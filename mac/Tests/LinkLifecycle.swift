import Foundation
import Darwin

@main struct LinkLifecycle {
    static func wait(_ signal: DispatchSemaphore, _ label: String) {
        precondition(signal.wait(timeout: .now() + 5) == .success, "Timed out: \(label)")
    }
    static func client(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var size: Int32 = 4096
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(result == 0, "connect failed")
        let body = Data("{\"device\":\"Lifecycle test\"}".utf8)
        var packet = Data([UInt8(VR4_HELLO)])
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { packet.append(contentsOf: $0) }
        packet.append(body)
        packet.withUnsafeBytes { precondition(Darwin.write(fd, $0.baseAddress, $0.count) == $0.count) }
        return fd
    }
    static func main() {
        let port: UInt16 = 19985
        let ready = DispatchSemaphore(value: 0), hello = DispatchSemaphore(value: 0)
        let disconnected = DispatchSemaphore(value: 0), conflict = DispatchSemaphore(value: 0)
        let link = Link(port: port)
        link.onIssue = { if $0.isEmpty { ready.signal() } }
        link.onHello = { _ in hello.signal() }
        link.onDisconnect = { disconnected.signal() }
        link.start(discovery: false)
        wait(ready, "listener ready")
        let first = client(port); wait(hello, "first HELLO")
        for _ in 0..<160 { link.send(Int32(VR4_VIDEO), Data(count: 65536)) }
        precondition(link.backlog > 0, "Must exercise pending sends")
        let second = client(port); wait(disconnected, "replacement cleanup"); wait(hello, "replacement HELLO")
        close(first)
        Thread.sleep(forTimeInterval: 0.2)
        precondition(link.backlog == 0, "Old completions must not corrupt new connection backlog")
        close(second); wait(disconnected, "EOF cleanup")
        precondition(link.backlog == 0, "Disconnected backlog must reset")
        let other = Link(port: port)
        other.onIssue = { if !$0.isEmpty { conflict.signal() } }
        other.start(discovery: false)
        wait(conflict, "port conflict surfaced")
        print("PASS: pending-send replacement, HELLO reconnect, EOF cleanup, listener failure")
    }
}
