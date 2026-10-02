import Foundation
import AppKit
import SceneKit

/// Shared memory with the Wine-side OpenXR runtime (layout in common/vr4mac.h).
final class Shm {
    let p: UnsafeMutablePointer<VR4Shm>
    init() {
        mkdir("/tmp/vr4mac", 0o777)
        let fd = open(VR4_SHM_PATH_MAC, O_RDWR | O_CREAT, 0o666)
        ftruncate(fd, off_t(VR4_SHM_SIZE))
        p = mmap(nil, Int(VR4_SHM_SIZE), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)!.bindMemory(to: VR4Shm.self, capacity: 1)
        close(fd)
        if p.pointee.magic != VR4_SHM_MAGIC || p.pointee.version != VR4_SHM_VERSION {
            memset(p, 0, MemoryLayout<VR4Shm>.size)
            p.pointee.magic = VR4_SHM_MAGIC; p.pointee.version = VR4_SHM_VERSION
        }
    }
    func write(_ t: VR4Tracking) {
        p.pointee.track_seq &+= 1; vr4_fence()
        p.pointee.track = t; vr4_fence()
        p.pointee.track_seq &+= 1
    }
    func frame(_ i: UInt32) -> UnsafeRawPointer { UnsafeRawPointer(vr4_frame(p, i)) }
}

/// Owns the headset session: link <-> compositor/game frames <-> encoder.
final class Engine: ObservableObject {
    let settings = Settings(), games = Games(), link = Link(), encoder = Encoder(), shm = Shm(), desktop = DesktopCapture(), audio = AudioCapture()
    let dash: Dashboard
    private let comp = Compositor()   // not lazy: touched from both the render and dashboard queues
    private let rq = DispatchQueue(label: "vr4.render", qos: .userInteractive)
    /// Dashboard state, CoreGraphics drawing and texture upload live here so the render queue never waits on them.
    private let dq = DispatchQueue(label: "vr4.dash", qos: .userInitiated)
    private var drawScheduled = false, lastMinute = -1   // dq only
    private var dashView = "home"                         // rq copy of dash.view
    private let viewLock = NSLock()
    private var _viewFrame: CVPixelBuffer?
    /// Latest side-by-side frame sent to the headset (for the VR View window).
    var viewFrame: CVPixelBuffer? { viewLock.lock(); defer { viewLock.unlock() }; return _viewFrame }
    private func setViewFrame(_ pb: CVPixelBuffer?) { viewLock.lock(); _viewFrame = pb; viewLock.unlock() }

    @Published var connected = false
    @Published var device = ""
    @Published var hands = (false, false)
    @Published var nowPlaying = ""
    @Published var streamInfo = ""   // e.g. "USB · 2432x1344 @ 72 Hz" for the Mac window
    @Published var connectionIssue = ""
    private lazy var gameOverrides = GameOverrides { [weak self] render, world in
        self?.shm.p.pointee.render_scale = render
        self?.shm.p.pointee.world_scale = world
    }
    private var overrideObserver: NSObjectProtocol?

    /// Settings > About on the Mac: show the welcome tour in the headset again.
    func replayTour() { dq.async { [self] in dash.startTutorial(); rq.async { self.setMenu(true) } } }

    private var eyeW = 0, eyeH = 0, fps = 72
    private var floorOffset: Float = 0
    private var useHEVC = false
    private var dashVisible = true, needPlace = true, windowShown = true
    private var menuDownAt: [CFTimeInterval] = [0, 0], menuHoldDone = [false, false]
    private var prevButtons: [UInt32] = [0, 0], prevTrigger: [Bool] = [false, false], prevGrip: [Bool] = [false, false], activeHand = 1
    /// Direct touch: the index fingertip is pressing a panel (tap = click, slide = drag); last fingertip depth.
    private var touchDown = [false, false], touchDepth: [Float] = [1, 1]
    private var directTouch = true
    private var grabHand: Int?                       // rq: hand dragging the window or dock by its grab bar
    private var desktopRect = CGRect.zero            // rq copy of dash.desktopRect
    private var detected: HeadsetModel = .quest2     // from HELLO
    private var backdropOn = false
    private var theaterOn = false, theaterPlace = false   // rq: flatscreen games / the Mac on a big screen
    private var tourFinal = false                         // rq: tour is on its "press your menu button" step
    private var lastTrack: VR4Tracking?
    private var pending: VR4Tracking?, scheduled = false
    private let pendingLock = NSLock()
    private var frameId: UInt64 = 0
    private var gameSeq: UInt32 = 0, hapticSeq: UInt32 = 0, lastGameFrame = Date.distantPast, gameActive = false
    private var fpsCount = 0, fpsT = Date()
    /// 5 s pipeline counters (logged): game frames seen, handed to the encoder, encoded, skipped for link backlog.
    private var stat = (game: 0, encIn: 0, encoded: 0, backlogSkip: 0, t: Date())
    private var audioStat = (packets: 0, dropped: 0, peak: Int16(0))   // rq
    private var uiQueue: [Int32] = [], lastAudioChunk = Date.distantPast, uiTimer: DispatchSourceTimer?   // rq: UI sounds for the headset

