import Foundation
import Network

/// TCP link to the Quest app (wire protocol in common/vr4mac.h), UDP discovery broadcast and adb reverse for USB.
final class Link {
    var onHello: ([String: Any]) -> Void = { _ in }
    var onTracking: (VR4Tracking) -> Void = { _ in }
    var onRequestIDR: () -> Void = {}
    var onMic: (Data) -> Void = { _ in }
    var onDisconnect: () -> Void = {}
    var onIssue: (String) -> Void = { _ in }
    private(set) var connected = false
    private(set) var peer = ""
    /// USB: the Quest reaches us through adb reverse, so the peer is loopback.
    var wired: Bool { peer.contains("127.0.0.1") || peer == "::1" }
    private var conn: NWConnection?
    private var inFlight = 0
    private let q = DispatchQueue(label: "vr4.link")
    private var listener: NWListener?
    private let usbQueue = DispatchQueue(label: "vr4.usb", qos: .utility)
    private var usbPending = false
    private let port: UInt16

    init(port: UInt16 = UInt16(VR4_PORT_TCP)) { self.port = port }

    func start(discovery: Bool = true) {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        do {
            listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            onIssue("Cannot listen for a headset: \(error.localizedDescription). Close other MacVR instances and reopen the app.")
            return
        }
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onIssue("")
            case .failed(let error): self?.onIssue("Headset connection unavailable: \(error.localizedDescription). Close other MacVR instances and reopen the app.")
            default: break
            }
        }
        listener?.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener?.start(queue: q)
        guard discovery else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1)
        var n = 0
        t.setEventHandler { [weak self] in
            self?.broadcast()
            if n % 5 == 0, self?.connected == false { self?.retryUSB() }
            n += 1
        }
        t.resume()
        timer = t
    }
    private var timer: DispatchSourceTimer?

    /// adb can block on USB authorization; keep it off the packet/connection queue.
    func retryUSB() {
        q.async { [weak self] in
            guard let self, !self.usbPending else { return }
            self.usbPending = true
            self.usbQueue.async { [weak self] in
                _ = adbReverse()
                self?.q.async { self?.usbPending = false }
            }
        }
    }

    private func accept(_ c: NWConnection) {
        if let previous = conn {
            previous.cancel()
            onDisconnect()
        }
        connected = false
        conn = c; inFlight = 0
        if case .hostPort(let h, _) = c.endpoint { peer = "\(h)" }
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c, c === self.conn else { return }
            switch s {
            case .ready: self.connected = true; self.onIssue("")
            case .failed, .cancelled: self.connected = false; self.conn = nil; self.inFlight = 0; self.peer = ""; self.onDisconnect()
            default: break
            }
        }
        c.start(queue: q)
        readPacket(c)
    }

    private func readPacket(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] h, _, done, err in
            guard let self, let h, h.count == 5, err == nil else { c.cancel(); return }
            let type = h[h.startIndex], len = Int(h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self) })
            guard len <= Int(VR4_MAX_PAYLOAD) else { c.cancel(); return }
            let handle = { (body: Data) in
                guard c === self.conn else { return }   // stale connection replaced by a newer one
                self.handle(type, body)
                if done { c.cancel() } else { self.readPacket(c) }
            }
            if len == 0 { handle(Data()); return }
            c.receive(minimumIncompleteLength: len, maximumLength: len) { b, _, _, err in
                guard let b, b.count == len, err == nil else { c.cancel(); return }
                handle(b)
            }
        }
    }

    private func handle(_ type: UInt8, _ b: Data) {
        switch Int(type) {
        case VR4_HELLO: if let j = try? JSONSerialization.jsonObject(with: b) as? [String: Any] { onHello(j) }
        case VR4_TRACKING where b.count == MemoryLayout<VR4Tracking>.size:
            onTracking(b.withUnsafeBytes { $0.loadUnaligned(as: VR4Tracking.self) })
        case VR4_REQUEST_IDR: onRequestIDR()
        case VR4_MIC: onMic(b)
        default: break
        }
    }

    /// Frames queued but not yet handed to the kernel; used to drop frames instead of building latency.
    var backlog: Int { q.sync { inFlight } }

    func send(_ type: Int32, _ payload: Data) {
        var d = Data([UInt8(type)])
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(payload)
        q.async { [self] in
            guard let c = conn else { return }
            inFlight += 1
            c.send(content: d, completion: .contentProcessed { [weak self, weak c] error in
                guard let self, let c, c === self.conn else { return }
                self.inFlight = max(0, self.inFlight - 1)
                if error != nil { c.cancel() }
            })
        }
    }

    func sendJSON(_ type: Int32, _ obj: [String: Any]) { send(type, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()) }

    private lazy var udp: Int32 = {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        return s
    }()
    private func broadcast() {
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(VR4_PORT_DISCOVERY).bigEndian
        a.sin_addr.s_addr = INADDR_BROADCAST
        let msg = "VR4MAC \(VR4_PORT_TCP)"
        _ = withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(udp, msg, msg.utf8.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
}

let adbPath = ["/opt/homebrew/bin/adb", NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb", "/usr/local/bin/adb"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

/// Wired mode: makes the Quest's 127.0.0.1:9945 reach this Mac over USB.
@discardableResult func adbReverse() -> Bool {
    guard let adb = adbPath else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: adb)
    p.arguments = ["reverse", "tcp:\(VR4_PORT_TCP)", "tcp:\(VR4_PORT_TCP)"]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    if done.wait(timeout: .now() + 8) == .timedOut { p.terminate(); return false }   // unauthorized/hung adb: don't block Retry USB forever
    return p.terminationStatus == 0
}