    /// UI sounds -> 48 kHz stereo, summed into the pending headset mix (44.1 kHz WAVs from UISounds, linear resample).
    private func pullUISounds() {
        for wav in UISounds.shared.takePending() where wav.count >= 44 + 8 {   // at least 2 stereo frames (interpolation reads i+1)
            wav.withUnsafeBytes { b in
                let src = b.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self), n = (wav.count - 44) / 4
                let out = n * 48_000 / 44_100
                if uiQueue.count < out * 2 { uiQueue += [Int32](repeating: 0, count: out * 2 - uiQueue.count) }
                for j in 0..<out {
                    let pos = Double(j) * 44_100 / 48_000, i = min(Int(pos), n - 2), f = Int32((pos - Double(i)) * 256)
                    for c in 0..<2 { uiQueue[2 * j + c] += (Int32(src[2 * i + c]) * (256 - f) + Int32(src[2 * i + 2 + c]) * f) >> 8 }
                }
            }
        }
    }
    /// Adds the next 10 ms of UI sound into a VR4_AUDIO packet (8-byte time header + 480 stereo s16 frames).
    private func mixUI(into pkt: inout Data) {
        pkt.withUnsafeMutableBytes { b in UISounds.shared.mixMusic(into: b.baseAddress!.advanced(by: 8).assumingMemoryBound(to: Int16.self), frames: (b.count - 8) / 4) }
        pullUISounds()
        guard !uiQueue.isEmpty else { return }
        let n = min(uiQueue.count, (pkt.count - 8) / 2)
        pkt.withUnsafeMutableBytes { b in
            let pcm = b.baseAddress!.advanced(by: 8).assumingMemoryBound(to: Int16.self)
            for i in 0..<n { pcm[i] = Int16(max(-32768, min(32767, Int32(pcm[i]) + uiQueue[i]))) }
        }
        uiQueue.removeFirst(n)
    }
    private var audioEnabled = false // rq only

    init() {
        dash = Dashboard(settings: settings, games: games)
        overrideObserver = NotificationCenter.default.addObserver(forName: Dashboard.overrideChanged, object: nil, queue: nil) { [weak self] note in
            guard let appid = note.userInfo?["appid"] as? String, let key = note.userInfo?["key"] as? String else { return }
            self?.rq.async { [weak self] in
                self?.gameOverrides.changed(appid, key: key)
            }
        }
        settings.onChange = { [weak self] in self?.rq.async { self?.applySettings() } }
        games.onUpdate = { [weak self] in self?.requestDraw() }
        dash.launch = { [weak self] g in
            guard let self else { return }
            // per-game overrides for the runtime (0 = default): render resolution and world scale
            rq.async { [self] in
                self.gameOverrides.start(g.appid)
                self.games.launch(g)
            }
            dash.note("Launching \(g.name)…", 4)
        }
        dash.power = { [weak self] in self?.games.quitGame(); self?.dash.note("Quitting game", 3) }
        dash.install = { [weak self] g in   // Steam asks to confirm on the Mac: show the desktop so it can be clicked in VR
            guard let self else { return }
            games.install(g)
            dq.asyncAfter(deadline: .now() + 1.5) { [self] in   // self is non-optional here
                self.dash.view = "desktop"; self.dash.note("Confirm the install in Steam's window", 5); self.requestDraw()
            }
        }
        dash.redraw = { [weak self] in self?.requestDraw() }
        link.onMic = { Mic.shared.receive($0) }
        Mic.shared.onChange = { [weak self] in self?.rq.async { self?.sendConfig() } }
        Mic.shared.apply()
        dash.recenter = { [weak self] in self?.rq.async { self?.needPlace = true } }
        dash.close = { [weak self] in guard self?.dash.view != "welcome" else { return }; self?.rq.async { self?.setMenu(false) } }
        dash.uninstall = { [weak self] g in   // Steam confirms on the Mac: show the desktop so it can be clicked in VR
            guard let self else { return }
            games.uninstall(g)
            dq.asyncAfter(deadline: .now() + 1.5) { [self] in self.dash.view = "desktop"; self.dash.note("Confirm the uninstall in Steam's window", 5); self.requestDraw() }
        }
        dash.openSteam = { [weak self] in self?.games.openSteam() }
        dash.theater = { [weak self] on in self?.rq.async { self?.setTheater(on) } }
        dash.version = "MacVR OS " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
        // desktop control (Accessibility-gated CGEvents)
        let input = DesktopInput.shared
        dash.desktopTrusted = input.trusted
        dash.requestTrust = { input.requestTrust() }
        dash.desktopPointer = { p, phase in
            if p.x >= 0 { input.move(toNormalized: p) }
            if phase == 1 { input.button(false, down: true) } else if phase == 3 { input.button(false, down: false) }
        }
        dash.desktopRightClick = { p in input.move(toNormalized: p); input.button(true, down: true); input.button(true, down: false) }
        dash.desktopScroll = { dy in input.scroll(dx: 0, dy: dy) }
        dash.typeText = { input.type($0) }
        dash.keyCode = { input.key(CGKeyCode($0)) }
        dash.setMacVolume = { v in DispatchQueue.global().async { Engine.appleScript("set volume output volume \(v)") } }
        link.onHello = { [weak self] j in self?.rq.async { self?.hello(j) } }
        link.onIssue = { [weak self] message in DispatchQueue.main.async { self?.connectionIssue = message } }
        link.onTracking = { [weak self] t in self?.tracking(t) }
        link.onRequestIDR = { [weak self] in self?.encoder.forceIDR = true }
        audio.onChunk = { [weak self] pkt in
            self?.rq.async {
                guard let self, self.audioEnabled else { return }
                guard self.link.backlog < 4 else { self.audioStat.dropped += 1; return }
                var out = Engine.mix(pkt)
                self.mixUI(into: &out); self.lastAudioChunk = Date()
                self.audioStat.packets += 1
                out.withUnsafeBytes { b in
                    let pcm = b.baseAddress!.advanced(by: 8).assumingMemoryBound(to: Int16.self)
                    for i in stride(from: 0, to: (b.count - 8) / 2, by: 16) { self.audioStat.peak = max(self.audioStat.peak, pcm[i] == .min ? .max : abs(pcm[i])) }
                }
                self.link.send(Int32(VR4_AUDIO), out)
            }
        }
        audio.onError = { [weak self] message in
            self?.dq.async { self?.dash.say(message) }
        }
        link.onDisconnect = { [weak self] in
            DesktopInput.shared.releaseAll()
            self?.shm.p.pointee.client_connected = 0
            self?.rq.async { [weak self] in
                guard let self else { return }
                audioEnabled = false; audio.stop(); uiQueue = []
                prevButtons = [0, 0]; prevTrigger = [false, false]; prevGrip = [false, false]
                grabHand = nil; lastTrack = nil
                desktop.stop(); setViewFrame(nil)
                dq.async { [weak self] in self?.dash.release(nil); self?.dash.grabbing = nil; self?.requestDraw() }
            }
            UISounds.shared.headsetOnly = false
            DispatchQueue.main.async { self?.connected = false; self?.hands = (false, false); self?.streamInfo = "" }
        }
        encoder.onFrame = { [weak self] data, idr, t in   // VideoToolbox thread: counters live on rq
            self?.rq.async { [weak self] in
                guard let self else { return }
                self.stat.encoded += 1
                self.frameId += 1
                var h = VR4VideoHeader(frame_id: self.frameId, time_ns: t, flags: idr ? 1 : 0)
                var d = Data(bytes: &h, count: MemoryLayout<VR4VideoHeader>.size)
                d.append(data)
                self.link.send(Int32(VR4_VIDEO), d)
            }
        }
        gameSeq = shm.p.pointee.frame_seq   // frames left over from an earlier run are not a running game
        games.scan()
        DispatchQueue.global(qos: .utility).async { [weak self] in   // install/refresh runtime, OpenComposite and game fixes at startup
            SiliconXR.install()   // VR for native Mac games (OpenXR + Vivecraft); independent of the Wine setup below
            do { try self?.games.setup() } catch {   // shown in the status window, not just the log
                NSLog("VR4Mac: setup failed: \(error)")
                DispatchQueue.main.async { self?.games.status = "Setup failed: \(error.localizedDescription)" }
            }
        }
        link.start()
        rq.async { self.applySettings() }

        // game frames + haptics from the Wine runtime; ponytail: 1 ms poll, swap for a semaphore if CPU matters
        let t = DispatchSource.makeTimerSource(queue: rq)
        t.schedule(deadline: .now(), repeating: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.pollRuntime() }
        t.resume(); pollTimer = t
        let clock = DispatchSource.makeTimerSource(queue: dq)
        clock.schedule(deadline: .now(), repeating: 1)
        clock.setEventHandler { [weak self] in   // clock needs a redraw once a minute; the fps counter every second
            guard let self else { return }
            let m = Calendar.current.component(.minute, from: Date())
            if m != self.lastMinute || self.settings.bool("show_fps") { self.lastMinute = m; self.requestDraw() }
        }
        clock.resume(); clockTimer = clock
    }
    private var pollTimer: DispatchSourceTimer?, clockTimer: DispatchSourceTimer?

    private var mbps: Int { settings["bitrate"] == "Auto" ? (link.wired ? 100 : 40) : settings.int("bitrate") }

    /// Coalesced dashboard redraw on dq; the finished texture is handed to the render queue.
    private func requestDraw() {
        dq.async { [self] in
            guard !drawScheduled else { return }
            drawScheduled = true
            dq.async { [self] in
                drawScheduled = false
                dash.draw()
                let tex = comp.uploadDashboard(dash.context), v = dash.view, r = dash.desktopRect, kb = dash.keyboardOpen
                let wo = dash.windowOpen
                let touring = v == "welcome", finalStep = dash.tourFinalStep, tourPart = dash.tourPart, hs = dash.headset
                dash.liveTourController = true
                if dash.animatingUntil > CACurrentMediaTime() { dq.asyncAfter(deadline: .now() + .milliseconds(16)) { self.requestDraw() } }
                rq.async { [self] in
                    comp.setDashboard(tex)
                    if v != dashView && dashVisible && !(v == "keyboard" && dashView == "library") { comp.pop(dock: false) }   // new window pops up
                    if wo && !windowShown && dashVisible { comp.pop(dock: false) }   // reopened from the dock
                    windowShown = wo; comp.setWindowHidden(!wo)
                    UISounds.shared.setMusic(touring)   // welcome-tour music, faded out when the tour ends
                    dashView = v; desktopRect = r; comp.setKeyboard(kb)
                    tourFinal = finalStep
                    comp.setDockHidden(touring)
                    comp.setSpace(touring && !finalStep)   // space during the tour; fades into the home on the last step
                    comp.setTourController(touring ? hs : nil, part: tourPart)
                }
            }
        }
    }

    /// Headset Audio level, balance and mono from Quick Settings, applied to the s16le stereo stream (8-byte time header).
    static func mix(_ pkt: Data) -> Data {
        let s = UISounds.shared, vol = Float(s.streamVolume) / 100, bal = Float(s.balance) / 50, mono = s.mono
        guard vol != 1 || bal != 0 || mono else { return pkt }
        var out = pkt
        let gl = vol * min(1, 1 - bal), gr = vol * min(1, 1 + bal)
        out.withUnsafeMutableBytes { raw in
            let pcm = raw.baseAddress!.advanced(by: 8).assumingMemoryBound(to: Int16.self), n = (raw.count - 8) / 4
            for i in 0..<n {
                var l = Float(pcm[2 * i]), r = Float(pcm[2 * i + 1])
                if mono { let m = (l + r) / 2; l = m; r = m }
                pcm[2 * i] = Int16(max(-32768, min(32767, l * gl))); pcm[2 * i + 1] = Int16(max(-32768, min(32767, r * gr)))
            }
        }
        return out
    }

    @discardableResult static func appleScript(_ src: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: src)?.executeAndReturnError(&err)
    }

    /// Open/close the menu (left ≡ button, the window's X, Resume). Opening re-places it in front of the head.
    private func setMenu(_ on: Bool) {
        guard on != dashVisible else { return }
        dashVisible = on; grabHand = nil
        UISounds.shared.play(on ? "menuOpen" : "menuClose")
        if on { needPlace = true; comp.pop(dock: true) } else { DesktopInput.shared.releaseAll() }
        let trusted = DesktopInput.shared.trusted
        dq.async { [self] in
            if on { dash.opened(); dash.desktopTrusted = trusted } else { dash.release(nil); dash.grabbing = nil }
            requestDraw()
        }
        if on {   // current Mac volume for the Quick Settings slider
            DispatchQueue.global().async { [weak self] in
                let v = Engine.appleScript("output volume of (get volume settings)")?.int32Value ?? -1
                self?.dq.async { self?.dash.macVolume = Int(v); self?.requestDraw() }
            }
        }
    }

    private func setTheater(_ on: Bool) {
        guard on != theaterOn else { return }
        theaterOn = on; theaterPlace = on; comp.lasersAlways = on
        if on { setMenu(false) } else { DesktopInput.shared.releaseAll() }
        UISounds.shared.play(on ? "env" : "close")
        dq.async { [self] in dash.theaterOn = on; requestDraw() }
    }
    private var theaterPrev = (trigger: [false, false], grip: [false, false])
    /// Theater with the menu closed: either laser is the Mac's mouse (trigger click/drag, grip right-click, stick scroll).
    private func theaterInput(_ t: VR4Tracking, _ hs: [VR4Hand], _ valid: [Bool]) {
        let input = DesktopInput.shared
        var rays: [Float?] = [nil, nil]
        for i in 0..<2 where valid[i] {
            let trig = hs[i].trigger > 0.55, grip = hs[i].squeeze > 0.7
            if let h = comp.theaterHit(hs[i].aim) {
                rays[i] = h.dist
                if i == activeHand || trig { input.move(toNormalized: h.uv) }
                if trig != theaterPrev.trigger[i] { activeHand = i; input.button(false, down: trig) }
                if grip && !theaterPrev.grip[i] { input.button(true, down: true); input.button(true, down: false) }
                if abs(hs[i].stick_y) > 0.2 { input.scroll(dx: 0, dy: Int32((hs[i].stick_y * 18).rounded())) }
            } else if theaterPrev.trigger[i] && !trig { input.button(false, down: false) }
            theaterPrev.trigger[i] = trig; theaterPrev.grip[i] = grip
        }
        comp.updateHands(t, rays: rays)
    }

    private func applyControllers() {
        let s = settings["controller_model"]
        let m = ["Quest 1": HeadsetModel.quest1, "Quest 2": .quest2, "Quest 3": .quest3][s] ?? detected
        comp.setControllerModel(m)
    }

    private func applySettings() {
        applyControllers()
        let quest = settings["menu_style"] != "SteamVR"   // Quest: a small window at arm's length, dock down by the hands
        let touch = settings.bool("direct_touch"), compact = quest && touch
        directTouch = touch
        comp.setLayout(quest: quest, compact: compact)
        let radii: [String: Float] = compact ? ["NEAR": 0.7, "MIDDLE": 0.85, "FAR": 1.0] : quest ? ["NEAR": 1.3, "MIDDLE": 1.6, "FAR": 2.0] : ["NEAR": 1.3, "MIDDLE": 1.8, "FAR": 2.5]
        comp.setRadius(radii[settings["dashboard_position"]] ?? radii["NEAR"]!)
        comp.setEnvironment(ProcessInfo.processInfo.environment["VR4_ENV"] ?? settings["environment"])   // VR4_ENV: README renders
        comp.setCurved(settings.bool("ui_curved"))
        comp.setGrid(settings.bool("floor_grid"))
        if eyeW > 0 { encoder.configure(width: eyeW * 2, height: eyeH, fps: fps, mbps: mbps, maxQP: (link.wired ? 23 : 30) + (useHEVC ? 4 : 0), hevc: useHEVC) }
        requestDraw()
        needPlace = true
    }

    private var config: [String: Any] = [:], helloMic = false
    /// CONFIG, also re-sent (same video params) when the microphone choice changes, to start/stop headset capture.
    private func sendConfig() {
        guard !config.isEmpty else { return }
        var c = config; c["mic"] = helloMic && Mic.shared.useHeadset
        link.sendJSON(Int32(VR4_CONFIG), c)
    }

    private func hello(_ j: [String: Any]) {
        let scale = Double(settings.int("render_scale")) / 100
        let rw = (j["eye_w"] as? Int).map { max(256, min(4096, $0)) } ?? 1440, rh = (j["eye_h"] as? Int).map { max(256, min(4096, $0)) } ?? 1584
        eyeW = max(128, min(2048, Int(Double(rw) * scale) / 32 * 32)); eyeH = max(128, min(2048, Int(Double(rh) * scale) / 32 * 32))
        floorOffset = j["reference_space"] as? String == "local" ? 1.6 : 0   // client has no STAGE space: assume standing height
        let rates = (j["refresh_rates"] as? [Double])?.map { Int($0.rounded()) } ?? [72]
        fps = rates.contains(settings.int("refresh_rate")) ? settings.int("refresh_rate") : (rates.first ?? 72)
        useHEVC = settings["codec"] == "HEVC" && (j["codecs"] as? [String])?.contains("hevc") == true
        if useHEVC, let mw = j["hevc_max_eye_w"] as? Int, let mh = j["hevc_max_eye_h"] as? Int, mw > 0, mh > 0 {
            eyeW = min(eyeW, mw / 32 * 32); eyeH = min(eyeH, mh / 32 * 32)
        }
        // decoder budget: H.264 level 5.1 = 983040 macroblocks/s; Quest HEVC ~4K60 (~480M px/s). Above it frames get rejected.
        let maxPixelsPerSecond = useHEVC ? 480_000_000 : 983_040 * 256
        while eyeW * 2 * eyeH * fps > maxPixelsPerSecond && eyeW > 256 {
            eyeW = (eyeW * 15 / 16) / 32 * 32; eyeH = (eyeH * 15 / 16) / 32 * 32
        }
        helloMic = j["mic"] as? Bool == true
        // encoder first: CONFIG must name a codec that actually started (HEVC falls back to H.264), or the headset waits on a black stream
        if !encoder.configure(width: eyeW * 2, height: eyeH, fps: fps, mbps: mbps, maxQP: (link.wired ? 23 : 30) + (useHEVC ? 4 : 0), hevc: useHEVC), useHEVC {
            useHEVC = false
            encoder.configure(width: eyeW * 2, height: eyeH, fps: fps, mbps: mbps, maxQP: link.wired ? 23 : 30, hevc: false)
        }
        config = ["eye_w": eyeW, "eye_h": eyeH, "fps": fps, "codec": useHEVC ? "hevc" : "h264"]
        sendConfig()
        NSLog("VR4Mac: %@ connected %@, %dx%d per eye @ %d Hz, %d Mbps", j["device"] as? String ?? "Quest", link.wired ? "over USB" : "over Wi-Fi", eyeW, eyeH, fps, mbps)
        let s = shm.p
        s.pointee.eye_w = UInt32(eyeW); s.pointee.eye_h = UInt32(eyeH); s.pointee.fps = Float(fps); s.pointee.client_connected = 1
        needPlace = true
        let name = j["device"] as? String ?? "Quest"
        detected = HeadsetModel.detect(device: name); applyControllers()
        Mic.shared.headsetName = detected.label
        activeHand = Dashboard.pointingHand   // the hand chosen in the welcome tour drives the menus first
        let info = "\(eyeW * 2)x\(eyeH) @ \(fps) Hz", wired = link.wired, hs = detected
        dq.async { [self] in
            dash.headset = hs; dash.linkStatus = wired ? "USB" : "Wi-Fi"; dash.streamInfo = info
            if !Dashboard.tutorialDone && dash.view != "welcome" { dash.startTutorial() }   // first-run welcome tour
            requestDraw()
        }
        audioEnabled = j["audio"] as? Bool == true
        if audioEnabled { audio.start() } else { audio.stop() }
        UISounds.shared.headsetOnly = audioEnabled
        if audioEnabled && uiTimer == nil {   // UI sounds still reach the headset when system capture is silent or unavailable
            let t = DispatchSource.makeTimerSource(queue: rq)
            t.schedule(deadline: .now(), repeating: .milliseconds(10))
            t.setEventHandler { [weak self] in
                guard let self, self.audioEnabled, Date().timeIntervalSince(self.lastAudioChunk) > 0.03 else { return }
                self.pullUISounds()
                guard !self.uiQueue.isEmpty || UISounds.shared.musicPlaying, self.link.backlog < 4 else { return }
                var t = UInt64(DispatchTime.now().uptimeNanoseconds)
                var pkt = Data(bytes: &t, count: 8); pkt.append(Data(count: 1920))
                self.mixUI(into: &pkt); self.audioStat.packets += 1
                self.link.send(Int32(VR4_AUDIO), pkt)
            }
            t.resume(); uiTimer = t
        }
        let mainInfo = (wired ? "USB" : "Wi-Fi") + " · " + info
        DispatchQueue.main.async { self.connected = true; self.device = hs.label; self.streamInfo = mainInfo }
    }

    /// Called on the link queue for every TRACKING packet; coalesces onto the render queue.
    private func tracking(_ raw: VR4Tracking) {
        var t = raw
        if floorOffset != 0 {   // LOCAL-space client: lift everything so the floor sits at y = 0 like STAGE
            t.head.py += floorOffset; t.eye.0.pose.py += floorOffset; t.eye.1.pose.py += floorOffset
            t.hand.0.aim.py += floorOffset; t.hand.0.grip.py += floorOffset; t.hand.1.aim.py += floorOffset; t.hand.1.grip.py += floorOffset
        }
        shm.write(t)
        pendingLock.lock(); pending = t; let go = !scheduled; scheduled = true; pendingLock.unlock()
        guard go else { return }
        rq.async { [self] in
            pendingLock.lock(); let t = pending!; scheduled = false; pendingLock.unlock()
            frame(t)
        }
    }

    /// Laser pointers on the menu: trigger press/hold/release, grip = secondary, stick = scroll.
    private func lasers(_ t: VR4Tracking, _ hs: [VR4Hand], _ valid: [Bool], _ trig: [Bool], _ grip: [Bool], _ rays: inout [Float?], _ poke: [Bool]) {
        var hits: [(uv: CGPoint, dist: Float)?] = [nil, nil]
        for i in 0..<2 where valid[i] && !poke[i] {
            if let h = comp.hit(hs[i].aim, solid: dash.solid) { hits[i] = h; rays[i] = h.dist }
        }
        if !trig[activeHand] {   // the hand that pulls the trigger (or the only one pointing at the menu) drives it
            if let i = (0..<2).first(where: { hits[$0] != nil && trig[$0] && !prevTrigger[$0] }) { activeHand = i }
            else if hits[activeHand] == nil, let i = (0..<2).first(where: { hits[$0] != nil }) { activeHand = i }
        }
        let a = activeHand, uv = hits[a]?.uv, dist = hits[a]?.dist, aim = hs[a].aim, head = t.head
        let down = trig[a] && !prevTrigger[a], held = trig[a] && prevTrigger[a], up = !trig[a] && prevTrigger[a]
        let secondary = grip[a] && !prevGrip[a], stick = grabHand == nil ? hs[a].stick_y : 0
        if grabHand == nil, dashView == "desktop", abs(hs[a].stick_x) > 0.5, hits[a] != nil {
            comp.zoomWindow(hs[a].stick_x * 0.012)   // stick left/right on the Mac desktop: smaller/bigger window
        }
        dq.async { [self] in
            var changed = false
            if down, let uv {
                let p = dash.press(uv)
                if p == .grabWindow || p == .grabDock || p == .grabKeyboard, let dist {
                    dash.grabbing = p == .grabWindow ? "grab" : p == .grabDock ? "grabdock" : "grabkb"
                    let part: Compositor.Part = p == .grabWindow ? .window : p == .grabDock ? .dock : .keyboard
                    rq.async { self.grabHand = a; self.comp.beginGrab(part, aim, dist: dist, head: head) }
                }
                changed = true
            } else if held, let uv { dash.drag(uv) }
            if up { dash.release(uv); changed = true }
            if secondary, let uv { dash.secondary(uv) }
            if abs(stick) > 0.2, let uv, dash.scroll(stick, at: uv) { changed = true }
            if dash.pointer(uv) { changed = true; if uv != nil { haptic(a, 0.25, 0.015) } }
            if changed { requestDraw() }
        }
    }

    private func frame(_ t: VR4Tracking) {
        lastTrack = t
        guard eyeW > 0 else { return }
        let hs = [t.hand.0, t.hand.1]
        let valid = hs.map { $0.flags & UInt32(VR4_HAND_ACTIVE | VR4_HAND_POSE_VALID) == UInt32(VR4_HAND_ACTIVE | VR4_HAND_POSE_VALID) }
        if valid[0] != hands.0 || valid[1] != hands.1 { DispatchQueue.main.async { self.hands = (valid[0], valid[1]) } }

        // left ≡ (menu) is the Quest system button: a press opens/closes the menu, holding it recenters (and opens) it.
        // B / Y too if enabled in Settings.
        for i in 0..<2 {
            var mask = i == 0 ? UInt32(VR4_BTN_MENU) : 0
            if settings.bool("system_button") { mask |= UInt32(i == 0 ? VR4_BTN_Y : VR4_BTN_B) }
            let down = valid[i] && hs[i].buttons & mask != 0, was = prevButtons[i] & mask != 0
            if down && !was { menuDownAt[i] = CACurrentMediaTime(); menuHoldDone[i] = false }
            if down && !menuHoldDone[i] && CACurrentMediaTime() - menuDownAt[i] > 0.6 && dashView != "welcome" {
                menuHoldDone[i] = true; needPlace = true; UISounds.shared.play("pop")   // hold: recenter in front of you
                if !dashVisible { setMenu(true) } else { comp.pop(dock: true) }
            }
            if !down && was && !menuHoldDone[i] {
                if dashView == "welcome" {   // the tour only ends on its last step, by pressing the menu button
                    if tourFinal { dq.async { [self] in dash.finishTutorial(); requestDraw() }; setMenu(false) }
                } else { setMenu(!dashVisible) }
            }
            prevButtons[i] = valid[i] ? hs[i].buttons : 0
        }
        shm.p.pointee.input_blocked = dashVisible ? 1 : 0
        if needPlace { comp.place(head: t.head); needPlace = false }
        comp.setDashVisible(dashVisible)

        // laser pointers: trigger press/hold/release, grip = secondary, stick = scroll (or push/pull while grabbing)
        var rays: [Float?] = [nil, nil], push: [SIMD3<Float>] = [.zero, .zero], poke = [false, false]
        let trig = (0..<2).map { valid[$0] && hs[$0].trigger > 0.55 }
        let grip = (0..<2).map { valid[$0] && hs[$0].squeeze > 0.7 }
        if dashVisible {
            if let g = grabHand {
                if valid[g] && trig[g] {
                    if comp.updateGrab(hs[g].aim, head: t.head, push: abs(hs[g].stick_y) > 0.2 ? hs[g].stick_y * 0.025 : 0) {
                        haptic(g, 0.8, 0.04); UISounds.shared.play("drop")   // hit the distance stop: it sticks here
                    }
                }
                else { grabHand = nil; UISounds.shared.play("drop"); dq.async { [self] in dash.grabbing = nil; requestDraw() } }
            }
            // direct touch: the fingertip pad presses when it reaches the surface and re-arms once lifted ~1 cm (taps type
            // fast); the hand stays on the surface unless pushed 6 cm through; while pressed, sliding drags.
            var touchUV: CGPoint?
            for i in 0..<2 where directTouch {
                let tc = valid[i] ? comp.touch(i, grip: hs[i].grip) : nil
                let onMenu = tc.map { dash.solid($0.uv) } ?? false, d = onMenu ? tc!.depth : 1
                poke[i] = onMenu && d < 0.12 && !trig[i]   // pulling the trigger keeps the laser
                if onMenu && d < 0 && d > -0.06 { push[i] = tc!.normal * -d }
                let wasDown = touchDown[i]
                touchDown[i] = poke[i] && d > -0.06 && (wasDown ? d < 0.012 : d <= 0.003 && touchDepth[i] > 0.003)
                touchDepth[i] = touchDown[i] ? min(touchDepth[i], d) : d
                guard onMenu, let uv = tc?.uv else { if wasDown { dq.async { [self] in dash.release(nil); requestDraw() } }; continue }
                if poke[i] && d < 0.05 { touchUV = uv; rays[i] = nil }
                if touchDown[i] && !wasDown {
                    haptic(i, 0.45, 0.018)
                    dq.async { [self] in if dash.press(uv) != .handled { dash.release(nil) }; requestDraw() }
                } else if touchDown[i] { dq.async { [self] in dash.drag(uv) } }
                else if wasDown { dq.async { [self] in dash.release(uv); requestDraw() } }
            }
            if let uv = touchUV { dq.async { [self] in if dash.pointer(uv) { requestDraw() } } }   // a finger at the menu drives it
            if touchUV == nil || grabHand != nil { lasers(t, hs, valid, trig, grip, &rays, poke) }
        }
        for i in 0..<2 { prevTrigger[i] = trig[i]; prevGrip[i] = grip[i] }
        comp.updateHands(t, rays: rays, push: push, poke: poke)

        // the desktop tab streams the Mac screen onto the dashboard
        let wantDesktop = dashVisible && windowShown && dashView == "desktop"
        if wantDesktop || theaterOn { desktop.start() } else if desktop.running { desktop.stop() }
        comp.setTheater(theaterOn ? desktop.latest : nil, head: theaterPlace ? t.head : nil)
        if theaterOn && desktop.latest != nil { theaterPlace = false }
        if theaterOn && !dashVisible { theaterInput(t, hs, valid) }
        let streaming = desktop.latest != nil
        dq.async { [self] in if dash.desktopStreaming != streaming { dash.desktopStreaming = streaming; requestDraw() } }
        let shot = wantDesktop ? desktop.latest : nil
        comp.setScreen(shot, rect: desktopRect)
        if let shot {
            let aspect = CGFloat(CVPixelBufferGetWidth(shot)) / CGFloat(max(1, CVPixelBufferGetHeight(shot)))
            dq.async { [self] in if abs(dash.desktopAspect - aspect) > 0.001 { dash.desktopAspect = aspect; requestDraw() } }
        }

        if gameActive && !dashVisible { return }   // game frames drive the stream
        if backdropOn && !(gameActive && dashVisible) { comp.setGameBackdrop(nil, poses: [], fovs: []); backdropOn = false }
        guard link.backlog < 3, let pb = comp.render(t, eyeW: eyeW, eyeH: eyeH) else { return }
        send(pb, t.time_ns)
    }

    private func send(_ pb: CVPixelBuffer, _ timeNs: UInt64) {
        stat.encIn += 1
        if Date().timeIntervalSince(stat.t) >= 5 {
            let d = Date().timeIntervalSince(stat.t)
            NSLog("VR4Mac: pipeline %.1f game fps, %.1f to encoder, %.1f encoded, %d backlog skips; audio %d pkts (%d dropped, peak %d, enabled %d)", Double(stat.game) / d, Double(stat.encIn) / d, Double(stat.encoded) / d, stat.backlogSkip, audioStat.packets, audioStat.dropped, Int(audioStat.peak), audioEnabled ? 1 : 0)
            audioStat = (0, 0, 0)
            stat = (0, 0, 0, 0, Date())
        }
        setViewFrame(pb)
        encoder.encode(pb, timeNs: timeNs)
        fpsCount += 1
        if Date().timeIntervalSince(fpsT) >= 1 { let n = fpsCount; dq.async { self.dash.fps = n }; fpsCount = 0; fpsT = Date() }
    }

    private func pollRuntime() {
        let s = shm.p
        if s.pointee.haptic_seq != hapticSeq {
            hapticSeq = s.pointee.haptic_seq
            var h = s.pointee.haptic
            link.send(Int32(VR4_HAPTICS), Data(bytes: &h, count: MemoryLayout<VR4Haptics>.size))
        }
        let seq = s.pointee.frame_seq
        if seq != gameSeq {
            gameSeq = seq; lastGameFrame = Date(); stat.game += 1
            if !gameActive {
                gameActive = true; setMenu(false)
                let name = withUnsafeBytes(of: s.pointee.app_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                let shown = name.replacingOccurrences(of: "OpenComposite_", with: "")
                dq.async { [self] in dash.gameActive = true; dash.gameName = shown; requestDraw() }
                NSLog("VR4Mac: streaming game frames from '%@'", name)
                DispatchQueue.main.async { self.nowPlaying = name.isEmpty ? "VR Game" : name }
            }
            let i = seq % 2
            let (w, h) = (Int(withUnsafeBytes(of: s.pointee.frame_w) { $0.load(fromByteOffset: Int(i) * 4, as: UInt32.self) }),
                          Int(withUnsafeBytes(of: s.pointee.frame_h) { $0.load(fromByteOffset: Int(i) * 4, as: UInt32.self) }))
            let t = withUnsafeBytes(of: s.pointee.frame_time_ns) { $0.load(fromByteOffset: Int(i) * 8, as: UInt64.self) }
            let rgba = withUnsafeBytes(of: s.pointee.frame_rgba) { $0.load(fromByteOffset: Int(i) * 4, as: UInt32.self) } != 0
            guard w > 0, h > 0, w * h * 4 <= Int(VR4_FRAME_MAX) else { return }
            if dashVisible {   // menu over the game: keep the latest game frame as the (world-locked) backdrop
                guard let pb = comp.copyFrame(shm.frame(i), w: w, h: h, outW: w, outH: h, rgba: rgba), let lt = lastTrack else { return }
                let poses = withUnsafeBytes(of: s.pointee.frame_eye_pose) { b in
                    (0..<2).map { e in b.load(fromByteOffset: (Int(i) * 2 + e) * MemoryLayout<VR4Pose>.stride, as: VR4Pose.self) }
                }
                comp.setGameBackdrop(pb, poses: poses, fovs: [lt.eye.0.fov, lt.eye.1.fov]); backdropOn = true
                return
            }
            guard link.backlog < 3 else { stat.backlogSkip += 1; return }
            guard let pb = comp.copyFrame(shm.frame(i), w: w, h: h, outW: eyeW * 2, outH: eyeH, rgba: rgba) else { return }
            send(pb, t)
        } else if gameActive && Date().timeIntervalSince(lastGameFrame) > 2 {
            gameActive = false; setMenu(true)
            gameOverrides.stop()
            dq.async { [self] in dash.gameActive = false; dash.gameName = ""; requestDraw() }
            NSLog("VR4Mac: game stopped, back to home")
            DispatchQueue.main.async { self.nowPlaying = "" }
        }
    }

    private func haptic(_ hand: Int, _ amp: Float, _ dur: Float) {
        var h = VR4Haptics(hand: UInt8(hand), amplitude: amp, duration_s: dur, frequency_hz: 0)
        link.send(Int32(VR4_HAPTICS), Data(bytes: &h, count: MemoryLayout<VR4Haptics>.size))
    }

    // MARK: self-test: render one frame with a fake headset pose, save PNG, encode, check NAL types
    func snapshot(to path: String) {
        let hevc = ProcessInfo.processInfo.environment["VR4_HEVC"] == "1"
        let readme = ProcessInfo.processInfo.environment["VR4_README"] == "1"   // one wide eye, no controller
        hello(["eye_w": readme ? Int(ProcessInfo.processInfo.environment["VR4_EYE_W"] ?? "1920")! : 1024, "eye_h": readme ? Int(ProcessInfo.processInfo.environment["VR4_EYE_W"] ?? "1920")! * (ProcessInfo.processInfo.environment["VR4_WIDE"] == "1" ? 9 : 21) / (ProcessInfo.processInfo.environment["VR4_WIDE"] == "1" ? 16 : 32) : 1024, "device": "Test", "codecs": hevc ? ["hevc", "h264"] : ["h264"]])
        let wide = ProcessInfo.processInfo.environment["VR4_WIDE"] == "1"   // video framing: smaller UI, room for captions
        let fov = wide ? VR4Fov(left: -0.98, right: 0.98, up: 0.62, down: -0.72) : readme ? VR4Fov(left: -0.82, right: 0.82, up: 0.45, down: -0.75) : VR4Fov(left: -0.8, right: 0.8, up: 0.8, down: -0.8)
        func pose(_ x: Float, _ y: Float, _ z: Float) -> VR4Pose { VR4Pose(px: x, py: y, pz: z, qx: 0, qy: 0, qz: 0, qw: 1) }
        let aimDown = simd_quatf(angle: -0.25, axis: SIMD3(1, 0, 0))
        var hand = VR4Hand(flags: readme ? 0 : 3, buttons: 0, aim: pose(0.2, 1.3, -0.3), grip: pose(0.2, 1.3, -0.3), trigger: 0, squeeze: 0, stick_x: 0, stick_y: 0)
        hand.aim.qx = aimDown.imag.x; hand.aim.qw = aimDown.real
        let pitch = simd_quatf(angle: Float(ProcessInfo.processInfo.environment["VR4_PITCH"] ?? "0") ?? 0, axis: SIMD3(1, 0, 0))   // README renders
        func look(_ x: Float) -> VR4Pose { var p = pose(x, 1.6, 0); p.qx = pitch.imag.x; p.qw = pitch.real; return p }
        let t = VR4Tracking(time_ns: 1, head: look(0), eye: (VR4Eye(pose: look(-0.032), fov: fov), VR4Eye(pose: look(0.032), fov: fov)),
                            hand: (VR4Hand(), hand))
        var nals: [UInt8] = []
        let done = DispatchSemaphore(value: 0)
        encoder.onFrame = { d, idr, _ in
            var i = 0
            while i + 4 < d.count { if d[i] == 0, d[i + 1] == 0, d[i + 2] == 0, d[i + 3] == 1 { nals.append(hevc ? (d[i + 4] >> 1) & 0x3f : d[i + 4] & 0x1f) }; i += 1 }
            done.signal()
        }
        rq.sync { frame(t) }
        dq.sync {}; dq.sync {}   // let the dashboard draw + upload finish
        if let st = ProcessInfo.processInfo.environment["VR4_TOUR_STEP"].flatMap({ Int($0) }) {   // snapshot a tour step mid-animation
            dq.sync { dash.testTourStep(st) }; dq.sync {}; dq.sync {}
            Thread.sleep(forTimeInterval: Double(ProcessInfo.processInfo.environment["VR4_SNAP_WAIT"] ?? "2.2") ?? 2.2)
        }
        if ProcessInfo.processInfo.environment["VR4_GAMES"] == "1" { games.scan(); RunLoop.main.run(until: Date() + 5); dq.sync {} }   // video renders: real library
        if let v = ProcessInfo.processInfo.environment["VR4_VIEW"] { dq.sync { dash.view = v }; requestDraw(); Thread.sleep(forTimeInterval: Double(ProcessInfo.processInfo.environment["VR4_SNAP_WAIT"] ?? "0.6") ?? 0.6) }   // README renders
        if let k = ProcessInfo.processInfo.environment["VR4_CLICK"]?.split(separator: ",").compactMap({ Double($0) }), k.count == 2 {   // canvas px
            dq.sync { dash.click(CGPoint(x: k[0] / Double(Dashboard.W), y: k[1] / Double(Dashboard.H))); dash.draw() }
        }
        if let n = ProcessInfo.processInfo.environment["VR4_SCROLL"].flatMap({ Int($0) }) {   // stick-scroll steps over the window
            dq.sync { for _ in 0..<n { _ = dash.scroll(-1, at: CGPoint(x: 0.5, y: 0.25)) }; dash.draw() }
        }
        if let h = ProcessInfo.processInfo.environment["VR4_HOVER"]?.split(separator: ",").compactMap({ Double($0) }), h.count == 2 {   // canvas px
            dq.sync { _ = dash.pointer(CGPoint(x: h[0] / Double(Dashboard.W), y: h[1] / Double(Dashboard.H))) }; requestDraw()
        }
        Thread.sleep(forTimeInterval: 0.4)   // let window pop-in animations settle
        if let p = ProcessInfo.processInfo.environment["VR4_DASH_PNG"] {   // video renders: the raw dashboard canvas with alpha
            dq.sync { dash.draw(); if let img = dash.context.makeImage() { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p)) } }
            return
        }
        dq.sync {}; dq.sync {}
        rq.sync {}   // finish selected view's texture and dock/keyboard updates before capture
        Thread.sleep(forTimeInterval: 0.4)
        rq.sync {
            guard let pb = comp.render(t, eyeW: eyeW, eyeH: eyeH) else { print("render failed"); exit(1) }
            let full = CIImage(cvPixelBuffer: pb), ci = readme ? full.cropped(to: CGRect(x: 0, y: 0, width: full.extent.width / 2, height: full.extent.height)) : full
            let rep = NSBitmapImageRep(ciImage: ci)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        _ = done.wait(timeout: .now() + 5)
        print("VR4Shm size \(MemoryLayout<VR4Shm>.size), VR4Tracking \(MemoryLayout<VR4Tracking>.size), NAL types in first frame: \(Set(nals).sorted())")
        assert(MemoryLayout<VR4Tracking>.size == 284)
        if hevc { assert(nals.first == 32 && nals.contains(33) && nals.contains(34) && nals.contains { $0 == 19 || $0 == 20 }, "HEVC IDR must start with VPS, SPS, PPS") }
        else { assert(nals.first == 7 && nals.contains(8) && nals.contains(5), "IDR must start with SPS, PPS") }
    }
}
