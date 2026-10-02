import Foundation
import CoreGraphics
import CoreText
import AppKit
import ImageIO

/// Swipe scrolling for a list (finger or hand pinch): it follows the finger, stretches with rubber-band resistance past
/// either end, coasts with momentum after release and springs back inside. A plain value, stepped by the Dashboard's
/// draw loop (Tests/main.swift checks the physics).
struct Flick {
    var pos: CGFloat = 0, vel: CGFloat = 0, limit: CGFloat = 0
    private(set) var held = false
    private var last: (t: Double, p: CGFloat)?
    /// Overscroll stretches less and less, to at most `band` px; `friction` per second while coasting.
    static let band: CGFloat = 300, friction: CGFloat = 3.2
    static func rubber(_ x: CGFloat) -> CGFloat { (1 - 1 / (x * 0.55 / band + 1)) * band }
    var settled: Bool { !held && vel == 0 && pos >= 0 && pos <= limit }
    /// Finger down: catches a coasting list.
    mutating func grab(at t: Double) { held = true; vel = 0; last = (t, pos) }
    /// `raw`: where the finger puts the list.
    mutating func drag(to raw: CGFloat, at t: Double) {
        pos = raw < 0 ? -Flick.rubber(-raw) : raw > limit ? limit + Flick.rubber(raw - limit) : raw
        if let l = last, t - l.t > 0.001 { vel = 0.75 * (pos - l.p) / CGFloat(t - l.t) + 0.25 * vel }
        last = (t, pos)
    }
    /// Finger lifted: coast at the finger's speed; a pause before lifting means no coast.
    mutating func release(at t: Double) {
        if let l = last, t - l.t > 0.08 { vel = 0 }
        vel = Swift.max(-6000, Swift.min(6000, vel)); held = false; last = nil
    }
    /// Thumbstick: moves directly (clamped), no momentum.
    mutating func set(_ p: CGFloat) { pos = Swift.max(0, Swift.min(limit, p)); vel = 0 }
    /// Page buttons: glide `d` px and come to rest there.
    mutating func glide(_ d: CGFloat) { vel = d * Flick.friction }
    /// Advances the physics by `dt` seconds; true while still moving.
    @discardableResult mutating func step(_ dt: CGFloat) -> Bool {
        guard !held else { return false }
        var left = dt
        while left > 0 {
            let h = Swift.min(left, 1.0 / 120); left -= h
            if pos < 0 || pos > limit {   // critically damped spring back to the end it passed
                let e: CGFloat = pos < 0 ? 0 : limit, k: CGFloat = 160
                vel += (-k * (pos - e) - 2 * k.squareRoot() * vel) * h
                pos += vel * h
                if abs(pos - e) < 0.5 && abs(vel) < 30 { pos = e; vel = 0 }
            } else {
                pos += vel * h
                vel *= exp(-Flick.friction * h)
                if abs(vel) < 20 { vel = 0 }   // under ~1 px a frame: stop (saves redraws)
            }
        }
        return !settled
    }
}

/// MacVR OS: the in-headset shell, drawn with CoreGraphics into one transparent texture (y-down canvas) that the
/// Compositor cuts into three floating panels, laid out like the Quest Universal Menu:
///   window (+ grab bar)  |  dock (+ grab bar)  |  pop-up keyboard (below the dock, only while typing).
/// Every control does something real; the Engine wires the callbacks (desktop input, Mac volume, games, environment).
final class Dashboard {
    static let W = 2048, H = 1810
    static let WIN = CGRect(x: 124, y: 16, width: 1800, height: 900)        // app window
    static let GRAB = CGRect(x: 874, y: 924, width: 300, height: 56)         // window grab bar (hit area; pill drawn inside)
    static let SPLIT = 990                                                   // canvas y: window part above, dock part below
    static let DOCK = CGRect(x: 224, y: 1062, width: 1600, height: 124)      // Universal Menu (tooltips drawn above it)
    static let DOCKGRAB = CGRect(x: 874, y: 1196, width: 300, height: 56)    // dock grab bar (moves dock + window together)
    static let SPLIT2 = 1262                                                 // canvas y: keyboard panel below
    static let KB = CGRect(x: 274, y: 1282, width: 1500, height: 460)        // pop-up keyboard panel
    static let KBGRAB = CGRect(x: 874, y: 1748, width: 300, height: 56)      // keyboard grab bar
    private static let content = CGRect(x: 164, y: 112, width: 1720, height: 784)   // window area below the title

    enum Press { case none, handled, grabWindow, grabDock, grabKeyboard }

    var view = "home" { didSet { windowOpen = true } }   // opening any view (dock, tiles) brings the window back
    /// The window's close dot hides just the window; the Universal Menu stays.
    var windowOpen = true
    var hover: String?
    var fps = 0
    var gameActive = false { didSet { trackPlay() } }
    var gameName = "" { didSet { trackPlay() } }
    var desktopStreaming = false
    var desktopAspect: CGFloat = 16.0 / 10
    var desktopTrusted = false
    var macVolume = -1                    // -1 = unknown until the Engine reads it
    var linkStatus = "USB"
    var headset: HeadsetModel = .quest2
    var streamInfo = ""                   // e.g. "2432x1344 @ 72 Hz"
    var headsetBattery = -1               // 0-100 from the headset's VR4_STATUS, -1 unknown
    var headsetCharging = false
    /// Save the headset view to ~/Pictures/MacVR (the Engine hides the menu first). Same as holding ≡ and pulling a trigger.
    var screenshot: () -> Void = {}
    /// Mac windows in VR: show the window picker (the Engine draws it in front of the menu).
    var openMacWindows: () -> Void = {}
    /// The keyboard panel types into the Mac window last used in VR (its bar's keyboard button).
    var macKeyboard = false
    var version = "MacVR OS"
    /// The pop-up keyboard panel is showing (search, command search, settings search, typing into the Mac desktop, or the tour's name step).
    var keyboardOpen: Bool {
        (view == "commands" && commandKeyboard) || view == "keyboard" || (view == "desktop" && desktopKeyboard)
            || (view == "welcome" && Dashboard.tour[min(step, Dashboard.tour.count - 1)].kind == "name") || (view == "settings" && settingsSearch) || macKeyboard
    }
    /// The user's name from the welcome tour (dock avatar, greetings); empty until they enter it.
    static var userName: String {
        get { UserDefaults.standard.string(forKey: "user.name") ?? "" } set { UserDefaults.standard.set(newValue, forKey: "user.name") }
    }
    /// Pointing hand chosen in the tour: 0 left, 1 right.
    static var pointingHand: Int {
        get { UserDefaults.standard.object(forKey: "user.hand") as? Int ?? 1 } set { UserDefaults.standard.set(newValue, forKey: "user.hand") }
    }
    /// Tour phases the Engine reacts to: space environment until the last step, then fade home; dock hidden throughout.
    var tourFinalStep: Bool { view == "welcome" && step == Dashboard.tour.count - 1 }
    /// Tour step's controller part for the live 3D controller ("trigger", "grip", "stick", "none"); nil = no controller.
    var tourPart: String? {
        guard view == "welcome" else { return nil }
        let t = Dashboard.tour[min(step, Dashboard.tour.count - 1)]
        return ["home", "hand", "style", "comfort", "hands"].contains(t.kind) ? nil : t.part
    }
    /// Close dot beside a grab bar (grows into an X on hover).
    static func dotRect(_ g: CGRect) -> CGRect { CGRect(x: g.midX + 120, y: g.midY - 30, width: 60, height: 60) }   // just past the pill's end
    /// Engine keeps redrawing (~60 Hz) while this is in the future, so animations play.
    var animatingUntil: CFTimeInterval = 0
    private var dotSince: [String: CFTimeInterval] = [:]
    /// Called by the Engine when the menu button is pressed on the tour's last step.
    func finishTutorial() { Dashboard.tutorialDone = true; view = gameActive ? "playing" : "home"; sounds.play("launch") }

    // callbacks (Engine)
    var launch: (Game) -> Void = { _ in }
    var install: (Game) -> Void = { _ in }
    var uninstall: (Game) -> Void = { _ in }
    var openSteam: () -> Void = {}
    /// Theater mode: the Mac screen (where a flatscreen game runs) on a big curved screen in a dark room.
    var theater: (Bool) -> Void = { _ in }
    var theaterOn = false
    /// Quits the running game.
    var power: () -> Void = {}
    var recenter: () -> Void = {}
    var close: () -> Void = {}
    var redraw: () -> Void = {}
    /// Power menu > Refresh Video: asks the encoder for a fresh keyframe (clears a frozen or blocky picture).
    var refreshStream: () -> Void = {}
    var setMacVolume: (Int) -> Void = { _ in }
    var requestTrust: () -> Void = {}
    /// Desktop pointer: normalized point on the Mac's main display (0-1, top-left) and phase 0 move, 1 down, 2 drag, 3 up.
    var desktopPointer: (CGPoint, Int) -> Void = { _, _ in }
    var desktopRightClick: (CGPoint) -> Void = { _ in }
    var desktopScroll: (Int32) -> Void = { _ in }
    var typeText: (String) -> Void = { _ in }
    var keyCode: (UInt16) -> Void = { _ in }

    private struct Region { let id: String; let r: CGRect; let fn: (() -> Void)?; let drag: ((CGPoint, Int) -> Void)? }
    private var regions: [Region] = []
    private var capture: Region?          // region receiving drag events while the trigger is held
    private let settings: Settings, games: Games
    private var ctx: CGContext
    private let mainCtx: CGContext
    // MARK: multitasking (Quest style): up to three windows. The centre one is `view`; the side slots keep their own view
    // and canvas (window part only, W x SPLIT) and are fully usable: input on a side panel runs with that view swapped in.
    private(set) var sideViews: [String?] = [nil, nil]   // left, right
    private var sideRegions: [[Region]] = [[], []], sideCtxs: [CGContext?] = [nil, nil]
    private var drawingSlot = 1, hoverSlot = 1, inputSlot = 1
    /// A newly opened app replaced the centre window (the Compositor makes it hop).
    var windowJump: () -> Void = {}
    func sideContext(_ i: Int) -> CGContext? { sideViews[i] == nil ? nil : sideCtxs[i] }
    private func sideCtx(_ i: Int) -> CGContext {
        if let c = sideCtxs[i] { return c }
        let c = CGContext(data: nil, width: Dashboard.W, height: Dashboard.SPLIT, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        c.translateBy(x: 0, y: CGFloat(Dashboard.SPLIT)); c.scaleBy(x: 1, y: -1)
        sideCtxs[i] = c
        return c
    }
    /// Runs input for slot 0 (left), 1 (centre/main canvas) or 2 (right) with that window's view swapped in.
    func inSlot<T>(_ slot: Int, _ body: () -> T) -> T {
        inputSlot = slot
        defer { inputSlot = 1 }
        let i = slot == 0 ? 0 : 1
        guard slot != 1, let v = sideViews[i] else { return body() }
        let saved = (view, windowOpen)
        view = v
        let r = body()
        sideViews[i] = windowOpen ? view : nil   // its close button empties the slot
        view = saved.0; windowOpen = saved.1
        return r
    }
    /// A window dragged from one slot to another: the two slots swap windows (an empty centre closes the main window).
    func moveWindow(from a: Int, to b: Int) {
        guard a != b, view != "welcome" else { return }
        func get(_ k: Int) -> String? { k == 1 ? (windowOpen ? view : nil) : sideViews[k == 0 ? 0 : 1] }
        let va = get(a), vb = get(b)
        func set(_ k: Int, _ v: String?) {
            if k == 1 { if let v { view = v; windowOpen = true } else { windowOpen = false } } else { sideViews[k == 0 ? 0 : 1] = v }
        }
        navigationHistory.swapAt(a, b)
        set(a, vb); set(b, va)
        sounds.play("drop"); redraw()
    }
    private let sounds = UISounds.shared
    private var commandKeyboard = false
    private var commandQuery = ""
    private var searchText: String {
        get { view == "commands" ? commandQuery : query }
        set { if view == "commands" { commandQuery = newValue } else { query = newValue } }
    }
    private var commandPage = 0, noticePage = 0
    private var overviewReturn = "home"
    private var navigationHistory: [[String]] = [[], [], []]
    private var navigatingBack = false
    /// Quiet mode is Do Not Disturb (one setting): notifications collect without pop-ups.
    private var quiet: Bool { settings.bool("dnd") }
    private var query = "", kbShift = false, desktopKeyboard = false
    private var spacePage = 0
    private var filter = 0                // library: index into `filters`
    private var sort = UserDefaults.standard.integer(forKey: "lib.sort")   // library: index into `sorts`
    private var menuFor: String?          // library tile whose "..." menu is open
    private var section = "general"       // settings sidebar
    private var settingsSearch = false, settingsQuery = ""
    private var highlight: (key: String, since: CFTimeInterval)?   // a setting opened from search: flashes once
    private var reveal: String?           // settings row to scroll into view on the next draw
    private var step = 0                  // welcome tutorial page
    private var tipIndex = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0   // home: tip of the day
    private var lastDesktopUV: CGPoint?
    var grabbing: String?                 // grab bar held (Engine sets/clears), keeps it highlighted
    private var pressed: (String, CFTimeInterval)?, inPress = false, navved = false
    private let solidLock = NSLock()
    private var solidState = (true, false, Dashboard.DOCK, [CGRect]())   // (windowOpen, keyboardOpen, dock, extras) as of the last draw
    private var solidExtra: [CGRect] = []  // opaque bits outside the window/dock this draw (a toast above the dock)
    private var sideOpen = [false, false]
    /// Menu style (Settings > Universal Menu): "Quest" = compact OS dock + windows with a bottom title bar;
    /// otherwise the SteamVR-like wide bar with the title on top. Read once per draw, like the accessibility options.
    private var quest = true, contrast = false, reduceMotion = false, leftHanded = false, textScale: CGFloat = 1
    private var dockRect = Dashboard.DOCK
    /// Window area below the title (Quest: the title bar is at the bottom, so content starts higher).
    private var content: CGRect { quest ? CGRect(x: 164, y: 64, width: 1720, height: 764) : Dashboard.content }
    /// The control was just clicked: shows a brief depressed state (a fraction of a second).
    private func isPressed(_ id: String) -> Bool { touchPending?.0.id == id || (pressed.map { $0.0 == id && CACurrentMediaTime() - $0.1 < 0.12 } ?? false) }
    /// Test hook: a fixed game list instead of the Steam library.
    var testLibrary: [Game]?
    private var library: [Game] { testLibrary ?? games.library }

    init(settings: Settings, games: Games) {
        self.settings = settings; self.games = games
        mainCtx = CGContext(data: nil, width: Dashboard.W, height: Dashboard.H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        mainCtx.translateBy(x: 0, y: CGFloat(Dashboard.H)); mainCtx.scaleBy(x: 1, y: -1)
        ctx = mainCtx
    }

    // MARK: notifications: grouped history (Notifications), pop-up toasts, actions
    struct Notice { let id: Int; var date: Date; let text: String; let kind: String; var count = 1; var action: (label: String, run: () -> Void)? = nil }
    private(set) var notices: [Notice] = [], unread = 0
    private var noticeSeq = 0, toastID: Int?, toastSince: CFTimeInterval = 0, toastUntil = Date.distantPast
    /// Notification groups, in this order (icon, colour); `noticeKind` guesses one from the text when the caller doesn't say.
    static let noticeKinds: [(kind: String, icon: String, color: UInt32)] = [
        ("Games", "controller", 0x3aa0ffff), ("Downloads", "download", 0x45c77fff), ("Connection", "wifi", 0xb07cffff), ("System", "bell", 0xff8f5aff),
    ]
    static func noticeKind(_ s: String) -> String {
        let l = s.lowercased()
        if ["download", "install"].contains(where: l.contains) { return "Downloads" }
        if ["launch", "quit", "game", "playing", "steam"].contains(where: l.contains) { return "Games" }
        if ["headset", "usb", "wi-fi", "connect", "stream", "video"].contains(where: l.contains) { return "Connection" }
        return "System"
    }
    func say(_ s: String) { sounds.play("error"); note(s, 3.5) }
    /// Toast + notification history (the dock bell). The same message again within a minute counts up instead of repeating.
    func note(_ s: String, _ secs: Double = 2.5, kind: String? = nil, action: (label: String, run: () -> Void)? = nil) {
        if let i = notices.firstIndex(where: { $0.text == s }), Date().timeIntervalSince(notices[i].date) < 60 {
            var n = notices.remove(at: i); n.count += 1; n.date = Date(); if action != nil { n.action = action }
            notices.insert(n, at: 0)
        } else {
            noticeSeq += 1
            notices.insert(Notice(id: noticeSeq, date: Date(), text: s, kind: kind ?? Dashboard.noticeKind(s), action: action), at: 0)
            notices = Array(notices.prefix(40))
        }
        if !(windowOpen && view == "notifications") { unread += 1 }
        guard !settings.bool("dnd") else { return }   // Do Not Disturb: collected, never popped up
        if !inPress { sounds.play("notify") }         // clicks already made their own sound
        toastID = notices[0].id; toastSince = CACurrentMediaTime(); toastUntil = Date().addingTimeInterval(secs)
        for t in [max(0, secs - 0.25), secs + 0.1] { DispatchQueue.global().asyncAfter(deadline: .now() + t) { [weak self] in self?.redraw() } }   // fade out, gone
    }
    func dismissNotice(_ id: Int) { notices.removeAll { $0.id == id }; if toastID == id { toastUntil = .distantPast }; sounds.play("dismiss"); redraw() }
    func clearNotices(_ kind: String? = nil) {
        notices.removeAll { kind == nil || $0.kind == kind }; unread = 0; toastUntil = .distantPast; flicks["notes"] = nil; sounds.play("dismiss"); redraw()
    }
    /// "Just now", "5 min ago", "3 h ago", "Yesterday", "4 days ago", then the date.
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        if s < 2 * 86400 { return "Yesterday" }
        if s < 7 * 86400 { return "\(Int(s / 86400)) days ago" }
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d)
    }
    /// Play time: "Under a minute", "42 min", "3 h", "3 h 12 min".
    static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        return m < 1 ? "Under a minute" : m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    // MARK: play history (App Library sort, details page, Home's "continue playing")
    static func lastPlayed(_ id: String) -> Double { UserDefaults.standard.double(forKey: "app.\(id).last") }
    static func playTime(_ id: String) -> Double { UserDefaults.standard.double(forKey: "app.\(id).played") }
    private var session: (id: String, since: Date)?
    /// A game started or stopped (Engine sets gameActive, then gameName): adds the session to its play time.
    private func trackPlay() {
        let id = gameActive ? games.playing(gameName)?.appid : nil
        guard id != session?.id else { return }
        if let s = session { UserDefaults.standard.set(Dashboard.playTime(s.id) + Date().timeIntervalSince(s.since), forKey: "app.\(s.id).played") }
        session = id.map { ($0, Date()) }
        if let id { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "app.\(id).last") }
    }

    /// Called when the menu opens: land on the running game, otherwise the library (the tutorial keeps its place).
    func opened() {
        capture = nil; menuFor = nil; powerOpen = false
        if view != "welcome" { view = gameActive ? "playing" : (view == "playing" || view == "keyboard" ? "library" : view) }
    }
    static var tutorialDone: Bool {
        get { UserDefaults.standard.bool(forKey: "oobe.done") } set { UserDefaults.standard.set(newValue, forKey: "oobe.done") }
    }
    /// First-run welcome tour (the Engine starts it on the first headset connection; Settings > About replays it).
    func startTutorial() { step = 0; nameDraft = Dashboard.userName; view = "welcome"; powerOpen = false; sounds.play("welcome"); redraw() }

    // MARK: input (uv from the SceneKit hit test, origin top-left)
    private func px(_ uv: CGPoint) -> CGPoint { CGPoint(x: uv.x * CGFloat(Dashboard.W), y: uv.y * CGFloat(inputSlot == 1 ? Dashboard.H : Dashboard.SPLIT)) }
    private func region(_ uv: CGPoint) -> Region? {
        let p = px(uv)
        return (inputSlot == 1 ? regions : sideRegions[inputSlot == 0 ? 0 : 1]).last { $0.r.contains(p) }
    }

    /// True where the menu is opaque (window, bars, dock, open keyboard); lasers pass through the transparent gaps.
    /// Called on the render queue (laser hit tests) while the menu draws on its own: reads a snapshot taken after each draw.
    func solid(_ uv: CGPoint, slot: Int = 1) -> Bool {
        if slot != 1 {   // a side window: its window and grab bar
            let p = CGPoint(x: uv.x * CGFloat(Dashboard.W), y: uv.y * CGFloat(Dashboard.SPLIT))
            solidLock.lock(); let open = sideOpen[slot == 0 ? 0 : 1]; solidLock.unlock()
            return open && (Dashboard.WIN.contains(p) || Dashboard.GRAB.contains(p))
        }
        let p = px(uv)
        solidLock.lock(); let (windowOpen, keyboardOpen, dock, extra) = solidState; solidLock.unlock()
        return windowOpen && (Dashboard.WIN.contains(p) || Dashboard.GRAB.contains(p) || Dashboard.dotRect(Dashboard.GRAB).contains(p))
            || dock.contains(p) || Dashboard.DOCKGRAB.contains(p) || Dashboard.dotRect(Dashboard.DOCKGRAB).contains(p)
            || (keyboardOpen && (Dashboard.KB.contains(p) || Dashboard.KBGRAB.contains(p) || Dashboard.dotRect(Dashboard.KBGRAB).contains(p)))
            || extra.contains { $0.contains(p) }
    }

    /// Hover update; returns true when the hovered element changed (for redraw + haptic tick).
    func pointer(_ uv: CGPoint?) -> Bool {
        let r = uv.flatMap { region($0) }
        if let uv, let r, r.id == "desktop", capture == nil, desktopTrusted { r.drag?(px(uv), 0); lastDesktopUV = uv }
        let id = r?.id
        let changed = id != hover || (id != nil && hoverSlot != inputSlot)
        defer { hover = id; if id != nil { hoverSlot = inputSlot } }
        if changed, id != nil, id != "desktop", !(id?.hasPrefix("power:dismiss") ?? false) { sounds.play("hover") }
        return changed
    }
    /// Trigger pressed. Buttons fire immediately; sliders and the desktop capture the drag; grab bars move panels.
    @discardableResult func press(_ uv: CGPoint) -> Press {
        guard let r = region(uv) else {
            if menuFor != nil { menuFor = nil; sounds.play("back") }   // click outside closes a context menu
            return .none
        }
        if r.id == "grab" { sounds.play("grab"); return .grabWindow }
        if r.id == "grabdock" { sounds.play("grab"); return .grabDock }
        if r.id == "grabkb" { sounds.play("grab"); return .grabKeyboard }
        if let d = r.drag { capture = r; d(px(uv), 1); return .handled }
        fire(r)
        return .handled
    }
    /// Runs a button at commit: a soft confirm when a window opens, else a tick.
    private func fire(_ r: Region) {
        if menuFor != nil && !r.id.hasPrefix("ctx:") && !r.id.hasPrefix("more:") { menuFor = nil }
        pressed = (r.id, CACurrentMediaTime()); animatingUntil = max(animatingUntil, CACurrentMediaTime() + 0.3)
        navved = false; inPress = true; r.fn?(); inPress = false
        sounds.play(navved ? "open" : "tap")
    }
    /// Direct touch: a fingertip landing on a control. Sliders and the Mac desktop act at once (and follow the finger);
    /// buttons and keys only light up and fire when the finger lifts (touchUp), like Horizon OS. Landing on a coasting
    /// list just stops it; holding a game tile opens its menu.
    private var touchPending: (Region, CGPoint)?, touchSince: CFTimeInterval = 0, touchPendingSlot = 1
    func touchDown(_ uv: CGPoint) {
        let p0 = px(uv)
        if Dashboard.WIN.contains(p0), !powerOpen, let k = scrollKey {
            var f = flicks[k] ?? Flick()
            let coasting = abs(f.vel) > 250
            f.grab(at: CACurrentMediaTime()); flicks[k] = f
            touchScroll = (p0.y, p0.x, f.pos, coasting, k)   // a swipe may scroll instead
            if coasting { return }
        }
        guard let r = region(uv), !r.id.hasPrefix("grab") else { return }
        if let d = r.drag { capture = r; d(px(uv), 1); return }
        touchPending = (r, px(uv)); touchSince = CACurrentMediaTime(); touchPendingSlot = inputSlot; sounds.play("hover")
        if r.id.hasPrefix("tile:") { animatingUntil = max(animatingUntil, touchSince + 0.7) }   // long-press ring
    }
    /// Finger lifted: fires the touched button if the finger is still on it (a few px of slide while lifting is fine).
    func touchUp(_ uv: CGPoint?) {
        if let s = touchScroll { flicks[s.key]?.release(at: CACurrentMediaTime()); animatingUntil = max(animatingUntil, CACurrentMediaTime() + 0.05) }
        touchScroll = nil
        if capture != nil { release(uv); return }
        guard let (r, at) = touchPending else { return }
        touchPending = nil
        let p = uv.map(px) ?? at
        // fingers slide while tapping: it still counts unless the finger travelled ~4 cm (a drag away), or it became a scroll
        guard r.r.insetBy(dx: -40, dy: -40).contains(p) || hypot(p.x - at.x, p.y - at.y) < 115 else { return }
        fire(r)
    }
    func drag(_ uv: CGPoint) {
        if let c = capture { c.drag?(px(uv), 2); return }
        guard var s = touchScroll else { return }
        let p = px(uv), dy = p.y - s.y0
        if !s.active && abs(dy) > 60 && abs(dy) > abs(p.x - s.x0) { s.active = true; s.y0 = p.y; touchPending = nil }   // ~2 cm up/down: a scroll, not a tap
        if s.active { flicks[s.key]?.drag(to: s.off0 - (p.y - s.y0), at: CACurrentMediaTime()) }
        touchScroll = s
    }
    /// Touch / pinch drag-to-scroll: where the finger landed, the list's offset then, and which list.
    private var touchScroll: (y0: CGFloat, x0: CGFloat, off0: CGFloat, active: Bool, key: String)?
    /// Scrolling lists by view (nil: the view doesn't scroll).
    private var scrollKey: String? { ["library": "library", "keyboard": "library", "settings": "settings", "notifications": "notes"][view] }
    private var flicks: [String: Flick] = [:]
    /// Hand-tracking pinch: grab bars grab at once; everything else acts like a touch (fires on release, drag scrolls).
    func pinchDown(_ uv: CGPoint) -> Press {
        if let r = region(uv), r.id.hasPrefix("grab") { return press(uv) }
        touchDown(uv); return .handled
    }
    func release(_ uv: CGPoint?) {
        if let c = capture { c.drag?(uv.map(px) ?? CGPoint(x: -1e4, y: -1e4), 3) }   // no uv: release in place, off-panel
        capture = nil
    }
    /// One-shot click (tests): press + release.
    func click(_ uv: CGPoint) { if press(uv) == .handled { release(uv) } }
    /// Grip: right click on the desktop; the "..." menu on a library tile; a game's details from Home or the dock.
    func secondary(_ uv: CGPoint) {
        guard let r = region(uv) else { return }
        if r.id == "desktop", let n = desktopNormalized(px(uv)) { desktopRightClick(n); sounds.play("tap") }
        if r.id.hasPrefix("tile:") { menuFor = String(r.id.dropFirst(5)); sounds.play("open") }
        for p in ["home:game:", "dock:game:"] where r.id.hasPrefix(p) {
            if let g = library.first(where: { $0.appid == r.id.dropFirst(p.count) }) { showDetails(g); sounds.play("open") }
        }
    }
    /// Thumbstick Y on the hovered view: scrolls lists, or scrolls the Mac. Returns true if something changed.
    func scroll(_ dy: Float, at uv: CGPoint) -> Bool {
        let r = region(uv)
        if r?.id == "desktop" { desktopScroll(Int32((dy * 18).rounded())); return false }
        // anywhere over the window scrolls it (not only over a tile: gaps between tiles used to stop the scroll dead)
        guard Dashboard.WIN.contains(px(uv)), let k = scrollKey, var f = flicks[k] else { return false }
        let o = f.pos
        f.set(f.pos - CGFloat(dy) * 28); flicks[k] = f
        if abs(f.pos - scrollTick) > 120 { scrollTick = f.pos; sounds.play("tick") }   // detent ticks while scrolling
        return o != f.pos
    }
    private var scrollTick: CGFloat = 0

    func nav(_ id: String) {
        if id == "overview" && view != "overview" { overviewReturn = safeWorkspaceView(view) }
        if id == "commands" && view != "commands" { commandQuery = ""; commandPage = 0; commandKeyboard = false }
        menuFor = nil
        if id == "power" { togglePower(); return }
        powerOpen = false
        if view != id || !windowOpen {
            if quest && windowOpen && inputSlot == 1 && !["welcome", "keyboard"].contains(view) { windowJump() }   // replaces the centre window
            if !navigatingBack && view != id && view != "welcome" {
                navigationHistory[inputSlot].append(view == "keyboard" ? "library" : view)
                navigationHistory[inputSlot] = Array(navigationHistory[inputSlot].suffix(16))
            }
            view = id; if inPress { navved = true } else { sounds.play("pop") }
        }
        if id == "notifications" { unread = 0 }
        if id != "settings" { settingsSearch = false }
        redraw()
    }
    /// Mac Desktop, or a way to switch it on when Settings hides it.
    private func openDesktop() {
        if settings.bool("show_desktop_tabs") { nav("desktop"); return }
        note("Mac Desktop is turned off", 4, kind: "System", action: ("Turn On", { [unowned self] in settings.set("show_desktop_tabs", "On"); view = "desktop"; redraw() }))
    }
    private func showDetails(_ g: Game) { menuFor = nil; settingsFor = g; nav("appsettings") }
    /// Jumps to a setting (from search): its section, scrolled into view, flashing once.
    private func openSetting(_ key: String) {
        section = Dashboard.sectionKeys.first { $0.value.contains(key) }?.key ?? section
        settingsQuery = ""; settingsSearch = false; highlight = (key, CACurrentMediaTime()); reveal = key
        nav("settings")
    }

    // MARK: power menu (dock power button, Quick Settings)
    private var powerOpen = false, quitArmed = false
    func togglePower() {
        powerOpen.toggle(); quitArmed = false; menuFor = nil
        if powerOpen { windowOpen = true }
        if inPress { navved = powerOpen } else { sounds.play(powerOpen ? "open" : "back") }
        redraw()
    }

    private func goBack() {
        guard let previous = navigationHistory[inputSlot].popLast() else { return }
        navigatingBack = true
        nav(previous == "playing" && !gameActive ? "home" : previous)
        navigatingBack = false
    }

    // MARK: motion: eased values, view transitions, flick physics (all instant with Reduce Motion)
    private var now: CFTimeInterval = 0, dt: CGFloat = 1.0 / 60, lastDraw: CFTimeInterval = 0
    private var eased: [String: CGFloat] = [:]
    private func keepAnimating(_ s: CFTimeInterval = 0.1) { animatingUntil = max(animatingUntil, now + s) }
    /// Moves a per-control value smoothly toward `target` and keeps the Engine redrawing until it settles.
    private func ease(_ key: String, _ target: CGFloat, speed: CGFloat = 16) -> CGFloat {
        let k = "\(drawingSlot)/" + key
        guard !reduceMotion, let v0 = eased[k] else { eased[k] = target; return target }
        var v = v0 + (target - v0) * (1 - exp(-speed * dt))
        if abs(target - v) < 0.004 { v = target } else { keepAnimating() }
        eased[k] = v
        return v
    }
    private var shownKey = "", shownSince: CFTimeInterval = 0
    /// Window content fades and rises into place when the app (or tour step, or game page) changes.
    private func transition(_ body: () -> Void) {
        let key = view + (view == "welcome" ? "\(step)" : view == "appsettings" ? settingsFor?.appid ?? "" : "")
        if key != shownKey { shownKey = key; shownSince = now }
        let p = reduceMotion ? 1 : min(1, CGFloat(now - shownSince) / 0.28)
        guard p < 1 else { body(); return }
        keepAnimating()
        let e = 1 - pow(1 - p, 3)
        ctx.saveGState(); ctx.setAlpha(e); ctx.translateBy(x: 0, y: 30 * (1 - e))
        ctx.beginTransparencyLayer(in: Dashboard.WIN, auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer(); ctx.restoreGState()
    }
    /// Hover lift for cards and tiles: eases a little bigger with a soft shadow and a fading focus ring; a press sinks it.
    private func lifted(_ id: String, _ r: CGRect, _ rad: CGFloat, hot: Bool, ring: Bool = true, _ body: (CGRect) -> Void) {
        let t = ease("lift:" + id, isPressed(id) ? -1 : hot ? 1 : 0)
        let k = 1 + 0.035 * t, b = CGRect(x: r.midX - r.width * k / 2, y: r.midY - r.height * k / 2, width: r.width * k, height: r.height * k)
        if t > 0.02 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -12 * t), blur: 36 * t, color: CGColor(gray: 0, alpha: 0.6 * t))
            ctx.setFillColor(col(0x1a242bff)); ctx.addPath(path(b.insetBy(dx: 3, dy: 3), rad)); ctx.fillPath()
            ctx.restoreGState()
        }
        body(b)
        if ring && t > 0.02 { outline(b.insetBy(dx: -5, dy: -5), rad + 5, 0xffffff00 | UInt32(min(1, t) * 225), 3) }
    }

    // MARK: drawing helpers
    @discardableResult
    private func btn(_ id: String, _ r: CGRect, _ fn: @escaping () -> Void) -> Bool {
        regions.append(Region(id: id, r: r, fn: fn, drag: nil)); return hover == id && hoverSlot == drawingSlot
    }
    private func dragRegion(_ id: String, _ r: CGRect, _ d: @escaping (CGPoint, Int) -> Void) -> Bool {
        regions.append(Region(id: id, r: r, fn: nil, drag: d)); return hover == id && hoverSlot == drawingSlot || capture?.id == id
    }
    private func path(_ r: CGRect, _ rad: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: min(rad, r.width / 2), cornerHeight: min(rad, r.height / 2), transform: nil)
    }
    private func rr(_ r: CGRect, _ rad: CGFloat, _ c: UInt32) { ctx.setFillColor(col(c)); ctx.addPath(path(r, rad)); ctx.fillPath() }
    private func outline(_ r: CGRect, _ rad: CGFloat, _ c: UInt32, _ w: CGFloat = 3) {
        ctx.setStrokeColor(col(c)); ctx.setLineWidth(contrast ? w * 1.6 : w); ctx.addPath(path(r, rad)); ctx.strokePath()
    }
    /// Restrained depth on app tiles, with the same contrast in both shell styles.
    private func grad(_ r: CGRect, _ rad: CGFloat, _ top: UInt32, _ bottom: UInt32) {
        if quest { rr(r, rad, top); return }
        ctx.saveGState(); ctx.addPath(path(r, rad)); ctx.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [col(top), col(bottom)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        }
        ctx.restoreGState()
    }
    /// Darkens art toward one edge so text over it stays readable (`fromLeft`: left side darkest, else the bottom).
    private func scrim(_ r: CGRect, _ rad: CGFloat, fromLeft: Bool = false, strength: CGFloat = 0.85) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(srgbRed: 0.03, green: 0.06, blue: 0.08, alpha: strength),
                                 CGColor(srgbRed: 0.03, green: 0.06, blue: 0.08, alpha: strength * 0.45), CGColor(srgbRed: 0.03, green: 0.06, blue: 0.08, alpha: 0)] as CFArray,
                                 locations: [0, 0.45, 1]) else { return }
        ctx.saveGState(); ctx.addPath(path(r, rad)); ctx.clip()
        ctx.drawLinearGradient(g, start: fromLeft ? CGPoint(x: r.minX, y: r.midY) : CGPoint(x: r.midX, y: r.maxY),
                               end: fromLeft ? CGPoint(x: r.maxX, y: r.midY) : CGPoint(x: r.midX, y: r.minY), options: [])
        ctx.restoreGState()
    }
    /// Quest style: the same layouts in neutral greys with Meta's blue (SteamVR style keeps its blue-grey slate).
    private static let questPalette: [UInt32: UInt32] = [   // Horizon OS slate (sampled from the headset's own UI)
        0x1f252dff: 0x243039ff, 0x353d49ff: 0x46525dff, 0x4f5a69ff: 0x56636fff, 0x2a313aff: 0x3a4550ff, 0x2c343fff: 0x34404aff,
        0x303945ff: 0x34404aff, 0x3c4654ff: 0x3d4a55ff, 0x3a4452ff: 0x46525dff, 0x56606eff: 0x56636fff, 0x46505eff: 0x515e69ff,
        0x4a5462ff: 0x4f5c67ff, 0x5a6472ff: 0x5d6a75ff, 0x222932ff: 0x1d2830ff, 0x323b47ff: 0x34404aff, 0x3c4755ff: 0x3d4a55ff,
        0x1b2129ff: 0x1f2b33ff, 0x2f3742ff: 0x34404aff, 0x0d1117ff: 0x1a242bff, 0x15181df2: 0x1c272ef2,
        0x2d8cffff: 0x2a73f5ff, 0x4a9dffff: 0x4a88f7ff, 0x9aa3afff: 0xa4adb4ff, 0xc9cfd8ff: 0xd2d8dcff, 0xd8dde4ff: 0xe0e5e8ff,
    ]
    /// High Contrast (Settings > Accessibility): secondary text goes white, panels near black, controls a step brighter.
    private static let contrastPalette: [UInt32: UInt32] = [
        0xa4adb4ff: 0xffffffff, 0xd2d8dcff: 0xffffffff, 0xe0e5e8ff: 0xffffffff, 0xc0c8ceff: 0xffffffff, 0xdfe3e8ff: 0xffffffff,
        0x9aa3afff: 0xffffffff, 0xc9cfd8ff: 0xffffffff, 0xd8dde4ff: 0xffffffff, 0x8a93a0ff: 0xe8e8e8ff, 0x9cd7ffff: 0xc8ecffff,
        0x243039ff: 0x05080bff, 0x1a242bff: 0x000000ff, 0x1f2b33ff: 0x05080bff, 0x1f252dff: 0x05080bff, 0x1b2129ff: 0x05080bff,
        0x34404aff: 0x26343eff, 0x2c343fff: 0x26343eff, 0x46525dff: 0x3c4d5aff, 0x34434bff: 0x26343eff,
        0xffffff1c: 0xffffff40, 0xffffffb0: 0xffffffff, 0x00000040: 0x00000080,
    ]
    private func col(_ c: UInt32) -> CGColor {   // 0xRRGGBBAA
        var c = quest ? Dashboard.questPalette[c] ?? c : c
        if contrast { c = Dashboard.contrastPalette[c] ?? c }
        return CGColor(srgbRed: CGFloat(c >> 24 & 255) / 255, green: CGFloat(c >> 16 & 255) / 255, blue: CGFloat(c >> 8 & 255) / 255, alpha: CGFloat(c & 255) / 255)
    }
    /// Button background; hover is a lighter flat fill.
    private func face(_ r: CGRect, _ rad: CGFloat, on: Bool, base: UInt32 = 0x353d49ff, hot: UInt32 = 0x4f5a69ff) {
        rr(r, rad, on && (touchPending != nil || pressed.map({ CACurrentMediaTime() - $0.1 < 0.12 }) == true) ? 0x2a313aff : on ? hot : base)
    }
    private func font(_ size: CGFloat, _ bold: Bool) -> NSFont {
        var f = NSFont.systemFont(ofSize: max(size, 26) * textScale, weight: bold ? .semibold : .medium)   // VR legibility floor; Quest text is medium, not bold
        if quest, let d = f.fontDescriptor.withDesign(.rounded) { f = NSFont(descriptor: d, size: f.pointSize) ?? f }   // Horizon OS's rounded type
        return f
    }
    private func line(_ s: String, _ f: NSFont, _ c: UInt32) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: NSColor(cgColor: col(c))!]))
    }
    /// Width of `s` as `txt` would draw it.
    private func textW(_ s: String, _ size: CGFloat, bold: Bool = false) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(s, font(size, bold), 0xffffffff), nil, nil, nil))
    }
    private func txt(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: UInt32 = 0xffffffff, bold: Bool = false,
                     align: CGFloat = 0, maxW: CGFloat = 5000) {
        let f = font(size, bold)
        var str = s, l = line(s, f, c)
        while CTLineGetTypographicBounds(l, nil, nil, nil) > maxW, str.count > 1 { str = String(str.dropLast(2)) + "…"; l = line(str, f, c) }
        let w = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x - w * align, y: y)
        CTLineDraw(l, ctx)
        ctx.restoreGState()
    }
    /// Word-wraps `s` into lines no wider than `maxW` (at most `maxLines`, the last one ellipsized).
    private func wrap(_ s: String, _ size: CGFloat, _ maxW: CGFloat, maxLines: Int = 6, bold: Bool = false) -> [String] {
        var lines: [String] = [], cur = ""
        for w in s.split(separator: " ") {
            let next = cur.isEmpty ? String(w) : cur + " " + w
            if !cur.isEmpty && textW(next, size, bold: bold) > maxW { lines.append(cur); cur = String(w) } else { cur = next }
        }
        if !cur.isEmpty { lines.append(cur) }
        if lines.count > maxLines { lines = Array(lines.prefix(maxLines)); lines[maxLines - 1] += "…" }
        return lines
    }
    /// A wrapped paragraph; returns the height it used.
    @discardableResult private func para(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: UInt32, maxW: CGFloat, maxLines: Int = 6, bold: Bool = false) -> CGFloat {
        let lh = max(size, 26) * 1.38 * textScale, lines = wrap(s, size, maxW, maxLines: maxLines, bold: bold)
        for (i, l) in lines.enumerated() { txt(l, x, y + CGFloat(i) * lh, size, c, bold: bold, maxW: maxW) }
        return CGFloat(lines.count) * lh
    }
    private func cover(_ img: CGImage?, _ r: CGRect, _ name: String, rad: CGFloat = 14) {
        ctx.saveGState()
        ctx.addPath(path(r, rad)); ctx.clip()
        if let img {
            let s = max(r.width / CGFloat(img.width), r.height / CGFloat(img.height))
            let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
            ctx.translateBy(x: r.midX - w / 2, y: r.midY + h / 2); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
        } else {
            ctx.setFillColor(col(0x2f3742ff)); ctx.fill(r)
            ctx.restoreGState()
            txt(name, r.midX, r.midY + 10, 28, 0xd6dae0ff, bold: true, align: 0.5, maxW: r.width - 24)
        }
    }

    private static var svgCache: [String: CGImage] = [:]
    /// Lucide icon (ISC), bundled as SVG, rasterized white at `px`; nil outside the app bundle (tests) -> drawn glyph.
    private static func svgIcon(_ n: String, px: Int) -> CGImage? {
        let key = "\(n)@\(px)"
        if let c = svgCache[key] { return c }
        guard let u = Bundle.main.url(forResource: n, withExtension: "svg", subdirectory: "icons"),
              let src = try? String(contentsOf: u, encoding: .utf8),
              let img = NSImage(data: Data(src.replacingOccurrences(of: "currentColor", with: "#ffffff").utf8)) else { return nil }
        var r = CGRect(x: 0, y: 0, width: px, height: px)
        guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return nil }
        svgCache[key] = cg
        return cg
    }
    private func icon(_ n: String, _ cx: CGFloat, _ cy: CGFloat, _ c: UInt32, _ s: CGFloat = 1.4) {
        let size = 34 * s
        if let img = Dashboard.svgIcon(n, px: Int(size * 2)) {   // tinted: draw white, then recolour with source-in
            let r = CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)
            ctx.saveGState(); ctx.beginTransparencyLayer(in: r.insetBy(dx: -2, dy: -2), auxiliaryInfo: nil)
            ctx.saveGState(); ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(origin: .zero, size: r.size)); ctx.restoreGState()
            ctx.setBlendMode(.sourceIn); ctx.setFillColor(col(c)); ctx.fill(r.insetBy(dx: -2, dy: -2))
            ctx.endTransparencyLayer(); ctx.restoreGState()
            return
        }
        // drawn glyphs (our own; also the fallback for the Lucide set in tests), on a 34 px grid around the centre
        ctx.saveGState(); ctx.translateBy(x: cx, y: cy); ctx.scaleBy(x: s, y: s)
        ctx.beginTransparencyLayer(in: CGRect(x: -20, y: -20, width: 40, height: 40), auxiliaryInfo: nil)
        ctx.setStrokeColor(col(c)); ctx.setFillColor(col(c)); ctx.setLineWidth(3.2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        func L(_ p: CGFloat...) { ctx.move(to: CGPoint(x: p[0], y: p[1])); stride(from: 2, to: p.count, by: 2).forEach { ctx.addLine(to: CGPoint(x: p[$0], y: p[$0 + 1])) }; ctx.strokePath() }
        func C(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ a0: CGFloat = 0, _ a1: CGFloat = 2 * .pi) { ctx.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: a0, endAngle: a1, clockwise: false); ctx.strokePath() }
        func D(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) { ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
        switch n {
        case "home": L(-17, -2, 0, -17, 17, -2); L(-12, -5, -12, 15, -4, 15, -4, 4, 4, 4, 4, 15, 12, 15, 12, -5)
        case "grid": for (x, y) in [(-14, -14), (2, -14), (-14, 2), (2, 2)] { ctx.addPath(path(CGRect(x: x, y: y, width: 12, height: 12), 3)); ctx.fillPath() }
        case "apps": for x in [-11, 0, 11] as [CGFloat] { for y in [-11, 0, 11] as [CGFloat] { D(x, y, 3.2) } }
        case "play": ctx.move(to: CGPoint(x: -9, y: -14)); ctx.addLine(to: CGPoint(x: 14, y: 0)); ctx.addLine(to: CGPoint(x: -9, y: 14)); ctx.closePath(); ctx.fillPath()
        case "gear": C(0, 0, 11); C(0, 0, 4); for a in 0..<8 { let s = sin(CGFloat(a) * .pi / 4), k = cos(CGFloat(a) * .pi / 4); L(s * 11, k * 11, s * 16, k * 16) }
        case "power": C(0, 2, 14, -.pi / 2 + 0.7, 1.5 * .pi - 0.7); L(0, -16, 0, 0)
        case "monitor": ctx.stroke(CGRect(x: -18, y: -14, width: 36, height: 24)); L(-8, 17, 8, 17); L(0, 10, 0, 17)
        case "recenter": C(0, 0, 12); C(0, 0, 3); L(0, -18, 0, -12); L(0, 12, 0, 18); L(-18, 0, -12, 0); L(12, 0, 18, 0)
        case "back": L(8, -12, -4, 0, 8, 12)
        case "next": L(-4, -12, 8, 0, -4, 12)
        case "search": C(-3, -3, 9); L(4, 4, 12, 12)
        case "usb": L(0, -16, 0, 16); L(0, -16, -4, -10); L(0, -16, 4, -10); L(0, 4, -8, -2, -8, -6); L(0, 8, 8, 2, 8, -2); C(0, 16, 3)
        case "wifi": C(0, 12, 20, -.pi * 0.75, -.pi * 0.25); C(0, 12, 12, -.pi * 0.75, -.pi * 0.25); D(0, 12, 3)
        case "sliders": for y in [-10, 0, 10] as [CGFloat] { L(-16, y, 16, y); C(y < 0 ? -6 : y > 0 ? 6 : 0, y, 4.5) }
        case "speaker": L(-14, -6, -6, -6, 2, -14, 2, 14, -6, 6, -14, 6, -14, -6); C(4, 0, 9, -.pi / 3, .pi / 3)
        case "sun": C(0, 0, 7); for a in 0..<8 { let s = sin(CGFloat(a) * .pi / 4), k = cos(CGFloat(a) * .pi / 4); L(s * 11, k * 11, s * 16, k * 16) }
        case "floor": L(-16, 10, 16, 10); L(-10, 2, 10, 2); L(-6, -6, 6, -6); L(-16, 10, -6, -6); L(16, 10, 6, -6); L(0, 10, 0, -6)
        case "gauge": C(0, 6, 15, .pi, 2 * .pi); L(0, 6, 8, -4)
        case "check": L(-12, 0, -3, 9, 12, -9)
        case "x": L(-10, -10, 10, 10); L(10, -10, -10, 10)
        case "keyboard": ctx.stroke(CGRect(x: -18, y: -11, width: 36, height: 22)); for x in [-11, -3, 5, 12] as [CGFloat] { D(x, -4, 1.4) }; L(-10, 5, 10, 5)
        case "refresh": C(0, 0, 13, -.pi * 0.2, .pi * 1.6); L(13, -12, 11, -3, 3, -6)
        case "download": L(0, -15, 0, 7); L(-8, -1, 0, 7, 8, -1); L(-14, 15, 14, 15)
        case "controller": L(-14, -4, -9, -10, 9, -10, 14, -4, 16, 8, 10, 12, 5, 4, -5, 4, -10, 12, -16, 8, -14, -4); C(-7, -3, 2); C(7, -3, 2)
        case "bell": ctx.move(to: CGPoint(x: -12, y: 8)); ctx.addLine(to: CGPoint(x: -9, y: 3)); ctx.addLine(to: CGPoint(x: -9, y: -4))
            ctx.addArc(center: CGPoint(x: 0, y: -4), radius: 9, startAngle: .pi, endAngle: 0, clockwise: false)
            ctx.addLine(to: CGPoint(x: 9, y: 3)); ctx.addLine(to: CGPoint(x: 12, y: 8)); ctx.closePath(); ctx.fillPath(); D(0, 12, 3)
        case "steam": C(0, 0, 15); D(5, -4, 5); L(5, -4, -8, 6); D(-8, 6, 3.5)
        case "globe": C(0, 0, 14); L(-14, 0, 14, 0); ctx.addEllipse(in: CGRect(x: -6, y: -14, width: 12, height: 28)); ctx.strokePath()
        case "info": C(0, 0, 14); L(0, -1, 0, 8); D(0, -7, 2)
        case "code": L(-6, -10, -15, 0, -6, 10); L(6, -10, 15, 0, 6, 10)
        case "person": C(0, -6, 6); C(0, 16, 12, .pi * 1.15, .pi * 1.85)
        case "pin": L(0, 4, 0, 16); ctx.addPath(path(CGRect(x: -8, y: -14, width: 16, height: 14), 4)); ctx.fillPath(); L(-12, 2, 12, 2)
        case "trash": L(-12, -9, 12, -9); L(-4, -9, -4, -13, 4, -13, 4, -9); ctx.addPath(path(CGRect(x: -9, y: -6, width: 18, height: 20), 3)); ctx.strokePath()
        case "mountain": L(-16, 12, -4, -6, 3, 4, 8, -2, 16, 12, -16, 12); D(8, -10, 3)
        case "hand": L(-6, 14, -6, -6); L(-6, -2, -1, -12, -1, 4); L(-1, -2, 4, -10, 4, 4); L(4, 0, 9, -6, 9, 8, 4, 16, -6, 16)
        // MacVR's own glyphs (no Lucide file)
        case "access": C(0, 0, 16); D(0, -8, 3); L(-9, -2, 9, -2); L(0, -2, 0, 5, -5, 12); L(0, 5, 5, 12)
        case "sort": L(-14, -10, 14, -10); L(-14, 0, 6, 0); L(-14, 10, -2, 10)
        case "chevron": L(-8, -4, 0, 4, 8, -4)
        case "moon": D(0, 0, 14); ctx.setBlendMode(.clear); D(8, -7, 12); ctx.setBlendMode(.normal)
        case "text": L(-16, -12, 4, -12); L(-6, -12, -6, 14); L(4, -2, 16, -2); L(10, -2, 10, 14)
        case "contrast": C(0, 0, 14); ctx.move(to: CGPoint(x: 0, y: -14)); ctx.addArc(center: .zero, radius: 14, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false); ctx.closePath(); ctx.fillPath()
        case "motion": C(0, 0, 14); L(-6, 0, 6, 0); L(2, -5, 7, 0, 2, 5)
        case "headset": ctx.addPath(path(CGRect(x: -18, y: -10, width: 36, height: 20), 8)); ctx.strokePath(); L(-5, 10, 0, 4, 5, 10); D(-8, 0, 2.5); D(8, 0, 2.5)
        case "exit": L(-4, -14, -14, -14, -14, 14, -4, 14); L(-2, 0, 15, 0); L(9, -6, 15, 0, 9, 6)
        case "clock": C(0, 0, 14); L(0, -8, 0, 0, 6, 4)
        case "star": ctx.move(to: CGPoint(x: 0, y: -16))
            for i in 1..<10 { let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5, r: CGFloat = i % 2 == 0 ? 16 : 7; ctx.addLine(to: CGPoint(x: cos(a) * r, y: sin(a) * r)) }
            ctx.closePath(); ctx.fillPath()
        case "mic": ctx.addPath(path(CGRect(x: -6, y: -16, width: 12, height: 20), 6)); ctx.strokePath(); C(0, -2, 11, 0, .pi); L(0, 9, 0, 15)
        case "theater": ctx.addPath(path(CGRect(x: -16, y: -6, width: 32, height: 20), 3)); ctx.strokePath(); L(-16, -6, -12, -14, 14, -14, 16, -6)
        case "tips": C(0, -4, 10, .pi * 0.8, .pi * 2.2); L(-5, 8, 5, 8); L(-3, 14, 3, 14)
        default: break
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Slider: point anywhere on it and hold the trigger to drag the value. `set` gets 0-1.
    private func slider(_ id: String, _ r: CGRect, _ value: Float, _ set: @escaping (Float) -> Void) {
        let on = dragRegion(id, r.insetBy(dx: -10, dy: -18)) { [unowned self] p, phase in
            guard phase != 3 else { sounds.play("slider"); return }
            set(min(1, max(0, Float((p.x - r.minX - 22) / (r.width - 44))))); redraw()
        }
        rr(CGRect(x: r.minX, y: r.midY - 8, width: r.width, height: 16), 8, 0x4a5462ff)
        rr(CGRect(x: r.minX, y: r.midY - 8, width: 22 + CGFloat(value) * (r.width - 44), height: 16), 8, 0x2d8cffff)
        let g = ease("knob:" + id, on ? 1 : 0, speed: 22) * 5
        let k = CGRect(x: r.minX + CGFloat(value) * (r.width - 44), y: r.midY - 22, width: 44, height: 44)
        rr(k.insetBy(dx: -g, dy: -g), 26, 0xffffffff)
    }
    private func toggle(_ r: CGRect, _ on: Bool, id: String = "") {
        let t = ease("tog:" + id + "\(r.minX),\(r.minY)", on ? 1 : 0, speed: 20)
        rr(r, r.height / 2, on ? 0x2d8cffff : 0x5a6472ff)
        let d = r.height - 10
        rr(CGRect(x: r.minX + 5 + t * (r.width - d - 10), y: r.minY + 5, width: d, height: d), d / 2, 0xffffffff)
    }
    /// Segmented control (one row of options); the selection slides between them. Hit areas stay inside `clip`.
    private func segmented(_ id: String, _ r: CGRect, _ opts: [String], _ sel: Int, clip: CGRect? = nil, _ pick: @escaping (Int) -> Void) {
        rr(r, 18, 0x222932ff)
        let w = r.width / CGFloat(opts.count)
        func cell(_ i: CGFloat) -> CGRect { CGRect(x: r.minX + i * w + 5, y: r.minY + 5, width: w - 10, height: r.height - 10) }
        rr(cell(ease("seg:" + id, CGFloat(sel), speed: 18)), 14, 0x2d8cffff)
        for (i, o) in opts.enumerated() {
            let c = cell(CGFloat(i)), hit = clip.map { c.intersection($0) } ?? c
            let h = hit.height > 20 && btn("\(id):\(i)", hit) { [unowned self] in pick(i); sounds.play("on"); redraw() }
            if h && i != sel { face(c, 14, on: true) }
            txt(o, c.midX, c.midY + 10, 26, i == sel ? 0xffffffff : 0xc9cfd8ff, bold: i == sel, align: 0.5, maxW: c.width - 12)
        }
    }
    private func clipped(_ r: CGRect, _ body: () -> Void) { ctx.saveGState(); ctx.clip(to: r); body(); ctx.restoreGState() }
    private func status(_ extra: [String]) -> String {
        let battery = headsetBattery < 0 ? "" : "\(headsetBattery)%" + (headsetCharging ? " charging" : "")
        return ([headset.label, battery, linkStatus, streamInfo] + extra).filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }
    private func scrollbar(_ area: CGRect, _ off: CGFloat, _ maxOff: CGFloat) {   // thumb shrinks while rubber-banding
        guard maxOff > 0 else { return }
        let track = CGRect(x: area.maxX + 12, y: area.minY, width: 8, height: area.height)
        rr(track, 4, 0xffffff22)
        let over = off < 0 ? -off : off > maxOff ? off - maxOff : 0
        let hgt = max(40, track.height * track.height / (track.height + maxOff) - over * 0.5)
        let y = track.minY + (track.height - hgt) * min(1, max(0, off / maxOff))
        rr(CGRect(x: track.minX, y: y, width: 8, height: hgt), 4, 0xffffffaa)
    }
    /// Section caption: small caps label in grey.
    private func caption(_ s: String, _ x: CGFloat, _ y: CGFloat) { txt(s.uppercased(), x, y, 23, 0xa4adb4ff, bold: true) }
    /// Stream bitrate as the Engine applies it (Auto: 100 Mbps over USB, 40 over Wi-Fi).
    private var mbps: Int { settings["bitrate"] == "Auto" ? (linkStatus == "USB" ? 100 : 40) : settings.int("bitrate") }

    // MARK: app icons (flat colour tiles)
    private static let apps: [String: (icon: String, label: String, top: UInt32, bottom: UInt32)] = [
        "overview": ("grid", "Workspace", 0x737ceaff, 0x424ca2ff),
        "commands": ("search", "Search", 0x36bbaeff, 0x186879ff),
        "home": ("home", "Home", 0x538ff5ff, 0x2758baff),
        "spaces": ("home", "Spaces", 0x39aa98ff, 0x206b79ff),
        "playing": ("play", "Now Playing", 0x3aa0ffff, 0x1467e0ff),
        "desktop": ("monitor", "Mac Desktop", 0xb07cffff, 0x7040e0ff),
        "quick": ("sliders", "Quick Settings", 0xffb23dff, 0xf07b12ff),
        "settings": ("gear", "Settings", 0x4fd18bff, 0x1f9d5cff),
        "steam": ("steam", "Steam", 0x1b2838ff, 0x0e141cff),
        "tips": ("tips", "Tips", 0x3ad1c6ff, 0x1a9a9aff),
        "theater": ("theater", "Theater", 0x4a4f63ff, 0x1c1e2aff),
        "appsettings": ("gear", "Game Details", 0x4fd18bff, 0x1f9d5cff),
        "library": ("apps", "App Library", 0x6b7685ff, 0x4a5462ff),
        "notifications": ("bell", "Notifications", 0xff6b8bff, 0xe0386aff),
    ]
    private func appIcon(_ id: String, _ r: CGRect, hot: Bool) {
        guard let a = Dashboard.apps[id] else { return }
        let big = hot ? r.insetBy(dx: -5, dy: -5) : r
        if id == "playing", let art = playingArt {   // Now Playing shows the game you're in
            cover(art, big, "", rad: big.width * 0.26); return
        }
        grad(big, big.width * 0.26, a.top, a.bottom)
        if id == "steam", let logo = games.steamIcon {   // the real Steam logo from the user's Steam install
            let s = big.width * 0.72
            cover(logo, CGRect(x: big.midX - s / 2, y: big.midY - s / 2, width: s, height: s), "", rad: s / 2); return
        }
        icon(a.icon, big.midX, big.midY, 0xffffffff, big.width / 70)
    }
    /// Opens a built-in app from a tile (App Library, search).
    private func openApp(_ id: String) {
        switch id {
        case "steam": openSteam(); openDesktop(); note("Opening Steam on the Mac desktop", kind: "Games")
        case "tips": startTutorial()
        case "theater": theater(!theaterOn); note(theaterOn ? "Theater mode" : "Theater off")
        case "desktop": openDesktop()
        default: nav(id)
        }
    }

    private var playingGame: Game? { gameActive ? games.playing(gameName) : nil }
    private var playingArt: CGImage? { playingGame.flatMap { games.image($0.appid, "library_600x900") } }

    // MARK: window chrome
    private var title: String {
        switch view {
        case "keyboard": return "App Library"
        case "welcome": return "Welcome to MacVR OS"
        default: return Dashboard.apps[view]?.label ?? "App Library"
        }
    }
    private func chrome() {
        let w = Dashboard.WIN
        if quest { questChrome(); return }
        rr(w, 40, 0x1f252dff)   // flat panel
        txt(title, w.midX, w.minY + 60, 30, 0xd8dde4ff, bold: true, align: 0.5)
        if view == "desktop" {   // keyboard for typing into the Mac (the panel also carries Esc/Tab/arrows)
            let k = CGRect(x: w.minX + 24, y: w.minY + 18, width: 64, height: 64)
            desktopKeyboardButton(k)
            txt("stick ↔ zoom · trigger click · grip right-click", w.maxX - 110, w.minY + 60, 26, 0x9aa3afff, align: 1)
        }
        grabBar("grab", Dashboard.GRAB)
    }
    private func desktopKeyboardButton(_ k: CGRect) {
        face(k, k.height / 2, on: btn("dt:kb", k) { [unowned self] in desktopKeyboard.toggle(); sounds.play(desktopKeyboard ? "open" : "back"); redraw() },
             base: desktopKeyboard ? 0x2d8cffff : 0x00000000)
        icon("keyboard", k.midX, k.midY, 0xffffffff, 1.0)
    }
    /// Quest window: grey panel, app content on top, and a darker title bar along the bottom edge with close and
    /// minimise on the left and the app name centred (like Horizon OS windows).
    private func questChrome() {
        let w = Dashboard.WIN, bar = CGRect(x: w.minX, y: w.maxY - 72, width: w.width, height: 72)
        rr(w, 30, 0x243039ff)
        ctx.saveGState(); ctx.addPath(path(w, 30)); ctx.clip()
        ctx.setFillColor(col(0x1a242bff)); ctx.fill(bar)
        ctx.restoreGState()
        if contrast { outline(w.insetBy(dx: 1, dy: 1), 30, 0xffffff70, 2); rr(CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: 2), 0, 0xffffff50) }
        let x = CGRect(x: bar.minX + 14, y: bar.minY + 8, width: 56, height: 56), m = CGRect(x: x.maxX + 8, y: x.minY, width: 56, height: 56)
        if view == "welcome" { txt(title, bar.midX, bar.midY + 10, 27, 0xd2d8dcff, align: 0.5); return }   // the tour can't be closed or left (no softlock)
        if btn("win:close", x, { [unowned self] in windowOpen = false; sounds.play("close"); redraw() }) || isPressed("win:close") { rr(x, 16, 0xffffff1c) }
        icon("x", x.midX, x.midY, 0xffffffff, 0.8)
        if btn("win:min", m, { [unowned self] in windowOpen = false; sounds.play("back"); redraw() }) || isPressed("win:min") { rr(m, 16, 0xffffff1c) }
        rr(CGRect(x: m.midX - 13, y: m.midY - 2, width: 26, height: 4), 2, 0xffffffff)
        let back = CGRect(x: m.maxX + 12, y: m.minY, width: 128, height: 56)
        if !navigationHistory[drawingSlot].isEmpty {
            if btn("win:back", back, { [unowned self] in goBack() }) { rr(back, 16, 0xffffff1c) }
            icon("back", back.minX + 26, back.midY, 0xffffffff, 0.65)
            txt("Back", back.minX + 47, back.midY + 9, 26)
        }
        let home = CGRect(x: bar.maxX - 330, y: bar.minY + 8, width: 120, height: 56)
        if btn("win:home", home, { [unowned self] in nav("home") }) { rr(home, 16, 0xffffff1c) }
        txt("Home", home.midX, home.midY + 10, 25, 0xd2d8dcff, align: 0.5)
        let spaces = CGRect(x: bar.maxX - 200, y: bar.minY + 8, width: 120, height: 56)
        if btn("win:spaces", spaces, { [unowned self] in nav("spaces") }) { rr(spaces, 16, 0xffffff1c) }
        txt("Spaces", spaces.midX, spaces.midY + 10, 25, 0xd2d8dcff, align: 0.5)
        txt(title, bar.midX, bar.midY + 10, 27, 0xd2d8dcff, align: 0.5)
        if !games.status.isEmpty { txt(games.status, back.maxX + 24, bar.midY + 10, 26, 0xa4adb4ff, maxW: bar.width / 2 - 380) }
        if view == "desktop" { desktopKeyboardButton(CGRect(x: bar.maxX - 70, y: bar.minY + 8, width: 56, height: 56)) }
        grabBar("grab", Dashboard.GRAB)
    }
    /// Quest-style pill; brighter and wider while hovered or held. A small dot beside it grows into an X and closes
    /// what the bar carries (window/menu, or the keyboard).
    private func grabBar(_ id: String, _ g: CGRect) {
        let hot = hover == id || grabbing == id
        regions.append(Region(id: id, r: g, fn: nil, drag: nil))
        let gw = 190 + 50 * ease("grab:" + id, hot ? 1 : 0, speed: 20)
        rr(CGRect(x: g.midX - gw / 2, y: g.midY - 8, width: gw, height: 16), 8, hot ? 0xffffffff : 0xffffffb0)
        if id == "grab" && view == "welcome" || quest && id != "grabkb" { return }   // Quest: the window's X is in its title bar
        let d = Dashboard.dotRect(g)
        let dotHot = btn("x:" + id, d) { [unowned self] in
            if id == "grabkb" {   // close the keyboard
                if macKeyboard { macKeyboard = false } else if view == "commands" { commandKeyboard = false } else if view == "desktop" { desktopKeyboard = false } else if view == "keyboard" { view = "library" } else if view == "settings" { settingsSearch = false }
                sounds.play("close"); redraw()
            } else if id == "grab" { windowOpen = false; sounds.play("close"); redraw() }   // just the window; the menu stays
            else { sounds.play("menuClose"); close() }
        }
        // grow from a small dot into a white X button (ease-out with a slight overshoot), and back on leave
        let now = CACurrentMediaTime(), dur = 0.2
        if dotHot != (dotSince[id].map { $0 < 0 } ?? false) {
            let prev = dotSince[id].map { min(1, (now - abs($0)) / dur) } ?? 1   // reverse from wherever it is
            dotSince[id] = (dotHot ? -1 : 1) * (now - (1 - prev) * dur)
        }
        var t = reduceMotion ? 1 : dotSince[id].map { min(1, (now - abs($0)) / dur) } ?? 1
        if t < 1 { animatingUntil = max(animatingUntil, now + 0.05) }
        if !dotHot { t = 1 - t }
        let back = 1 + 2.2 * pow(t - 1, 3) + 1.2 * pow(t - 1, 2)   // easeOutBack
        let rad = 9 + 17 * CGFloat(back)
        let a = UInt32(176 + 79 * min(1, max(0, t)))
        rr(CGRect(x: d.midX - rad, y: d.midY - rad, width: 2 * rad, height: 2 * rad), rad, 0xffffff00 | a)
        if t > 0.15 { icon("x", d.midX, d.midY, 0x1b212900 | UInt32(255 * min(1, (t - 0.15) / 0.6)), CGFloat(0.4 + 0.35 * back)) }
    }

    // MARK: the Universal Menu (dock)
    private var recents: [String] {   // pinned favourites first, then most recently launched
        let pinned = UserDefaults.standard.stringArray(forKey: "dock.pinned") ?? []
        let recent = UserDefaults.standard.stringArray(forKey: "dock.recent") ?? []
        return Array((pinned + recent.filter { !pinned.contains($0) }).prefix(max(4, min(6, pinned.count))))
    }
    private func pushRecent(_ id: String) {
        var r = UserDefaults.standard.stringArray(forKey: "dock.recent") ?? []
        r.removeAll { $0 == id }; r.insert(id, at: 0)
        UserDefaults.standard.set(Array(r.prefix(8)), forKey: "dock.recent")
    }
    private var pinnedSet: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "dock.pinned") ?? []) }
    private func isPinned(_ id: String) -> Bool { pinnedSet.contains(id) }
    private func togglePin(_ id: String) {
        var p = UserDefaults.standard.stringArray(forKey: "dock.pinned") ?? []
        if p.contains(id) { p.removeAll { $0 == id } } else { p.insert(id, at: 0) }
        UserDefaults.standard.set(p, forKey: "dock.pinned")
    }
    /// Per-game overrides (0 = default): render resolution %, world scale %, always open in Theater.
    static func override(_ appid: String, _ key: String) -> Int { UserDefaults.standard.integer(forKey: "app.\(appid).\(key)") }
    static let overrideChanged = Notification.Name("MacVR.gameOverrideChanged")
    static func setOverride(_ appid: String, _ key: String, _ v: Int) {
        UserDefaults.standard.set(v, forKey: "app.\(appid).\(key)")
        NotificationCenter.default.post(name: overrideChanged, object: nil, userInfo: ["appid": appid, "key": key])
    }
    private var settingsFor: Game?
    private func start(_ g: Game) {
        if g.installed && Dashboard.override(g.appid, "theater") == 1 && !theaterOn { theater(true) }
        if g.installed { pushRecent(g.appid); UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "app.\(g.appid).last"); sounds.play("launch"); launch(g) }
        else if let p = g.progress { note("Downloading \(g.name): \(Int(p * 100))%", kind: "Downloads") }
        else { sounds.play("on"); install(g) }
    }

    /// SteamVR-style Universal Menu (late v60-v76 Quest look): a thin near-black bar. Left: avatar, clock and status
    /// (-> Quick Settings), notifications. Right: white system glyphs, colourful app icons, recent games, App Library grid.
    /// Hover is a calm plate (no enlarging), the active app gets a tiny indicator, labels only appear on hover.
    private func dock() {
        let d = Dashboard.DOCK
        dockRect = d
        rr(d, 40, 0x15181de8)
        var tip: (CGRect, String)?
        func plate(_ id: String, _ r: CGRect, _ rad: CGFloat) {   // hover / press feedback behind a control
            if isPressed(id) { rr(r, rad, 0xffffff38) } else if hover == id { rr(r, rad, 0xffffff1c) }
        }
        func indicator(_ x: CGFloat, _ on: Bool) { if on { rr(CGRect(x: x - 9, y: d.maxY - 14, width: 18, height: 5), 2.5, 0xffffffff) } }
        // status: avatar, clock, link, fps -> Quick Settings (the clock area)
        let st = CGRect(x: d.minX + 16, y: d.minY + 14, width: 360, height: d.height - 28)
        let stHot = btn("dock:quick", st) { [unowned self] in nav("quick") }
        plate("dock:quick", st, st.height / 2)
        rr(CGRect(x: st.minX + 14, y: st.midY - 28, width: 56, height: 56), 28, 0xd9467aff)
        if let first = Dashboard.userName.first { txt(String(first).uppercased(), st.minX + 42, st.midY + 10, 28, bold: true, align: 0.5) }
        else { icon("person", st.minX + 42, st.midY, 0xffffffff, 0.8) }
        let tf = DateFormatter(); tf.timeStyle = .short
        txt(tf.string(from: Date()), st.minX + 88, st.midY + 11, 30)
        icon(linkStatus == "USB" ? "usb" : "wifi", st.minX + 268, st.midY, 0xffffffff, 0.85)
        if settings.bool("show_fps") { txt("\(fps)", st.maxX - 20, st.midY + 10, 26, 0x5ee07aff, align: 1) }
        indicator(st.minX + 120, view == "quick")
        if stHot { tip = (st, "Quick Settings") }
        // notifications
        let bell = CGRect(x: st.maxX + 16, y: d.midY - 36, width: 72, height: 72)
        if btn("dock:notifications", bell, { [unowned self] in nav("notifications") }) { tip = (bell, unread > 0 ? "Notifications · \(unread) new" : "Notifications") }
        plate("dock:notifications", bell, 22)
        icon("bell", bell.midX, bell.midY, 0xffffffff, 0.95)
        if unread > 0 && !quiet { rr(CGRect(x: bell.maxX - 22, y: bell.minY + 12, width: 14, height: 14), 7, 0x2d8cffff) }
        indicator(bell.midX, view == "notifications")
        // system destinations | apps | recent games | App Library
        var items: [String] = gameActive ? ["home", "overview", "commands", "playing"] : ["home", "overview", "commands"]
        items += settings.bool("show_desktop_tabs") ? ["desktop", "steam"] : ["steam"]
        if settings.bool("show_settings_tab") { items.append("settings") }
        let games = recents.prefix(2).compactMap { id in library.first { $0.appid == id } }
        let tile: CGFloat = 66, gap: CGFloat = 22
        let count = CGFloat(items.count + games.count + 1)
        var x = d.maxX - 34 - count * (tile + gap) + gap - (games.isEmpty ? 0 : 30)
        func slot(_ id: String, _ label: String, _ draw: (CGRect) -> Void, _ fn: @escaping () -> Void, active: Bool) {
            let r = CGRect(x: x, y: d.midY - tile / 2 - 4, width: tile, height: tile)
            let h = btn("dock:" + id, r, fn)
            plate("dock:" + id, r.insetBy(dx: -10, dy: -10), 24)
            draw(r)
            indicator(r.midX, active)
            if h { tip = (r, label) }
            x += tile + gap
        }
        let glyphs = ["desktop": "monitor", "settings": "gear", "library": "apps"]   // system controls: white glyphs
        for id in items {
            slot(id, Dashboard.apps[id]!.label, { [unowned self] r in
                if let g = glyphs[id] { icon(g, r.midX, r.midY, 0xffffffff, 1.0) }
                else if id == "playing", let gm = playingGame { gameIcon(gm, r) }
                else { appIcon(id, r, hot: false) }
            }, { [unowned self] in openApp(id) }, active: view == id)
        }
        if !games.isEmpty {   // subtle separator, then recent games
            rr(CGRect(x: x - 1, y: d.minY + 34, width: 2, height: d.height - 68), 1, 0xffffff26); x += 30
            for g in games {
                slot("game:" + g.appid, g.name, { [unowned self] r in gameIcon(g, r) }, { [unowned self] in start(g) },
                     active: gameActive && self.games.playing(gameName) == g)
            }
        }
        slot("library", "App Library", { r in icon("apps", r.midX, r.midY, 0xffffffff, 1.0) }, { [unowned self] in nav("library") },
             active: view == "library" || view == "keyboard")
        if let (r, label) = tip {   // label above the hovered control
            let w = CGFloat(label.count) * 15 + 44, tt = CGRect(x: min(max(r.midX - w / 2, 20), CGFloat(Dashboard.W) - w - 20), y: d.minY - 58, width: w, height: 46)
            rr(tt, 12, 0x15181df2); txt(label, tt.midX, tt.midY + 9, 26, align: 0.5)
        }
        grabBar("grabdock", Dashboard.DOCKGRAB)
    }
    private var lastTip: (CGRect, String)?
    /// Quest Universal Menu (Horizon OS): a slim slate rounded rectangle under the window. Left: avatar, notifications and
    /// a status pill (link, time) that opens Quick Settings. Then app tiles, pinned and recent games, a divider, the App
    /// Library and (Settings > Show Power Options) the power button. Tiles lift on hover; the name fades in above.
    /// Left-Handed Layout mirrors the whole bar.
    private func questDock() {
        var items: [String] = gameActive ? ["home", "overview", "commands", "playing"] : ["home", "overview", "commands"]
        items += settings.bool("show_desktop_tabs") ? ["desktop", "steam"] : ["steam"]
        if settings.bool("show_settings_tab") { items.append("settings") }
        let favs = recents.compactMap { id in library.first { $0.appid == id } }
        let power = settings.bool("show_power")
        let tile: CGFloat = 66, gap: CGFloat = 16, statusW: CGFloat = 330
        let width = 18 + statusW + 70 + CGFloat(items.count + favs.count) * (tile + gap) + 22 + tile + 22 + (power ? 86 : 0)
        let d = CGRect(x: Dashboard.DOCK.midX - width / 2, y: Dashboard.DOCK.midY - 46, width: width, height: 92)
        dockRect = d
        func m(_ r: CGRect) -> CGRect { leftHanded ? CGRect(x: d.minX + d.maxX - r.maxX, y: r.minY, width: r.width, height: r.height) : r }
        rr(d, 28, 0x1f2b33ff)   // Horizon OS dock: a rounded rectangle, not a pill
        var tip: (CGRect, String)?
        // avatar with presence dot: opens Home
        let av = m(CGRect(x: d.minX + 22, y: d.midY - 22, width: 44, height: 44))
        if btn("dock:me", av.insetBy(dx: -6, dy: -6), { [unowned self] in nav("home") }) { tip = (av, Dashboard.userName.isEmpty ? "Home" : Dashboard.userName) }
        rr(av, 22, 0xd9467aff)
        if let first = Dashboard.userName.first { txt(String(first).uppercased(), av.midX, av.midY + 9, 26, bold: true, align: 0.5) }
        else { icon("person", av.midX, av.midY, 0xffffffff, 0.6) }
        rr(CGRect(x: av.maxX - 13, y: av.maxY - 13, width: 15, height: 15), 7.5, 0x1f2b33ff)
        rr(CGRect(x: av.maxX - 11, y: av.maxY - 11, width: 11, height: 11), 5.5, 0x45d36bff)   // headset connected
        // notifications
        let bell = m(CGRect(x: d.minX + 78, y: d.midY - 26, width: 52, height: 52))
        if btn("dock:notifications", bell, { [unowned self] in nav("notifications") }) {
            tip = (bell, unread > 0 ? "Notifications · \(unread) new" : "Notifications"); rr(bell, 26, 0xffffff1c)
        }
        icon("bell", bell.midX, bell.midY, 0xe0e5e8ff, 0.6)
        if settings.bool("dnd") { icon("moon", bell.maxX - 12, bell.minY + 12, 0xc8d0d6ff, 0.36) }
        else if unread > 0 { rr(CGRect(x: bell.maxX - 17, y: bell.minY + 7, width: 13, height: 13), 6.5, 0x2a73f5ff) }
        if view == "notifications" { rr(CGRect(x: bell.midX - 12, y: d.maxY - 10, width: 24, height: 4), 2, 0xc8d0d6ff) }
        // status pill: link, fps, time -> Quick Settings
        let tf = DateFormatter(); tf.dateFormat = "h:mm"
        let time = tf.string(from: Date()), fpsText = settings.bool("show_fps") ? "\(fps)" : ""
        let pw = 130 + CGFloat(time.count + fpsText.count) * 15
        let st = m(CGRect(x: d.minX + 142, y: d.midY - 26, width: pw, height: 52))
        if btn("dock:quick", st, { [unowned self] in nav("quick") }) { tip = (st, "Quick Settings") }
        rr(st, 26, isPressed("dock:quick") ? 0x46525dff : hover == "dock:quick" ? 0x3e4c55ff : 0x34434bff)
        icon(linkStatus == "USB" ? "usb" : "wifi", st.minX + 32, st.midY, 0xe0e5e8ff, 0.55)
        if !fpsText.isEmpty { txt(fpsText, st.minX + 58, st.midY + 9, 26, 0x5ee07aff) }
        txt(time, st.maxX - 22, st.midY + 9, 26, 0xe0e5e8ff, align: 1)
        if view == "quick" { rr(CGRect(x: st.midX - 12, y: d.maxY - 10, width: 24, height: 4), 2, 0xc8d0d6ff) }
        // app tiles: lift on hover, sink on press
        var x = max(d.minX + 142 + pw + 40, d.minX + 18 + statusW + 70)
        func slot(_ id: String, _ label: String, _ draw: (CGRect) -> Void, _ fn: @escaping () -> Void, active: Bool) {
            let r0 = m(CGRect(x: x, y: d.midY - tile / 2 - 3, width: tile, height: tile))
            let h = btn("dock:" + id, r0.insetBy(dx: -gap / 2, dy: -8), fn)
            let t = ease("dock:" + id, isPressed("dock:" + id) ? -1 : h ? 1 : 0, speed: 20), k = 1 + 0.08 * t
            let r = CGRect(x: r0.midX - tile * k / 2, y: r0.midY - tile * k / 2 - 7 * max(0, t), width: tile * k, height: tile * k)
            draw(r)
            if t > 0.02 { outline(r.insetBy(dx: -4, dy: -4), 21, 0xffffff00 | UInt32(192 * min(1, t)), 3) }
            if active { rr(CGRect(x: r0.midX - 12, y: d.maxY - 10, width: 24, height: 4), 2, 0xc8d0d6ff) }
            if h { tip = (r0, label) }
            x += tile + gap
        }
        for id in items {
            slot(id, Dashboard.apps[id]!.label, { [unowned self] r in
                if id == "playing", let gm = playingGame { gameIcon(gm, r) } else { appIcon(id, r, hot: false) }
            }, { [unowned self] in openApp(id) }, active: view == id)
        }
        for g in favs {
            slot("game:" + g.appid, g.name + (isPinned(g.appid) ? "  ·  Pinned" : ""), { [unowned self] r in gameIcon(g, r) }, { [unowned self] in start(g) },
                 active: gameActive && self.games.playing(gameName) == g)
        }
        rr(m(CGRect(x: x + 2, y: d.minY + 24, width: 2, height: d.height - 48)), 1, 0xffffff2a); x += 22
        slot("library", "App Library", { [unowned self] r in rr(r, 18, 0x46525dff); icon("apps", r.midX, r.midY, 0xffffffff, 0.85 * r.width / tile) },
             { [unowned self] in nav("library") }, active: view == "library" || view == "keyboard")
        if power {
            x += 8
            slot("power", powerOpen ? "Close Power Menu" : "Power", { [unowned self] r in
                rr(r.insetBy(dx: 6, dy: 6), r.width / 2, powerOpen ? 0x2a73f5ff : 0x34434bff); icon("power", r.midX, r.midY, 0xffffffff, 0.7 * r.width / tile)
            }, { [unowned self] in togglePower() }, active: powerOpen)
        }
        let ta = ease("dock:tip", tip != nil && !toastShowing ? 1 : 0, speed: 24)   // a toast owns that strip while it shows
        if let tip { lastTip = tip }
        if ta > 0.01, let (r, label) = lastTip {   // the name fades in above the hovered control
            let w = textW(label, 26) + 44, tt = CGRect(x: min(max(r.midX - w / 2, 20), CGFloat(Dashboard.W) - w - 20), y: d.minY - 58 + 8 * (1 - ta), width: w, height: 46)
            ctx.saveGState(); ctx.setAlpha(ta)
            rr(tt, 12, 0x1c272ef2); txt(label, tt.midX, tt.midY + 9, 26, align: 0.5)
            ctx.restoreGState()
        }
        grabBar("grabdock", Dashboard.DOCKGRAB)
    }
    /// A game's small square Steam icon (the Quest dock uses icon assets, not marketing art); cropped art until it loads.
    private func gameIcon(_ g: Game, _ r: CGRect) {
        if let ic = games.icon(g.appid) ?? games.image(g.appid, "library_600x900") { cover(ic, r, "", rad: r.width * 0.22); return }
        rr(r, r.width * 0.22, 0x46525dff)   // no art (e.g. a standalone game): its initial
        txt(String(g.name.prefix(1)).uppercased(), r.midX, r.midY + r.height * 0.17, r.height * 0.5, bold: true, align: 0.5)
    }

    // MARK: Home: greeting and clock, continue playing, tips and news, quick actions, recent games
    private func homeAction(_ id: String, _ label: String, _ symbol: String, _ r: CGRect, primary: Bool = false, _ action: @escaping () -> Void) {
        let hot = btn(id, r, action)
        face(r, min(18, r.height / 2), on: hot, base: primary ? 0x2d8cffff : 0x34404aff, hot: primary ? 0x4a9dffff : 0x4f5a69ff)
        icon(symbol, r.minX + 35, r.midY, 0xffffffff, 0.85)
        txt(label, r.minX + 68, r.midY + 10, 27, bold: true, maxW: r.width - 88)
        if hot { outline(r, min(18, r.height / 2), 0x8fbcffff, 2) }
    }
    private static let tips: [(String, String)] = [
        ("Swipe to scroll", "Flick a list with your finger or a pinch. It glides and slows down, like on your phone."),
        ("Hold for options", "Touch and hold a game, or squeeze the grip on it, for Play, Pin and Details."),
        ("Three windows", "Drag a window by the bar under it to put it beside the others."),
        ("Pin your favourites", "Pin games to the dock from their ••• menu so they're always one tap away."),
        ("Search everything", "Search in the App Library finds games, apps and settings."),
        ("Theater", "Play flatscreen games on a giant curved screen. Find Theater in Quick Settings."),
        ("Make it comfortable", "Text Size, High Contrast and Reduce Motion live in Settings > Accessibility."),
        ("Recenter", "Hold the menu button to bring the menu back in front of you."),
        ("Do Not Disturb", "Mute pop-ups from Quick Settings. Everything still lands in Notifications."),
        ("Power menu", "The power button quits games, refreshes the video and recenters your view."),
    ]
    /// The game Home offers to continue: the one running, else the last one played.
    private var continueGame: Game? {
        if let g = playingGame { return g }
        let installed = library.filter(\.installed), ids = UserDefaults.standard.stringArray(forKey: "dock.recent") ?? []
        return ids.lazy.compactMap { id in installed.first { $0.appid == id } }.first ?? installed.max { Dashboard.lastPlayed($0.appid) < Dashboard.lastPlayed($1.appid) }
    }
    private func drawHome() {
        let c = content, date = Date()
        let hour = Calendar.current.component(.hour, from: date)
        let greeting = hour < 5 ? "Good evening" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let first = Dashboard.userName.split(separator: " ").first.map(String.init) ?? ""
        txt(first.isEmpty ? greeting : "\(greeting), \(first)", c.minX + 8, c.minY + 46, 46, bold: true, maxW: 1150)
        let df = DateFormatter(); df.dateFormat = "EEEE, MMMM d"
        let installed = library.filter(\.installed)
        txt("\(df.string(from: date))  ·  \(settings["environment"])  ·  \(installed.count) game\(installed.count == 1 ? "" : "s") ready",
            c.minX + 8, c.minY + 88, 27, 0xa4adb4ff, maxW: 1150)
        let tf = DateFormatter(); tf.timeStyle = .short
        txt(tf.string(from: date), c.maxX - 8, c.minY + 50, 46, bold: true, align: 1)
        icon(linkStatus == "USB" ? "usb" : "wifi", c.maxX - textW("\(headset.label) · \(linkStatus)", 26) - 34, c.minY + 79, 0xa4adb4ff, 0.6)
        txt("\(headset.label) · \(linkStatus)", c.maxX - 8, c.minY + 88, 26, 0xa4adb4ff, align: 1)
        // hero: continue playing (art), or a welcome over your home environment
        let hero = CGRect(x: c.minX, y: c.minY + 118, width: 1100, height: 330)
        if let g = continueGame {
            let hot = btn("home:hero", hero) { [unowned self] in if gameActive { close() } else { start(g) } }
            lifted("home:hero", hero, 26, hot: hot) { r in
                cover(games.image(g.appid, "library_hero") ?? games.image(g.appid, "header"), r, "", rad: 26)
                scrim(r, 26, fromLeft: true, strength: 0.92)
            }
            txt(gameActive ? "NOW PLAYING" : "CONTINUE PLAYING", hero.minX + 36, hero.minY + 52, 23, 0x9cd7ffff, bold: true)
            txt(g.name, hero.minX + 36, hero.minY + 116, 50, bold: true, maxW: hero.width - 72)
            let last = Dashboard.lastPlayed(g.appid), played = Dashboard.playTime(g.appid)
            let meta = [g.vr ? "VR" : "Flatscreen", last > 0 ? "Played " + Dashboard.ago(Date(timeIntervalSince1970: last)).lowercased() : "",
                        played > 0 ? Dashboard.duration(played) + " total" : ""].filter { !$0.isEmpty }.joined(separator: "  ·  ")
            txt(meta, hero.minX + 36, hero.minY + 160, 27, 0xd2d8dcff, maxW: hero.width - 72)
            homeAction("home:primary", gameActive ? "Resume" : "Play", "play", CGRect(x: hero.minX + 36, y: hero.maxY - 96, width: 220, height: 68), primary: true) { [unowned self] in
                if gameActive { close() } else { start(g) }
            }
            homeAction("home:details", "Details", "info", CGRect(x: hero.minX + 276, y: hero.maxY - 96, width: 220, height: 68)) { [unowned self] in showDetails(g) }
            homeAction("home:spaces", "Change space", "mountain", CGRect(x: hero.minX + 516, y: hero.maxY - 96, width: 290, height: 68)) { [unowned self] in nav("spaces") }
        } else {
            cover(Dashboard.envThumb(settings["environment"]), hero, "", rad: 26)
            scrim(hero, 26, fromLeft: true, strength: 0.8)
            txt("WELCOME HOME", hero.minX + 36, hero.minY + 52, 23, 0x9cd7ffff, bold: true)
            txt(settings["environment"], hero.minX + 36, hero.minY + 116, 50, bold: true, maxW: hero.width - 72)
            txt("Settle in, find a game, or bring your Mac into VR.", hero.minX + 36, hero.minY + 160, 27, 0xd2d8dcff, maxW: hero.width - 72)
            homeAction("home:primary", "Explore library", "apps", CGRect(x: hero.minX + 36, y: hero.maxY - 96, width: 300, height: 68), primary: true) { [unowned self] in nav("library") }
            homeAction("home:spaces", "Change space", "mountain", CGRect(x: hero.minX + 356, y: hero.maxY - 96, width: 290, height: 68)) { [unowned self] in nav("spaces") }
        }
        // right column: tip of the day / Steam news, then four quick actions
        let x = hero.maxX + 24, w = c.maxX - x
        let cards = Dashboard.tips.map { ("TIP", $0.0, $0.1) } + games.news.prefix(3).map { n in
            ("NEWS · " + (library.first { $0.appid == n.appid }?.name ?? "Steam"), n.title, Dashboard.ago(n.date) + (n.label.isEmpty ? "" : "  ·  " + n.label)) }
        let card = cards[((tipIndex % cards.count) + cards.count) % cards.count]
        let tipR = CGRect(x: x, y: hero.minY, width: w, height: 178)
        rr(tipR, 24, 0x34404aff)
        icon(card.0 == "TIP" ? "tips" : "globe", tipR.minX + 40, tipR.minY + 38, 0x9cd7ffff, 0.75)
        txt(card.0, tipR.minX + 70, tipR.minY + 48, 23, 0x9cd7ffff, bold: true, maxW: w - 170)
        txt(card.1, tipR.minX + 28, tipR.minY + 90, 29, bold: true, maxW: w - 56)
        para(card.2, tipR.minX + 28, tipR.minY + 128, 24, 0xd2d8dcff, maxW: w - 56, maxLines: 2)
        let nextTip = CGRect(x: tipR.maxX - 120, y: tipR.minY + 12, width: 104, height: 52)
        face(nextTip, 26, on: btn("home:tip", nextTip) { [unowned self] in tipIndex += 1; redraw() }, base: 0x00000000, hot: 0x46525dff)
        txt("Next", nextTip.midX - 10, nextTip.midY + 9, 25, 0xd2d8dcff, align: 0.5); icon("next", nextTip.maxX - 22, nextTip.midY, 0xd2d8dcff, 0.5)
        let qa: [(String, String, String, () -> Void)] = [
            ("home:desktop", "Mac Desktop", "monitor", { [unowned self] in openDesktop() }),
            ("home:quick", "Quick Settings", "sliders", { [unowned self] in nav("quick") }),
            ("home:recenter", "Recenter", "recenter", { [unowned self] in recenter(); note("View centered", kind: "System") }),
            ("home:library", "All Apps", "apps", { [unowned self] in nav("library") }),
        ]
        let qw = (w - 16) / 2
        for (i, a) in qa.enumerated() {
            homeAction(a.0, a.1, a.2, CGRect(x: x + CGFloat(i % 2) * (qw + 16), y: tipR.maxY + 16 + CGFloat(i / 2) * 72, width: qw, height: 64), a.3)
        }
        // recent games
        txt("Jump back in", c.minX + 8, c.minY + 500, 32, bold: true)
        let ids = UserDefaults.standard.stringArray(forKey: "dock.recent") ?? []
        let ordered = ids.compactMap { id in installed.first { $0.appid == id } } + installed.filter { !ids.contains($0.appid) }
        if ordered.isEmpty {
            let r = CGRect(x: c.minX, y: c.minY + 526, width: c.width, height: 170)
            rr(r, 22, 0x34404aff)
            txt("Make room for your first adventure", r.minX + 30, r.minY + 60, 32, bold: true)
            txt("Open Steam on your Mac to sign in and install a game.", r.minX + 30, r.minY + 104, 27, 0xd2d8dcff)
            homeAction("home:steam", "Open Steam", "steam", CGRect(x: r.maxX - 320, y: r.minY + 50, width: 280, height: 72)) { [unowned self] in openSteam(); note("Opening Steam on your Mac", kind: "Games") }
        } else {
            let all = CGRect(x: c.maxX - 170, y: c.minY + 466, width: 170, height: 50)
            face(all, 25, on: btn("home:all", all) { [unowned self] in nav("library") }, base: 0x00000000, hot: 0x46525dff)
            txt("See all", all.midX - 12, all.midY + 9, 26, 0xd2d8dcff, align: 0.5); icon("next", all.maxX - 26, all.midY, 0xd2d8dcff, 0.5)
            let n = 5, width = (c.width - CGFloat(n - 1) * 22) / CGFloat(n)
            for (i, g) in ordered.prefix(n).enumerated() {
                let r = CGRect(x: c.minX + CGFloat(i) * (width + 22), y: c.minY + 528, width: width, height: width * 0.467)
                let hot = btn("home:game:" + g.appid, r) { [unowned self] in start(g) }
                lifted("home:game:" + g.appid, r, 18, hot: hot) { b in cover(games.image(g.appid, "header"), b, g.name, rad: 18) }
                txt(g.name, r.minX + 4, r.maxY + 36, 26, hot ? 0xffffffff : 0xdfe3e8ff, maxW: width - 8)
            }
        }
    }

    private func drawSpaces() {
        let c = content
        txt("Find your happy place", c.minX, c.minY + 44, 44, bold: true)
        let styles = Settings.items["home_style"]!.options
        segmented("space:style", CGRect(x: c.maxX - 740, y: c.minY, width: 740, height: 60), styles, styles.firstIndex(of: settings["home_style"]) ?? 0) { [unowned self] i in settings.set("home_style", styles[i]) }
        txt("Choose a space to make it your home. Changes apply immediately.", c.minX, c.minY + 88, 27, 0xa4adb4ff)
        let all = Settings.items["environment"]!.options
        let pageCount = (all.count + 5) / 6
        spacePage = min(spacePage, pageCount - 1)
        let width = (c.width - 48) / 3
        for (i, name) in all.dropFirst(spacePage * 6).prefix(6).enumerated() {
            let r = CGRect(x: c.minX + CGFloat(i % 3) * (width + 24), y: c.minY + 120 + CGFloat(i / 3) * 246, width: width, height: 220)
            let selected = settings["environment"] == name
            let hot = btn("space:" + name, r) { [unowned self] in settings.set("environment", name); sounds.play("env"); redraw() }
            lifted("space:" + name, r, 22, hot: hot, ring: !selected) { b in
                cover(Dashboard.envThumb(name), b, name, rad: 22)
                scrim(b, 22, strength: 0.9)
                txt(name, b.minX + 22, b.maxY - 21, 28, bold: selected, maxW: b.width - 80)
                if selected { icon("check", b.maxX - 34, b.maxY - 31, 0x8fbcffff, 0.8); outline(b, 22, 0x69aaffff, 4) }
            }
        }
        let y = c.maxY - 84
        homeAction("spaces:home", "Back home", "home", CGRect(x: c.minX, y: y, width: 280, height: 68)) { [unowned self] in nav("home") }
        if spacePage > 0 { homeAction("spaces:previous", "Previous", "back", CGRect(x: c.maxX - 620, y: y, width: 240, height: 68)) { [unowned self] in spacePage -= 1; redraw() } }
        txt("\(spacePage + 1) / \(pageCount)", c.maxX - 320, y + 43, 26, 0xa4adb4ff, align: 0.5)
        if spacePage + 1 < pageCount { homeAction("spaces:next", "Next", "next", CGRect(x: c.maxX - 240, y: y, width: 240, height: 68)) { [unowned self] in spacePage += 1; redraw() } }
    }

    // MARK: Workspace overview and command launcher
    private func safeWorkspaceView(_ value: String) -> String {
        let allowed = ["home", "spaces", "library", "desktop", "quick", "settings", "notifications", "playing"]
        guard allowed.contains(value) else { return "home" }
        if value == "playing" && !gameActive { return "home" }
        if value == "desktop" && !settings.bool("show_desktop_tabs") { return "home" }
        if value == "settings" && !settings.bool("show_settings_tab") { return "home" }
        return value
    }
    private func saveWorkspace() {
        let center = view == "overview" ? overviewReturn : view
        let views = [sideViews[0] ?? "", safeWorkspaceView(center), sideViews[1] ?? ""]
        UserDefaults.standard.set(["views": views, "environment": settings["environment"], "style": settings["home_style"]], forKey: "shell.workspace")
        note("Workspace saved. Restore your windows and space anytime."); redraw()
    }
    private func restoreWorkspace() {
        guard let saved = UserDefaults.standard.dictionary(forKey: "shell.workspace"),
              let views = saved["views"] as? [String], views.count == 3 else { return }
        if let env = saved["environment"] as? String, Settings.items["environment"]!.options.contains(env) { settings.set("environment", env) }
        if let style = saved["style"] as? String, Settings.items["home_style"]!.options.contains(style) { settings.set("home_style", style) }
        navigationHistory = [[], [], []]
        sideViews = quest ? [views[0].isEmpty ? nil : safeWorkspaceView(views[0]), views[2].isEmpty ? nil : safeWorkspaceView(views[2])] : [nil, nil]
        nav(safeWorkspaceView(views[1])); recenter(); note("Workspace restored")
    }
    private func toggleQuiet() { toggleSetting("dnd"); toastUntil = .distantPast; redraw() }
    private func drawOverview() {
        let c = content
        txt("Make space for what matters", c.minX, c.minY + 44, 44, bold: true)
        txt("Switch your flow. Arrange your windows. Feel at home.", c.minX, c.minY + 88, 27, 0xb7c8daff)
        guard drawingSlot == 1 else {
            txt("Open Workspace from the dock to manage all your windows.", c.midX, c.midY, 28, align: 0.5, maxW: c.width - 60)
            return
        }
        let presets = [("Play", "Your next adventure, front and center", "play", UInt32(0x285e97ff)),
                       ("Focus", "Your Mac, with controls within reach", "monitor", UInt32(0x544c91ff)),
                       ("Explore", "A new space. A little inspiration.", "mountain", UInt32(0x246c70ff))]
        let width = (c.width - 40) / 3
        for (i, item) in presets.enumerated() {
            let r = CGRect(x: c.minX + CGFloat(i) * (width + 20), y: c.minY + 120, width: width, height: 156)
            let hot = btn("overview:" + item.0, r) { [unowned self] in workspace(item.0) }
            grad(r, 24, item.3, 0x1d2d43ff)
            icon(item.2, r.minX + 42, r.minY + 46, 0xc5e1ffff, 1)
            txt(item.0, r.minX + 80, r.minY + 56, 34, bold: true)
            txt(item.1, r.minX + 28, r.maxY - 32, 26, 0xd7e2eeff, maxW: r.width - 56)
            if hot { outline(r, 24, 0xb7d9ffff, 3) }
        }
        txt(quest ? "YOUR OPEN WINDOWS" : "YOUR WINDOW", c.minX, c.minY + 325, 26, 0xb7c8daff, bold: true)
        let windows: [String?] = quest ? [sideViews[0], overviewReturn, sideViews[1]] : [overviewReturn]
        for (i, route) in windows.enumerated() {
            let r = CGRect(x: c.minX + CGFloat(i) * (width + 20), y: c.minY + 350, width: width, height: 184)
            rr(r, 22, 0x101c2bff); outline(r, 22, 0x7294bb40, 2)
            txt(quest ? ["LEFT", "CENTER", "RIGHT"][i] : "CENTER", r.minX + 24, r.minY + 35, 26, 0x91a6beff)
            guard let route else {
                txt("Room for more", r.minX + 24, r.minY + 84, 30, bold: true)
                homeAction("overview:add:\(i)", i == 0 ? "Add library" : "Add controls", "apps", CGRect(x: r.minX + 20, y: r.maxY - 78, width: r.width - 40, height: 60)) { [unowned self] in
                    sideViews[i == 0 ? 0 : 1] = i == 0 ? "library" : "quick"; navigationHistory[i] = []; redraw()
                }
                continue
            }
            let label = Dashboard.apps[route]?.label ?? "Home"
            txt(label, r.minX + 24, r.minY + 82, 30, bold: true, maxW: r.width - 48)
            homeAction("overview:open:\(i)", i == 1 || !quest ? "Return" : "Bring to center", "next", CGRect(x: r.minX + 20, y: r.maxY - 78, width: r.width - (i == 1 || !quest ? 40 : 130), height: 60)) { [unowned self] in
                if quest && i != 1 { navigationHistory.swapAt(i, 1); sideViews[i == 0 ? 0 : 1] = safeWorkspaceView(overviewReturn) }
                nav(safeWorkspaceView(route))
            }
            if quest && i != 1 {
                let closeRect = CGRect(x: r.maxX - 90, y: r.maxY - 78, width: 70, height: 60)
                let hot = btn("overview:close:\(i)", closeRect) { [unowned self] in sideViews[i == 0 ? 0 : 1] = nil; navigationHistory[i] = []; redraw() }
                face(closeRect, 18, on: hot); icon("x", closeRect.midX, closeRect.midY, 0xffffffff, 0.8)
            }
        }
        let y = c.minY + 565
        homeAction("overview:save", "Save this layout", "pin", CGRect(x: c.minX, y: y, width: 390, height: 76)) { [unowned self] in saveWorkspace() }
        if UserDefaults.standard.dictionary(forKey: "shell.workspace") != nil {
            homeAction("overview:restore", "Restore saved", "refresh", CGRect(x: c.minX + 410, y: y, width: 390, height: 76)) { [unowned self] in restoreWorkspace() }
        }
        homeAction("overview:quiet", quiet ? "Do Not Disturb: On" : "Do Not Disturb: Off", quiet ? "check" : "bell", CGRect(x: c.maxX - 470, y: y, width: 470, height: 76)) { [unowned self] in toggleQuiet() }
        txt("Saved layouts include your space. Do Not Disturb keeps notifications in your inbox, without pop-ups.", c.minX, c.minY + 701, 26, 0xb7c8daff, maxW: c.width)
    }

    private func drawCommands() {
        let c = content
        txt("What would you like to do?", c.minX, c.minY + 44, 42, bold: true)
        txt("Apps, games and everyday actions. One place to find them.", c.minX, c.minY + 84, 27, 0xb7c8daff)
        let search = CGRect(x: c.minX, y: c.minY + 112, width: c.width, height: 80)
        let hot = btn("command:search", search) { [unowned self] in if inputSlot == 1 { commandKeyboard = true } else { note("Open Search from the dock to use the keyboard") }; redraw() }
        face(search, 24, on: hot, base: 0x101c2bff)
        outline(search, 24, commandKeyboard ? 0x8dbfffff : 0x7294bb70, 2)
        icon("search", search.minX + 42, search.midY, 0xb7d9ffff, 1)
        txt(commandQuery.isEmpty ? "Search MacVR" : commandQuery, search.minX + 82, search.midY + 11, 30, commandQuery.isEmpty ? 0x91a6beff : 0xffffffff, maxW: search.width - 190)
        if !commandQuery.isEmpty {
            let clear = CGRect(x: search.maxX - 76, y: search.minY + 8, width: 64, height: 64)
            _ = btn("command:clear", clear) { [unowned self] in commandQuery = ""; commandPage = 0; redraw() }
            icon("x", clear.midX, clear.midY, 0xffffffff, 0.85)
        }
        var actions: [(String, String, String, String, () -> Void)] = []
        if gameActive { actions.append(("resume", "Resume game", gameName, "play", { [unowned self] in close() })) }
        for route in ["library", "home", "overview", "desktop", "spaces", "quick", "settings", "notifications"] {
            if route == "desktop" && !settings.bool("show_desktop_tabs") || route == "settings" && !settings.bool("show_settings_tab") { continue }
            let app = Dashboard.apps[route]!
            actions.append((route, app.label, "Open app", app.icon, { [unowned self] in nav(route) }))
        }
        actions += [
            ("recenter", "Center my view", "Bring the menu back in front of you", "recenter", { [unowned self] in recenter(); note("View centered") }),
            ("quiet", quiet ? "Turn off Do Not Disturb" : "Turn on Do Not Disturb", "Keep notifications in your inbox, without pop-ups", "bell", { [unowned self] in toggleQuiet() }),
            ("steam", "Open Steam", "Browse and install games on your Mac", "steam", { [unowned self] in openSteam(); nav("desktop") }),
            ("theater", theaterOn ? "Leave theater" : "Enter theater", "A big screen for your Mac", "monitor", { [unowned self] in theater(!theaterOn); redraw() })
        ]
        for g in games.library {
            actions.append(("game:" + g.appid, g.name, g.installed ? "Play game" : g.progress != nil ? "View download progress" : "Install game", g.installed ? "play" : "download", { [unowned self] in start(g) }))
        }
        let results = actions.filter { commandQuery.isEmpty || ($0.1 + " " + $0.2).localizedCaseInsensitiveContains(commandQuery) }
        let pages = max(1, (results.count + 5) / 6)
        commandPage = min(commandPage, pages - 1)
        let width = (c.width - 24) / 2
        for (i, action) in results.dropFirst(commandPage * 6).prefix(6).enumerated() {
            let r = CGRect(x: c.minX + CGFloat(i % 2) * (width + 24), y: c.minY + 220 + CGFloat(i / 2) * 130, width: width, height: 112)
            let hot = btn("command:" + action.0, r, action.4)
            face(r, 22, on: hot, base: 0x2a3a4dff)
            icon(action.3, r.minX + 44, r.midY, 0xb7d9ffff, 1)
            txt(action.1, r.minX + 88, r.minY + 43, 29, bold: true, maxW: r.width - 120)
            txt(action.2, r.minX + 88, r.minY + 82, 26, 0xb7c8daff, maxW: r.width - 120)
            if hot { outline(r, 22, 0xb7d9ffff, 2) }
        }
        if results.isEmpty {
            txt("Nothing found yet", c.midX, c.minY + 350, 34, bold: true, align: 0.5)
            txt("Try a game name, Desktop, Disturb or center.", c.midX, c.minY + 403, 27, 0xb7c8daff, align: 0.5)
        }
        let y = c.minY + 640
        if commandPage > 0 { homeAction("command:previous", "Previous", "back", CGRect(x: c.minX, y: y, width: 260, height: 68)) { [unowned self] in commandPage -= 1; redraw() } }
        txt("\(results.count) results  ·  \(commandPage + 1) / \(pages)", c.midX, y + 44, 26, 0xb7c8daff, align: 0.5)
        if commandPage + 1 < pages { homeAction("command:next", "Next", "next", CGRect(x: c.maxX - 260, y: y, width: 260, height: 68)) { [unowned self] in commandPage += 1; redraw() } }
    }

    // MARK: App Library
    // MARK: App Library: filters, sort, universal search (apps, settings, games), detail pages
    static let filters = ["All", "Installed", "VR", "Flat", "Pinned"], sorts = ["Recent", "A–Z", "Most Played"]
    private static let systemApps = ["home", "overview", "commands", "spaces", "desktop", "steam", "theater", "settings", "quick", "notifications", "tips"]
    /// The library as shown (pure, tested): `filter` and `sort` index `filters` / `sorts`. A search keeps names containing
    /// the query (accents and case ignored) and ranks names that start with it, or have a word that does, first.
    static func arrange(_ lib: [Game], query: String, filter: Int, sort: Int, pinned: Set<String>,
                        last: (String) -> Double, played: (String) -> Double) -> [Game] {
        let q = query.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let shown = lib.filter { g in
            (q.isEmpty || fold(g.name).contains(q)) && [true, g.installed || g.progress != nil, g.vr, !g.vr, pinned.contains(g.appid)][min(max(filter, 0), 4)]
        }
        func key(_ g: Game) -> (Int, Double, Int, String) {
            let n = fold(g.name), rank = q.isEmpty || n.hasPrefix(q) || n.contains(" " + q) ? 0 : 1
            switch sort {
            case 1: return (rank, 0, 0, n)
            case 2: return (rank, -played(g.appid), g.installed ? 0 : 1, n)
            default: return (rank, -last(g.appid), g.installed ? 0 : 1, n)
            }
        }
        return shown.sorted { key($0) < key($1) }
    }
    private func drawLibrary() {
        let c = content
        segmented("filter", CGRect(x: c.minX, y: c.minY - 4, width: 650, height: 64), Dashboard.filters, filter) { [unowned self] i in filter = i; flicks["library"] = nil }
        let s = CGRect(x: c.minX + 670, y: c.minY - 4, width: 640, height: 64)
        let searching = view == "keyboard"
        face(s, 32, on: btn("search", s) { [unowned self] in view = "keyboard"; sounds.play("open"); redraw() }, base: searching ? 0x3c4654ff : 0x303945ff)
        if searching { outline(s.insetBy(dx: 1.5, dy: 1.5), 32, 0x2d8cffff, 3) }
        icon("search", s.minX + 40, s.midY, 0x9aa3afff, 1.0)
        txt(query.isEmpty ? "Search games, apps and settings" : query + (searching ? "▏" : ""), s.minX + 76, s.midY + 10, 28, query.isEmpty ? 0x9aa3afff : 0xffffffff, maxW: 500)
        if !query.isEmpty {
            let x = CGRect(x: s.maxX - 62, y: s.minY + 6, width: 52, height: 52)
            face(x, 26, on: btn("clearq", x) { [unowned self] in query = ""; flicks["library"] = nil; sounds.play("back"); redraw() }, base: 0x00000000)
            icon("x", x.midX, x.midY, 0xffffffff, 0.8)
        }
        let so = CGRect(x: s.maxX + 20, y: c.minY - 4, width: c.maxX - 84 - s.maxX - 20, height: 64)
        face(so, 32, on: btn("sort", so) { [unowned self] in
            sort = (sort + 1) % Dashboard.sorts.count; UserDefaults.standard.set(sort, forKey: "lib.sort"); flicks["library"] = nil; redraw()
        }, base: 0x303945ff)
        icon("sort", so.minX + 36, so.midY, 0xc9cfd8ff, 0.8)
        txt(Dashboard.sorts[sort], so.minX + 66, so.midY + 10, 27, bold: true, maxW: so.width - 110)
        icon("chevron", so.maxX - 32, so.midY, 0xc9cfd8ff, 0.6)
        let rf = CGRect(x: c.maxX - 64, y: c.minY - 4, width: 64, height: 64)
        face(rf, 32, on: btn("rescan", rf) { [unowned self] in games.scan(); note("Library refreshed", kind: "Games") })
        icon("refresh", rf.midX, rf.midY, 0xffffffff, 1.0)

        let launched = UserDefaults.standard.stringArray(forKey: "dock.recent") ?? []   // launch order from before play tracking existed
        let lib = Dashboard.arrange(library, query: query, filter: filter, sort: sort, pinned: pinnedSet, last: { id in
            let t = Dashboard.lastPlayed(id); return t > 0 ? t : launched.firstIndex(of: id).map { Double(100 - $0) } ?? 0
        }, played: Dashboard.playTime)
        let apps = filter != 0 ? [] : Dashboard.systemApps.filter { query.isEmpty || Dashboard.apps[$0]!.label.localizedCaseInsensitiveContains(query) }
        let setKeys = query.trimmingCharacters(in: .whitespaces).isEmpty ? [] : Array(Dashboard.settingsMatching(query).prefix(5))
        let area = CGRect(x: c.minX, y: c.minY + 80, width: c.width, height: c.height - 80 - 74)
        let off = flicks["library"]?.pos ?? 0
        let cols = 4, gap: CGFloat = 36, pad: CGFloat = 18, tw = (area.width - 20 - 2 * pad - CGFloat(cols - 1) * gap) / CGFloat(cols), th = tw * 0.467, rowH = th + 104
        var y = area.minY - off
        var menuTile: (CGRect, Game)?
        func live(_ r: CGRect) -> CGRect? { let v = r.intersection(area); return v.height > 40 ? v : nil }   // hit area while scrolled into view
        clipped(area.insetBy(dx: -8, dy: -8)) {
            if !apps.isEmpty {   // built-in apps: one row of small tiles
                caption("Apps", area.minX + pad, y + 30); y += 46
                let aw = (area.width - 20 - 2 * pad - 8 * 14) / 9
                for (i, id) in apps.enumerated() {
                    let a = Dashboard.apps[id]!, cell = CGRect(x: area.minX + pad + CGFloat(i) * (aw + 14), y: y, width: aw, height: 150)
                    let r = CGRect(x: cell.midX - 52, y: cell.minY + 6, width: 104, height: 104)
                    let h = live(cell).map { btn("sys:" + id, $0) { [unowned self] in openApp(id) } } ?? false
                    lifted("sys:" + id, r, 28, hot: h) { [unowned self] b in
                        grad(b, 28, a.top, a.bottom)
                        if id == "steam", let logo = games.steamIcon { cover(logo, b.insetBy(dx: 18, dy: 18), "", rad: 34) } else { icon(a.icon, b.midX, b.midY, 0xffffffff, 1.2 * b.width / 104) }
                    }
                    txt(a.label, cell.midX, cell.maxY + 10, 24, h ? 0xffffffff : 0xdfe3e8ff, align: 0.5, maxW: aw + 10)
                }
                y += 186
            }
            if !setKeys.isEmpty {   // matching settings: chips that jump straight to them
                caption("Settings", area.minX + pad, y + 30); y += 46
                var x = area.minX + pad
                for k in setKeys {
                    let label = Settings.items[k]!.label, w = textW(label, 27, bold: true) + 120
                    if x + w > area.maxX - pad { break }
                    let r = CGRect(x: x, y: y, width: w, height: 68)
                    let h = live(r).map { btn("setres:" + k, $0) { [unowned self] in openSetting(k) } } ?? false
                    face(r, 34, on: h, base: 0x34404aff)
                    icon("gear", r.minX + 38, r.midY, 0x9cd7ffff, 0.75)
                    txt(label, r.minX + 70, r.midY + 10, 27, bold: true)
                    icon("next", r.maxX - 30, r.midY, 0xc9cfd8ff, 0.5)
                    x += w + 16
                }
                y += 96
            }
            if !lib.isEmpty || filter != 0 {
                caption("Games  ·  \(lib.count)", area.minX + pad, y + 30); y += 52
            }
            for (i, g) in lib.enumerated() {
                let r = CGRect(x: area.minX + pad + CGFloat(i % cols) * (tw + gap), y: y + CGFloat(i / cols) * rowH, width: tw, height: th)
                guard r.maxY + 80 > area.minY, r.minY < area.maxY else { continue }
                let h = live(r).map { btn("tile:" + g.appid, $0) { [unowned self] in start(g) } } ?? false
                lifted("tile:" + g.appid, r, 18, hot: h || menuFor == g.appid) { [unowned self] big in
                    cover(games.image(g.appid, "header"), big, g.name, rad: 18)
                    if !g.installed {   // owned but not installed: dimmed, with download state
                        rr(big, 18, 0x00000080)
                        let b = CGRect(x: big.midX - 38, y: big.midY - 38, width: 76, height: 76)
                        rr(b, 38, 0x000000b0)
                        if let p = g.progress {
                            let bar = CGRect(x: big.minX + 18, y: big.maxY - 28, width: big.width - 36, height: 12)
                            rr(bar, 6, 0xffffff40); rr(CGRect(x: bar.minX, y: bar.minY, width: max(12, bar.width * CGFloat(p)), height: 12), 6, 0x2d8cffff)
                            txt("\(Int(p * 100))%", b.midX, b.midY + 10, 26, bold: true, align: 0.5)
                        } else { icon("download", b.midX, b.midY, 0xffffffff, 1.2) }
                    }
                    if g.vr { rr(CGRect(x: big.minX + 12, y: big.minY + 12, width: 60, height: 38), 10, 0x000000c0); txt("VR", big.minX + 42, big.minY + 41, 26, bold: true, align: 0.5) }
                    if isPinned(g.appid) { rr(CGRect(x: big.maxX - 52, y: big.maxY - 52, width: 40, height: 40), 20, 0x000000b0); icon("pin", big.maxX - 32, big.maxY - 32, 0xffffffff, 0.6) }
                    if r.intersection(area).height > 60 {
                        let more = CGRect(x: big.maxX - 64, y: big.minY + 10, width: 54, height: 42)
                        rr(more, 21, menuFor == g.appid ? 0x2d8cffff : 0x000000c8); txt("•••", more.midX, more.midY + 9, 26, bold: true, align: 0.5)
                    }
                }
                if isPressed("tile:" + g.appid) || touchPending?.0.id == "tile:" + g.appid { longPressRing(r) }
                // "..." hit area sits on top of the tile (registered after it)
                if r.intersection(area).height > 60 {
                    let more = CGRect(x: r.maxX - 64, y: r.minY + 10, width: 54, height: 42)
                    btn("more:" + g.appid, more.intersection(area)) { [unowned self] in menuFor = menuFor == g.appid ? nil : g.appid; redraw() }
                }
                if menuFor == g.appid { menuTile = (r, g) }
                txt(g.name, r.minX + 4, r.maxY + 40, 27, h ? 0xffffffff : 0xdfe3e8ff, bold: h, maxW: tw - 8)
                let last = Dashboard.lastPlayed(g.appid), played = Dashboard.playTime(g.appid)
                let meta = g.progress != nil ? "Downloading" : !g.installed ? "Not installed" :
                    [g.vr ? "VR" : "Flat", played > 0 ? Dashboard.duration(played) : last > 0 ? Dashboard.ago(Date(timeIntervalSince1970: last)) : "Ready to play"].joined(separator: "  ·  ")
                txt(meta, r.minX + 4, r.maxY + 74, 23, 0xa4adb4ff, maxW: tw - 8)
            }
            y += CGFloat((lib.count + cols - 1) / cols) * rowH
        }
        if lib.isEmpty && apps.isEmpty && setKeys.isEmpty {
            icon("search", area.midX, area.midY - 70, 0x5d6a75ff, 2.4)
            txt(query.isEmpty ? (filter == 4 ? "Pin games from their ••• menu to see them here." : "No games here yet. Sign in to Steam, then refresh.")
                : "Nothing matches \"\(query)\"", area.midX, area.midY + 30, 30, 0xa4adb4ff, align: 0.5)
        }
        let maxOff = max(0, y + off - area.maxY + 10)
        flicks["library", default: Flick()].limit = maxOff
        // bottom bar: hint + page buttons (touch-friendly paging without a thumbstick)
        let pageY = c.maxY - 64
        txt("Swipe or use the thumbstick to browse  ·  Hold a game for options", c.minX + 8, pageY + 40, 24, 0xa4adb4ff)
        if off > 1 {
            homeAction("lib:previous", "Previous", "back", CGRect(x: c.maxX - 470, y: pageY, width: 220, height: 60)) { [unowned self] in pageLibrary(-area.height) }
        }
        if off < maxOff - 1 {
            homeAction("lib:next", "Next", "next", CGRect(x: c.maxX - 230, y: pageY, width: 220, height: 60)) { [unowned self] in pageLibrary(area.height) }
        }
        scrollbar(area, off, maxOff)
        if let (r, g) = menuTile { contextMenu(g, at: r) }
    }
    private func pageLibrary(_ d: CGFloat) {
        guard var f = flicks["library"] else { return }
        let target = max(0, min(f.limit, f.pos + d))
        if reduceMotion { f.set(target) } else { f.glide(target - f.pos) }
        flicks["library"] = f; animatingUntil = max(animatingUntil, CACurrentMediaTime() + 0.05); redraw()
    }
    /// Direct touch / pinch held on a game: a ring fills, then its menu opens.
    private func longPressRing(_ r: CGRect) {
        guard touchPending?.0.id.hasPrefix("tile:") == true, touchPendingSlot == drawingSlot, touchScroll?.active != true else { return }
        let p = CGFloat((now - touchSince - 0.15) / 0.45)
        guard p > 0 else { return }
        ctx.saveGState(); ctx.setStrokeColor(col(0xffffffe0)); ctx.setLineWidth(6); ctx.setLineCap(.round)
        ctx.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: 40, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * min(1, p), clockwise: false)
        ctx.strokePath(); ctx.restoreGState()
    }
    /// Quest-style tile menu: Play/Install, Details, Pin to Universal Menu, Theater, Uninstall.
    private func contextMenu(_ g: Game, at r: CGRect) {
        var items: [(String, String, String, () -> Void)] = [
            ("ctx:play", g.installed ? "play" : "download", g.installed ? "Play" : (g.progress != nil ? "Downloading…" : "Install"), { [unowned self] in menuFor = nil; start(g) }),
            ("ctx:details", "info", "Details", { [unowned self] in showDetails(g) }),
            ("ctx:pin", "pin", isPinned(g.appid) ? "Unpin from Universal Menu" : "Pin to Universal Menu", { [unowned self] in
                togglePin(g.appid); menuFor = nil; note(isPinned(g.appid) ? "\(g.name) pinned to the dock" : "\(g.name) unpinned", kind: "Games") }),
        ]
        if g.installed { items.append(("ctx:theater", "theater", "Play in Theater", { [unowned self] in
            menuFor = nil; if !theaterOn { theater(true) }; pushRecent(g.appid); sounds.play("launch"); launch(g) })) }
        if g.installed && g.appid.allSatisfy(\.isNumber) { items.append(("ctx:uninstall", "trash", "Uninstall", { [unowned self] in menuFor = nil; uninstall(g) })) }
        let w: CGFloat = 470, h = CGFloat(items.count) * 76 + 20
        var m = CGRect(x: r.maxX - w + 20, y: r.minY + 60, width: w, height: h)
        let floor = Dashboard.WIN.maxY - (quest ? 84 : 20)   // above the Quest title bar
        if m.maxY > floor { m.origin.y = floor - h }
        if m.minX < Dashboard.WIN.minX + 20 { m.origin.x = Dashboard.WIN.minX + 20 }
        let a = ease("ctx:" + g.appid, 1, speed: 24)   // pops in from its corner
        let shown = CGRect(x: m.maxX - m.width * (0.92 + 0.08 * a), y: m.minY, width: m.width * (0.92 + 0.08 * a), height: m.height * (0.9 + 0.1 * a))
        ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: CGColor(gray: 0, alpha: 0.6))
        rr(shown, 22, 0x1b2129ff); ctx.restoreGState()
        for (i, (id, ic, label, fn)) in items.enumerated() {
            let row = CGRect(x: m.minX + 10, y: m.minY + 10 + CGFloat(i) * 76, width: w - 20, height: 70)
            face(row, 16, on: btn(id, row, fn), base: 0x00000000, hot: 0x3a4452ff)
            icon(ic, row.minX + 40, row.midY, id == "ctx:uninstall" ? 0xff7a7aff : 0xffffffff, 0.95)
            txt(label, row.minX + 80, row.midY + 10, 28, id == "ctx:uninstall" ? 0xff9a9aff : 0xffffffff, maxW: w - 110)
        }
    }

    // MARK: Now Playing
    private func drawPlaying() {
        let c = content
        let g = games.playing(gameName)
        if let art = g.flatMap({ games.image($0.appid, "library_hero") }) {
            let r = CGRect(x: c.minX, y: c.minY, width: c.width, height: c.height - 250)
            cover(art, r, "", rad: 26); scrim(r, 26, strength: 0.95)
        }
        txt(g?.name ?? (gameName.isEmpty ? "VR Game" : gameName), c.minX + 20, c.maxY - 270, 64, bold: true, maxW: c.width - 40)
        if let s = session { txt("Playing for " + Dashboard.duration(Date().timeIntervalSince(s.since)).lowercased() + "  ·  " + Dashboard.duration(Dashboard.playTime(s.id) + Date().timeIntervalSince(s.since)) + " total",
                                c.minX + 22, c.maxY - 226, 27, 0xd2d8dcff, maxW: c.width - 40) }
        let round: [(String, String, String, () -> Void)] = [
            ("p:recenter", "recenter", "Recenter", { [unowned self] in recenter(); note("View recentered", kind: "System") }),
            ("p:desktop", "monitor", "Mac Desktop", { [unowned self] in openDesktop() }),
            ("p:quick", "sliders", "Quick Settings", { [unowned self] in nav("quick") }),
            ("p:library", "apps", "App Library", { [unowned self] in nav("library") }),
        ]
        for (i, (id, ic, label, fn)) in round.enumerated() {
            let r = CGRect(x: c.minX + 20 + CGFloat(i) * 104, y: c.maxY - 190, width: 84, height: 84)
            let h = btn(id, r, fn)
            rr(r, 42, h ? 0x56606eff : 0x3a4452ff)
            icon(ic, r.midX, r.midY, 0xffffffff, 1.05)
            if h { txt(label, c.minX + 20 + CGFloat(round.count) * 104 + 10, r.midY + 10, 28, 0xc9cfd8ff) }
        }
        let resume = CGRect(x: c.minX + 20, y: c.maxY - 90, width: 360, height: 84)
        face(resume, 42, on: btn("resume", resume) { [unowned self] in sounds.play("menuClose"); close() }, base: 0x2d8cffff, hot: 0x4a9dffff)
        txt("Resume", resume.midX, resume.midY + 11, 32, bold: true, align: 0.5)
        let quit = CGRect(x: resume.maxX + 24, y: resume.minY, width: 360, height: 84)
        face(quit, 42, on: btn("quit", quit) { [unowned self] in power() }, base: 0x3a4452ff, hot: 0x56606eff)
        txt("Quit", quit.midX, quit.midY + 11, 32, bold: true, align: 0.5)
        txt(status(["\(fps) fps"]), c.maxX - 20, c.maxY - 38, 26, 0x9aa3afff, align: 1, maxW: 800)
    }

    // MARK: Mac desktop
    /// Desktop picture area (canvas px) - the Compositor lays the live Mac screen exactly over it.
    var desktopRect: CGRect {
        let c = content
        let area = CGRect(x: Dashboard.WIN.minX + 24, y: c.minY - 10, width: Dashboard.WIN.width - 48, height: c.height + 10)   // whole window
        var w = area.width, h = w / desktopAspect
        if h > area.height { h = area.height; w = h * desktopAspect }
        return CGRect(x: area.midX - w / 2, y: area.minY, width: w, height: h)
    }
    private func desktopNormalized(_ p: CGPoint) -> CGPoint? {
        let r = desktopRect
        guard r.insetBy(dx: -4, dy: -4).contains(p) else { return nil }
        return CGPoint(x: min(1, max(0, (p.x - r.minX) / r.width)), y: min(1, max(0, (p.y - r.minY) / r.height)))
    }
    private func drawDesktop() {
        let r = desktopRect
        rr(r.insetBy(dx: -6, dy: -6), 12, 0x000000ff)
        if !desktopStreaming {
            txt("Starting screen capture…", r.midX, r.midY - 10, 32, 0xc9cfd8ff, align: 0.5)
            txt("If it stays blank, allow VR4Mac under Screen & System Audio Recording.", r.midX, r.midY + 40, 26, 0x9aa3afff, align: 0.5, maxW: r.width - 40)
        }
        if desktopTrusted {
            _ = dragRegion("desktop", r) { [unowned self] p, phase in
                if phase == 1 { typed = "" }   // clicking moves the Mac's text cursor: suggestions start over
                if let n = desktopNormalized(p) { desktopPointer(n, phase) } else if phase == 3 { desktopPointer(CGPoint(x: -1, y: -1), 3) }
            }
        } else {
            let b = CGRect(x: r.midX - 520, y: r.maxY - 130, width: 1040, height: 100)
            face(b, 30, on: btn("trust", b) { [unowned self] in requestTrust(); note("Approve VR4Mac under Privacy & Security > Accessibility", 5, kind: "System") }, base: 0x2d8cffff, hot: 0x4a9dffff)
            txt("Allow control: enable VR4Mac in Accessibility", b.midX, b.midY + 10, 30, bold: true, align: 0.5, maxW: b.width - 40)
        }
    }

    // MARK: Quick Settings (SteamVR style: shortcuts, two sliders, status)
    private func drawQuick() {
        let c = content
        var shortcuts: [(String, String, String, Bool, () -> Void)] = gameActive ? [
            ("q:resume", "play", "Resume", false, { [unowned self] in close() }),   // straight back into the game
        ] : []
        shortcuts += [
            ("q:recenter", "recenter", "Recenter", false, { [unowned self] in recenter(); note("View recentered", kind: "System") }),
            ("q:theater", "theater", "Theater", theaterOn, { [unowned self] in theater(!theaterOn) }),
            ("q:desktop", "monitor", "Mac Desktop", false, { [unowned self] in openDesktop() }),
            ("q:env", "mountain", settings["environment"], false, { [unowned self] in nav("spaces") }),
        ]
        shortcuts.append(("q:mic", "mic", "Headset Mic", Mic.shared.useHeadset, { [unowned self] in toggleMic() }))
        shortcuts.append(("q:dnd", "moon", "Do Not Disturb", settings.bool("dnd"), { [unowned self] in toggleSetting("dnd") }))
        if gameActive { shortcuts.append(("q:quit", "power", "Quit Game", false, { [unowned self] in power() })) }
        let d: CGFloat = 150, gap: CGFloat = shortcuts.count > 6 ? 40 : shortcuts.count > 5 ? 60 : 90, total = CGFloat(shortcuts.count) * d + CGFloat(shortcuts.count - 1) * gap
        for (i, (id, ic, label, on, fn)) in shortcuts.enumerated() {
            let r = CGRect(x: c.midX - total / 2 + CGFloat(i) * (d + gap), y: c.minY + 20, width: d, height: d)
            let h = btn(id, r) { [unowned self] in fn(); redraw() }
            rr(r, d / 2, isPressed(id) ? 0x2a313aff : on ? 0x2d8cffff : h ? 0x4a5462ff : 0x353d49ff)
            icon(ic, r.midX, r.midY, 0xffffffff, 1.7)
            txt(label, r.midX, r.maxY + 50, 28, h ? 0xffffffff : 0xc9cfd8ff, align: 0.5, maxW: d + gap - 10)
        }
        let lx = c.minX, sx = c.minX + 330, sw: CGFloat = 1000
        var y = c.minY + 330
        icon("speaker", lx + 50, y, 0xffffffff, 1.1); txt("Volume", lx + 100, y + 10, 30, bold: true)
        slider("q:vol", CGRect(x: sx, y: y - 25, width: sw, height: 50), Float(sounds.streamVolume) / 100) { [unowned self] v in sounds.streamVolume = Int(v * 100) }
        txt("\(sounds.streamVolume)%", sx + sw + 40, y + 10, 30, 0xc9cfd8ff)
        y += 110
        icon("sun", lx + 50, y, 0xffffffff, 1.1); txt("Brightness", lx + 100, y + 10, 30, bold: true)
        slider("q:bright", CGRect(x: sx, y: y - 25, width: sw, height: 50), Float(sounds.brightness - 20) / 80) { [unowned self] v in
            sounds.brightness = 20 + Int(v * 80)
        }
        txt("\(sounds.brightness)%", sx + sw + 40, y + 10, 30, 0xc9cfd8ff)
        txt(status(fps > 0 ? ["\(fps) fps"] : []), c.minX + 10, c.maxY - 40, 28, 0x9aa3afff, maxW: c.width - 760)
        let pw = CGRect(x: c.maxX - 680, y: c.maxY - 100, width: 320, height: 84)
        face(pw, 42, on: btn("q:power", pw) { [unowned self] in togglePower() })
        icon("power", pw.minX + 52, pw.midY, 0xffffffff, 1.0); txt("Power", pw.minX + 92, pw.midY + 11, 30, bold: true)
        let all = CGRect(x: c.maxX - 340, y: c.maxY - 100, width: 320, height: 84)
        face(all, 42, on: btn("q:all", all) { [unowned self] in nav("settings") })
        icon("gear", all.minX + 52, all.midY, 0xffffffff, 1.0); txt("All Settings", all.minX + 92, all.midY + 11, 30, bold: true)
    }
    private func toggleMic() {   // one tap: talk in games through the headset
        Mic.shared.choice = Mic.shared.useHeadset ? "" : Mic.headset
        note(Mic.shared.useHeadset ? "Headset mic on" : "Headset mic off", kind: "System"); sounds.play(Mic.shared.useHeadset ? "on" : "off")
    }
    private func toggleSetting(_ k: String) { settings.set(k, settings.bool(k) ? "Off" : "On"); sounds.play(settings.bool(k) ? "on" : "off") }

    /// Quest Quick Settings (Horizon OS): big clock and live status on top, pill sliders, toggle tiles, Mac Desktop and
    /// Environment cards, then workspaces.
    private func drawQuickQuest() {
        let c = content, date = Date()
        let tf = DateFormatter(); tf.dateFormat = "h:mm"
        let ap = DateFormatter(); ap.dateFormat = "a"
        let time = tf.string(from: date)
        txt(time, c.minX, c.minY + 50, 58, bold: true)
        txt(ap.string(from: date), c.minX + textW(time, 58, bold: true) + 10, c.minY + 50, 26, 0xa4adb4ff)
        let df = DateFormatter(); df.dateFormat = "EEEE, MMMM d"
        txt(df.string(from: date), c.minX + 2, c.minY + 92, 26, 0xa4adb4ff)
        // status chips: link, stream, headset, fps
        var x = c.minX + 330
        let right = c.maxX - (gameActive ? 560 : 330)
        func chip(_ ic: String, _ s: String, _ tint: UInt32 = 0xe0e5e8ff) {
            let w = textW(s, 25) + 82
            guard x + w <= right else { return }
            let r = CGRect(x: x, y: c.minY + 4, width: w, height: 54)
            rr(r, 27, 0x34404aff); icon(ic, r.minX + 34, r.midY, tint, 0.62); txt(s, r.minX + 60, r.midY + 9, 25, 0xe0e5e8ff)
            x = r.maxX + 12
        }
        chip(linkStatus == "USB" ? "usb" : "wifi", linkStatus == "USB" ? "USB connected" : "Wi-Fi")
        chip("headset", headset.label)
        if streamInfo.isEmpty { chip("gauge", "Not streaming", 0xa4adb4ff) } else { chip("gauge", "\(mbps) Mbps") }
        if fps > 0 { chip("gauge", "\(fps) fps", 0x5ee07aff) }
        if !streamInfo.isEmpty { txt(streamInfo, c.minX + 332, c.minY + 92, 24, 0xa4adb4ff) }
        // right: Resume (game running), power, settings
        let gear = CGRect(x: c.maxX - 200, y: c.minY + 2, width: 200, height: 60)
        face(gear, 30, on: btn("q:all", gear) { [unowned self] in nav("settings") }, base: 0x34404aff, hot: 0x46525dff)
        icon("gear", gear.minX + 38, gear.midY, 0xffffffff, 0.9); txt("Settings", gear.minX + 70, gear.midY + 10, 27, bold: true)
        let pw = CGRect(x: gear.minX - 76, y: c.minY + 2, width: 60, height: 60)
        face(pw, 30, on: btn("q:power", pw) { [unowned self] in togglePower() }, base: 0x34404aff, hot: 0x46525dff)
        icon("power", pw.midX, pw.midY, 0xffffffff, 0.75)
        if gameActive {
            let rs = CGRect(x: pw.minX - 216, y: c.minY + 2, width: 200, height: 60)
            face(rs, 30, on: btn("q:resume", rs) { [unowned self] in close() }, base: 0x2a73f5ff, hot: 0x4a88f7ff)
            icon("play", rs.minX + 38, rs.midY, 0xffffffff, 0.7); txt("Resume", rs.minX + 68, rs.midY + 10, 27, bold: true)
        }
        // pill sliders: blue fill, white knob carrying the icon
        func pill(_ id: String, _ r: CGRect, _ value: Float, _ ic: String, _ set: @escaping (Float) -> Void) {
            let hot = dragRegion(id, r.insetBy(dx: -6, dy: -8)) { [unowned self] p, phase in
                guard phase != 3 else { sounds.play("slider"); return }
                set(min(1, max(0, Float((p.x - r.minX - r.height / 2) / (r.width - r.height))))); redraw()
            }
            rr(r, r.height / 2, 0x34404aff)
            let kx = r.minX + CGFloat(value) * (r.width - r.height)
            rr(CGRect(x: r.minX, y: r.minY, width: kx - r.minX + r.height, height: r.height), r.height / 2, 0x2a73f5ff)
            let g = ease("pill:" + id, hot ? 1 : 0, speed: 22) * 3
            let k = CGRect(x: kx + 5, y: r.minY + 5, width: r.height - 10, height: r.height - 10).insetBy(dx: -g, dy: -g)
            rr(k, k.height / 2, 0xffffffff)
            icon(ic, k.midX, k.midY, 0x1f2b33ff, 0.75)
            if hot { txt("\(Int((value * 100).rounded()))%", r.maxX - 30, r.midY + 10, 27, value > 0.9 ? 0xffffffff : 0xe0e5e8ff, bold: true, align: 1) }
        }
        let sw = (c.width - 24) / 2
        pill("q:vol", CGRect(x: c.minX, y: c.minY + 122, width: sw, height: 66), Float(sounds.streamVolume) / 100, "speaker") { [unowned self] v in sounds.streamVolume = Int(v * 100) }
        pill("q:bright", CGRect(x: c.minX + sw + 24, y: c.minY + 122, width: sw, height: 66), Float(sounds.brightness - 20) / 80, "sun") { [unowned self] v in sounds.brightness = 20 + Int(v * 80) }
        // toggle tiles: icon top-left, name and state bottom-left; on = blue
        let bitrates = Settings.items["bitrate"]!.options, sizes = Settings.items["text_size"]!.options
        let tiles: [(String, String, String, String, Bool, () -> Void)] = [
            ("q:recenter", "recenter", "Recenter", "Face forward", false, { [unowned self] in recenter(); note("View recentered", kind: "System") }),
            ("q:theater", "theater", "Theater", theaterOn ? "On" : "Off", theaterOn, { [unowned self] in theater(!theaterOn) }),
            ("q:touch", "hand", "Direct Touch", settings.bool("direct_touch") ? "On" : "Off", settings.bool("direct_touch"), { [unowned self] in toggleSetting("direct_touch") }),
            ("q:mic", "mic", "Headset Mic", Mic.shared.useHeadset ? "On" : "Off", Mic.shared.useHeadset, { [unowned self] in toggleMic() }),
            ("q:dnd", "moon", "Do Not Disturb", settings.bool("dnd") ? "On" : "Off", settings.bool("dnd"), { [unowned self] in toggleSetting("dnd") }),
            ("q:bitrate", "gauge", "Stream Quality", settings["bitrate"] == "Auto" ? "Auto · \(mbps) Mbps" : "\(mbps) Mbps", false, { [unowned self] in
                let i = bitrates.firstIndex(of: settings["bitrate"]) ?? 0; settings.set("bitrate", bitrates[(i + 1) % bitrates.count]); sounds.play("on") }),
            ("q:style", "apps", "Menu Style", settings["menu_style"], false, { [unowned self] in settings.cycle("menu_style"); sounds.play("on") }),
            ("q:text", "text", "Text Size", settings["text_size"], settings["text_size"] != "Default", { [unowned self] in
                let i = sizes.firstIndex(of: settings["text_size"]) ?? 0; settings.set("text_size", sizes[(i + 1) % sizes.count]); sounds.play("on") }),
            ("q:notes", "bell", "Notifications", unread > 0 ? "\(unread) new" : notices.isEmpty ? "None" : "\(notices.count)", false, { [unowned self] in nav("notifications") }),
            gameActive ? ("q:quit", "power", "Quit Game", gameName.isEmpty ? "Running" : gameName, false, { [unowned self] in power() })
                : ("q:hands", "hand", "Hand Tracking", "How to", false, { [unowned self] in
                    note("Put your controllers down: pinch to click, pinch and drag to scroll, left palm pinch opens the menu", 6, kind: "System") }),
            ("q:shot", "camera", "Screenshot", "To Pictures", false, { [unowned self] in screenshot() }),
            ("q:macwin", "monitor", "Mac Windows", "Bring into VR", false, { [unowned self] in openMacWindows() }),
        ]
        let tw = (c.width - 5 * 16) / 6
        for (i, (id, ic, label, sub, on, fn)) in tiles.enumerated() {
            let r = CGRect(x: c.minX + CGFloat(i % 6) * (tw + 16), y: c.minY + 212 + CGFloat(i / 6) * 140, width: tw, height: 126)
            let h = btn(id, r) { [unowned self] in fn(); redraw() }
            lifted(id, r, 26, hot: h, ring: false) { b in
                rr(b, 26, on ? (h ? 0x4a88f7ff : 0x2a73f5ff) : h ? 0x56636fff : 0x46525dff)
                rr(CGRect(x: b.minX + 16, y: b.minY + 12, width: 42, height: 42), 21, on ? 0xffffff30 : 0x00000022)
                icon(ic, b.minX + 37, b.minY + 33, 0xffffffff, 0.62)
                txt(label, b.minX + 22, b.maxY - 40, 27, bold: true, maxW: b.width - 34)
                txt(sub, b.minX + 22, b.maxY - 12, 23, on ? 0xe6efffff : 0xc0c8ceff, maxW: b.width - 34)
            }
        }
        // cards: Mac Desktop and Environment (with a peek of your home)
        let cw = (c.width - 16) / 2
        for (i, id) in ["q:desktop", "q:env"].enumerated() {
            let r = CGRect(x: c.minX + CGFloat(i) * (cw + 16), y: c.minY + 504, width: cw, height: 140)
            let h = btn(id, r) { [unowned self] in if id == "q:env" { nav("spaces") } else { openDesktop() }; redraw() }
            lifted(id, r, 28, hot: h, ring: false) { [unowned self] b in
                if id == "q:env" { cover(Dashboard.envThumb(settings["environment"]), b, "", rad: 28); scrim(b, 28, fromLeft: true, strength: 0.9) }
                else { rr(b, 28, h ? 0x56636fff : 0x46525dff) }
                icon(id == "q:env" ? "mountain" : "monitor", b.minX + 50, b.midY, 0xffffffff, 1.1)
                txt(id == "q:env" ? "Environment" : "Mac Desktop", b.minX + 100, b.midY - 4, 34, bold: true, maxW: b.width - 140)
                txt(id == "q:env" ? settings["environment"] + "  ·  " + settings["home_style"] : desktopStreaming ? "Streaming your Mac" : "See and use your Mac",
                    b.minX + 100, b.midY + 36, 25, 0xd2d8dcff, maxW: b.width - 140)
                icon("next", b.maxX - 40, b.midY, 0xd2d8dcff, 0.7)
            }
        }
        if quest && drawingSlot == 1 {
            caption("Workspaces", c.minX, c.minY + 704)
            let bw = (c.width - 260 - 3 * 20) / 4   // Play, Focus, Explore, then the full Workspace overview
            for (i, name) in ["Play", "Focus", "Explore"].enumerated() {
                homeAction("workspace:" + name, name, ["play", "monitor", "home"][i], CGRect(x: c.minX + 260 + CGFloat(i) * (bw + 20), y: c.minY + 664, width: bw, height: 64)) { [unowned self] in workspace(name) }
            }
            homeAction("q:windows", "All windows", "grid", CGRect(x: c.maxX - bw, y: c.minY + 664, width: bw, height: 64)) { [unowned self] in nav("overview") }
        }
    }

    /// Apply predictable three-window layouts using the existing spatial slots.
    private func workspace(_ name: String) {
        guard quest else { nav(name == "Explore" ? "spaces" : "home"); return }
        if name == "Focus" && !settings.bool("show_desktop_tabs") { openDesktop(); return }
        sideViews = [nil, nil]; navigationHistory = [[], [], []]
        switch name {
        case "Focus":
            view = "desktop"; sideViews = ["home", "quick"]
        case "Explore": view = "spaces"; sideViews = ["home", "library"]
        default: view = gameActive ? "playing" : "home"
        }
        recenter(); sounds.play("open"); redraw()
    }

    // MARK: power menu: a sheet over the window
    private func drawPower() {
        let w = Dashboard.WIN
        let a = ease("power", 1, speed: 20)
        btn("power:dismiss", w) { [unowned self] in powerOpen = false; sounds.play("back"); redraw() }   // tap outside the sheet closes it
        rr(w, 30, 0x00000000 | UInt32(168 * a))
        let sheet = CGRect(x: w.midX - 600, y: w.minY + 70 + 30 * (1 - a), width: 1200, height: 730)
        btn("power:sheet", sheet) {}   // taps on the sheet's background do nothing
        ctx.saveGState(); ctx.setAlpha(a)
        ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 60, color: CGColor(gray: 0, alpha: 0.7))
        rr(sheet, 40, 0x1c272eff); ctx.restoreGState()
        ctx.saveGState(); ctx.setAlpha(a)
        icon("power", sheet.minX + 64, sheet.minY + 70, 0xffffffff, 1.0)
        txt("Power", sheet.minX + 104, sheet.minY + 84, 40, bold: true)
        txt(gameActive ? "Playing " + (gameName.isEmpty ? "a game" : gameName) : "No game running  ·  " + status([]), sheet.minX + 104, sheet.minY + 126, 26, 0xa4adb4ff, maxW: sheet.width - 160)
        let items: [(id: String, ic: String, label: String, sub: String, tint: UInt32, on: Bool, fn: () -> Void)] = [
            ("power:resume", "play", gameActive ? "Resume" : "Close Menu", gameActive ? "Back to your game" : "Back to your home", 0x2a73f5ff, true,
             { [unowned self] in powerOpen = false; close() }),
            ("power:quit", "x", "Quit Game", gameActive ? "Ends " + (gameName.isEmpty ? "the game" : gameName) : "No game running", 0xd9534fff, gameActive,
             { [unowned self] in powerOpen = false; power() }),
            ("power:recenter", "recenter", "Recenter", "Face forward again", 0x46525dff, true,
             { [unowned self] in powerOpen = false; recenter(); note("View recentered", kind: "System") }),
            ("power:refresh", "refresh", "Refresh Video", "Fix a frozen picture", 0x46525dff, true,
             { [unowned self] in refreshStream(); note("Video refreshed", kind: "Connection") }),
            ("power:theater", "theater", theaterOn ? "Leave Theater" : "Theater", theaterOn ? "Back to your home" : "Mac on a big screen", 0x46525dff, true,
             { [unowned self] in powerOpen = false; theater(!theaterOn) }),
            ("power:exit", "exit", quitArmed ? "Tap again to quit" : "Quit MacVR", quitArmed ? "Streaming stops" : "Stop streaming", quitArmed ? 0xd9534fff : 0x46525dff, true,
             { [unowned self] in
                 if quitArmed { DispatchQueue.main.async { NSApplication.shared.terminate(nil) } } else { quitArmed = true; sounds.play("error"); redraw() } }),
        ]
        let tw = (sheet.width - 96 - 2 * 24) / 3, th: CGFloat = 200
        for (i, it) in items.enumerated() {
            let r = CGRect(x: sheet.minX + 48 + CGFloat(i % 3) * (tw + 24), y: sheet.minY + 170 + CGFloat(i / 3) * (th + 24), width: tw, height: th)
            let h = it.on && btn(it.id, r) { it.fn(); }
            lifted(it.id, r, 30, hot: h, ring: false) { b in
                rr(b, 30, !it.on ? 0x2a3640ff : h ? (it.tint == 0x46525dff ? 0x56636fff : it.tint) : 0x34404aff)
                rr(CGRect(x: b.minX + 26, y: b.minY + 26, width: 72, height: 72), 36, it.on ? it.tint : 0x34404aff)
                icon(it.ic, b.minX + 62, b.minY + 62, it.on ? 0xffffffff : 0x7d8a95ff, 0.95)
                txt(it.label, b.minX + 28, b.maxY - 58, 32, it.on ? 0xffffffff : 0x7d8a95ff, bold: true, maxW: b.width - 50)
                txt(it.sub, b.minX + 28, b.maxY - 22, 24, it.on ? 0xc0c8ceff : 0x6b7880ff, maxW: b.width - 50)
            }
        }
        let cancel = CGRect(x: sheet.midX - 150, y: sheet.maxY - 96, width: 300, height: 68)
        face(cancel, 34, on: btn("power:cancel", cancel) { [unowned self] in powerOpen = false; sounds.play("back"); redraw() }, base: 0x34404aff, hot: 0x46525dff)
        txt("Cancel", cancel.midX, cancel.midY + 10, 28, bold: true, align: 0.5)
        ctx.restoreGState()
    }

    // MARK: Settings: sidebar with search, sections of described rows, live preview
    private static let sections: [(id: String, icon: String, label: String)] = [
        ("general", "gear", "General"), ("video", "monitor", "Display & Video"), ("controllers", "controller", "Controllers"),
        ("audio", "speaker", "Audio"), ("environment", "mountain", "Environment"), ("menu", "apps", "Universal Menu"),
        ("accessibility", "access", "Accessibility"), ("about", "info", "About"),
    ]
    private static let sectionKeys: [String: [String]] = [
        "general": ["render_scale", "refresh_rate"], "video": ["bitrate", "codec", "show_fps", "perf_hud", "theater_screen", "theater_curved", "theater_lights"],
        "controllers": ["controller_model", "system_button"], "environment": ["home_style", "floor_grid"],
        "menu": ["menu_style", "direct_touch", "dashboard_position", "ui_curved", "dnd", "show_desktop_tabs", "show_settings_tab", "show_power"],
        "accessibility": ["text_size", "high_contrast", "reduce_motion", "left_handed"],
    ]
    /// Settings search (pure, tested): rows with a word starting with the query, those matching by name first, then by
    /// description or section name, each in sidebar order.
    static func settingsMatching(_ q: String) -> [String] {
        let q = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        func hit(_ s: String) -> Bool { let l = s.lowercased(); return l.hasPrefix(q) || l.contains(" " + q) || l.contains("-" + q) }
        let all = sections.flatMap { s in (sectionKeys[s.id] ?? []).map { (section: s.label, key: $0) } }
        let named = all.filter { hit(Settings.items[$0.key]?.label ?? "") }.map(\.key)
        return named + all.filter { !named.contains($0.key) && (hit(Settings.items[$0.key]?.info ?? "") || hit($0.section)) }.map(\.key)
    }
    private func drawSettings() {
        let w = Dashboard.WIN
        let side = CGRect(x: w.minX + 24, y: content.minY, width: 440, height: content.height - 4)
        // search field (types on the pop-up keyboard)
        let sf = CGRect(x: side.minX, y: side.minY, width: side.width, height: 64)
        face(sf, 32, on: btn("set:search", sf) { [unowned self] in settingsSearch = true; sounds.play("open"); redraw() }, base: settingsSearch ? 0x3c4654ff : 0x303945ff)
        if settingsSearch { outline(sf.insetBy(dx: 1.5, dy: 1.5), 32, 0x2d8cffff, 3) }
        icon("search", sf.minX + 38, sf.midY, 0x9aa3afff, 0.9)
        txt(settingsQuery.isEmpty ? "Search settings" : settingsQuery + (settingsSearch ? "▏" : ""), sf.minX + 70, sf.midY + 10, 27, settingsQuery.isEmpty ? 0x9aa3afff : 0xffffffff, maxW: sf.width - 140)
        if !settingsQuery.isEmpty {
            let x = CGRect(x: sf.maxX - 58, y: sf.minY + 6, width: 52, height: 52)
            face(x, 26, on: btn("set:clear", x) { [unowned self] in settingsQuery = ""; flicks["settings"] = nil; sounds.play("back"); redraw() }, base: 0x00000000)
            icon("x", x.midX, x.midY, 0xffffffff, 0.7)
        }
        for (i, s) in Dashboard.sections.enumerated() {
            let r = CGRect(x: side.minX, y: side.minY + 84 + CGFloat(i) * 80, width: side.width, height: 70)
            let sel = section == s.id && settingsQuery.isEmpty
            let h = btn("sec:" + s.id, r) { [unowned self] in
                if section != s.id || !settingsQuery.isEmpty { section = s.id; settingsQuery = ""; settingsSearch = false; flicks["settings"] = nil; sounds.play("tap") }; redraw()
            }
            if sel || h { rr(r, 20, sel ? (quest ? 0x2d8cffff : 0x3c4755ff) : 0x323b47ff) }
            icon(s.icon, r.minX + 44, r.midY, sel ? 0xffffffff : 0xc9cfd8ff, 1.0)
            txt(s.label, r.minX + 88, r.midY + 10, 28, sel ? 0xffffffff : 0xc9cfd8ff, bold: sel, maxW: side.width - 100)
        }
        rr(CGRect(x: side.maxX + 22, y: side.minY, width: 2, height: side.height), 1, 0xffffff18)
        let c = CGRect(x: side.maxX + 60, y: side.minY, width: w.maxX - side.maxX - 100, height: side.height)
        let results = settingsQuery.isEmpty ? nil : Dashboard.settingsMatching(settingsQuery)
        txt(results != nil ? "Results for \u{201C}\(settingsQuery)\u{201D}" : Dashboard.sections.first { $0.id == section }?.label ?? "", c.minX, c.minY + 40, 36, bold: true, maxW: c.width)
        let body = CGRect(x: c.minX, y: c.minY + 76, width: c.width, height: c.height - 76)
        let off = flicks["settings"]?.pos ?? 0
        var y = body.minY - off
        var revealY: CGFloat?
        clipped(body.insetBy(dx: -8, dy: 0)) {
            for key in results ?? Dashboard.sectionKeys[section] ?? [] {
                if reveal == key { revealY = y + off - body.minY - 12 }
                y += settingRow(key, CGRect(x: body.minX, y: y, width: body.width - 24, height: 0), clip: body, caption: results != nil) + 14
            }
            if results?.isEmpty == true { txt("No settings match. Try another word.", body.minX + 10, y + 40, 28, 0xa4adb4ff) }
            guard results == nil else { return }
            switch section {
            case "controllers":   // the hand picked in the welcome tour
                let r = CGRect(x: body.minX, y: y, width: body.width - 24, height: 104)
                rr(r, 22, 0x2c343fff)
                txt("Pointing Hand", r.minX + 30, r.minY + 46, 30)
                txt("The controller that drives the menu first. Applies when the headset reconnects.", r.minX + 30, r.minY + 82, 24, 0xa4adb4ff, maxW: r.width - 360)
                segmented("set:hand", CGRect(x: r.maxX - 284, y: r.midY - 32, width: 260, height: 64), ["Left", "Right"], Dashboard.pointingHand, clip: body) { i in
                    Dashboard.pointingHand = i
                }
                y += 118
            case "audio":
                let sx = body.minX + 300, sw = body.width - 480
                for (id, label, value, set) in [
                    ("s:vol", "Headset Audio", Float(sounds.streamVolume) / 100, { [unowned self] (v: Float) in sounds.streamVolume = Int(v * 100) }),
                    ("s:macvol", "Mac Volume", Float(max(0, macVolume)) / 100, { [unowned self] (v: Float) in macVolume = Int(v * 100); setMacVolume(macVolume) }),
                    ("s:ui", "Menu Sounds", Float(sounds.volume) / 100, { [unowned self] (v: Float) in sounds.volume = Int(v * 100) }),
                    ("s:bal", "Balance", Float(sounds.balance + 50) / 100, { [unowned self] (v: Float) in let b = Int(v * 100) - 50; sounds.balance = abs(b) < 4 ? 0 : b }),
                ] as [(String, String, Float, (Float) -> Void)] {
                    txt(label, body.minX + 10, y + 50, 30, bold: true)
                    slider(id, CGRect(x: sx, y: y + 16, width: sw, height: 50), value, set)
                    txt("\(Int((value * 100).rounded()))" + (id == "s:bal" ? "" : "%"), sx + sw + 34, y + 51, 26, 0xa4adb4ff)
                    y += 100
                }
                // Microphone: click cycles Mac inputs and the headset mic (games record from the chosen one)
                let mic = CGRect(x: body.minX, y: y, width: body.width - 24, height: 84)
                face(mic, 22, on: btn("s:mic", mic) { [unowned self] in
                    let o = Mic.shared.options(), i = o.firstIndex { $0.0 == Mic.shared.choice } ?? 0
                    Mic.shared.choice = o[(i + 1) % o.count].0; note("Microphone: " + Mic.shared.label, kind: "System"); redraw()
                }, base: 0x2c343fff)
                icon("mic", mic.minX + 40, mic.midY, 0xffffffff, 0.9)
                txt("Microphone", mic.minX + 76, mic.midY + 11, 30)
                txt(Mic.shared.label + "  ›", mic.maxX - 30, mic.midY + 11, 28, 0xc9cfd8ff, align: 1, maxW: mic.width - 360)
                y += 100
                let mr = CGRect(x: body.minX, y: y, width: body.width - 24, height: 84)
                face(mr, 22, on: btn("s:mono", mr) { [unowned self] in sounds.mono.toggle(); sounds.play(sounds.mono ? "on" : "off"); redraw() }, base: 0x2c343fff)
                txt("Mono Audio", mr.minX + 30, mr.midY + 11, 30)
                toggle(CGRect(x: mr.maxX - 130, y: mr.midY - 24, width: 96, height: 48), sounds.mono, id: "mono")
                y += 100
            case "environment":
                let envs = Settings.items["environment"]!.options, tw = (body.width - 24 - 40) / 3, th = tw * 0.5
                for (i, e) in envs.enumerated() {
                    let r = CGRect(x: body.minX + CGFloat(i % 3) * (tw + 20), y: y + CGFloat(i / 3) * (th + 70), width: tw, height: th)
                    let sel = settings["environment"] == e
                    let h = r.intersection(body).height > 40 && btn("env:\(i)", r.intersection(body)) { [unowned self] in settings.set("environment", e); sounds.play("env"); note("Home: \(e)", kind: "System") }
                    lifted("env:\(i)", r, 18, hot: h, ring: !sel) { b in
                        if let img = Dashboard.envThumb(e) { cover(img, b, e, rad: 18) } else { grad(b, 18, 0x3a2a6cff, 0x140c30ff) }
                        if sel { outline(b.insetBy(dx: -5, dy: -5), 22, 0x2d8cffff, 5) }
                    }
                    txt(e, r.midX, r.maxY + 44, 28, sel ? 0xffffffff : 0xc9cfd8ff, bold: sel, align: 0.5)
                }
                y += CGFloat((envs.count + 2) / 3) * (th + 70)
            case "accessibility":   // the whole menu is the live preview; this card shows the type and contrast up close
                let r = CGRect(x: body.minX, y: y + 4, width: body.width - 24, height: 168)
                rr(r, 24, 0x2c343fff); outline(r, 24, 0xffffff18, 2)
                caption("Preview", r.minX + 30, r.minY + 40)
                txt("Aa", r.minX + 30, r.maxY - 34, 72, bold: true)
                txt("The quick brown fox jumps over the lazy dog.", r.minX + 170, r.minY + 92, 30, maxW: r.width - 520)
                txt(reduceMotion ? "Animations are off." : "Secondary text, like this, explains things.", r.minX + 170, r.minY + 134, 25, 0xa4adb4ff, maxW: r.width - 520)
                toggle(CGRect(x: r.maxX - 126, y: r.midY - 24, width: 96, height: 48), true, id: "preview")
                let b = CGRect(x: r.maxX - 340, y: r.midY - 28, width: 190, height: 56)
                rr(b, 28, 0x2d8cffff); txt("Button", b.midX, b.midY + 10, 27, bold: true, align: 0.5)
                y += 186
            case "about":
                for (k, v) in [("Version", version), ("Headset", headset.label), ("Link", linkStatus), ("Stream", streamInfo.isEmpty ? "not connected" : streamInfo),
                               ("Games", "\(library.count) owned · \(library.filter(\.installed).count) installed")] {
                    txt(k, body.minX + 10, y + 44, 30, bold: true); txt(v, body.minX + 330, y + 44, 30, 0xc9cfd8ff, maxW: body.width - 360); y += 70
                }
                let t = CGRect(x: body.minX, y: y + 20, width: 460, height: 80)
                face(t, 40, on: btn("s:tutorial", t) { [unowned self] in startTutorial() }, base: 0x2d8cffff, hot: 0x4a9dffff)
                txt("Replay Welcome Tour", t.midX, t.midY + 10, 29, bold: true, align: 0.5); y += 130
                txt("Runtime log: /tmp/vr4mac/runtime.log", body.minX + 10, y + 30, 26, 0x9aa3afff)
                txt("MacVR log: ~/Library/Application Support/VR4Mac/macvr.log", body.minX + 10, y + 70, 26, 0x9aa3afff); y += 100
                txt("Environments: Poly Haven (CC0) · Controller models: WebXR Input Profiles (MIT)", body.minX + 10, y + 30, 26, 0x9aa3afff, maxW: body.width); y += 60
            default: break
            }
        }
        let maxOff = max(0, y + off - body.maxY)
        flicks["settings", default: Flick()].limit = maxOff
        if let ry = revealY { flicks["settings"]!.set(ry); reveal = nil; keepAnimating() }
        scrollbar(body, off, maxOff)
    }
    /// One Settings row: name, description and its control (switch, segmented choice, or menu-style previews). Returns its height.
    private func settingRow(_ key: String, _ r0: CGRect, clip: CGRect, caption showSection: Bool = false) -> CGFloat {
        guard let it = Settings.items[key] else { return 0 }
        let v = settings[key], isToggle = it.options == Settings.offOn, styles = key == "menu_style"
        let cell = it.options.map { textW($0, 26, bold: true) + 36 }.max() ?? 0   // every option fits its cell
        let ctlW: CGFloat = isToggle ? 120 : styles ? 460 : min(CGFloat(it.options.count) * max(116, cell), 640)
        let tw = r0.width - ctlW - 90
        let lines = it.info.isEmpty ? [] : wrap(it.info, 24, tw, maxLines: 3)
        let h = max(styles ? 190 : 104, 70 + CGFloat(lines.count) * 33 * textScale + (showSection ? 30 : 0))
        let r = CGRect(x: r0.minX, y: r0.minY, width: r0.width, height: h)
        guard r.maxY > clip.minY - 10, r.minY < clip.maxY + 10 else { return h }   // scrolled out of view
        let vis = r.intersection(clip)
        let hot = vis.height > 30 && btn("set:" + key, vis) { [unowned self] in
            settings.cycle(key); sounds.play(isToggle ? (v == "On" ? "off" : "on") : "tap"); redraw()
        }
        face(r, 22, on: hot, base: 0x2c343fff)
        if let hl = highlight, hl.key == key {   // opened from search: a blue ring pulses twice
            let t = now - hl.since
            if t < 1.6 { outline(r.insetBy(dx: -3, dy: -3), 24, 0x2d8cff00 | UInt32(255 * (0.5 + 0.5 * cos(t * 4 * .pi)) * (1 - t / 1.6)), 4); keepAnimating() } else { highlight = nil }
        }
        var ty = r.minY + 46
        if showSection, let s = Dashboard.sections.first(where: { Dashboard.sectionKeys[$0.id]?.contains(key) == true }) { caption(s.label, r.minX + 30, r.minY + 38); ty += 30 }
        txt(it.label, r.minX + 30, ty, 30, maxW: tw)
        for (i, l) in lines.enumerated() { txt(l, r.minX + 30, ty + 36 + CGFloat(i) * 33 * textScale, 24, 0xa4adb4ff, maxW: tw) }
        if isToggle { toggle(CGRect(x: r.maxX - 130, y: r.midY - 24, width: 96, height: 48), v == "On", id: key) }
        else if styles {   // live previews of the two menus
            for (i, name) in it.options.enumerated() {
                let p = CGRect(x: r.maxX - 24 - ctlW + CGFloat(i) * 236, y: r.minY + 22, width: 220, height: h - 44)
                let sel = v == name, hit = p.intersection(clip)
                let ph = hit.height > 30 && btn("set:\(key):\(i)", hit) { [unowned self] in settings.set(key, name); sounds.play("on"); redraw() }
                rr(p, 18, ph ? 0x46525dff : 0x222932ff)
                if sel { outline(p, 18, 0x2d8cffff, 4) }
                let win = CGRect(x: p.minX + 34, y: p.minY + 16, width: p.width - 68, height: 52)
                rr(win, 8, 0x5d6a75ff)
                if i == 0 {   // Quest: title bar at the bottom, small dock below
                    rr(CGRect(x: win.minX, y: win.maxY - 12, width: win.width, height: 12), 4, 0x3d4a55ff)
                    rr(CGRect(x: p.midX - 46, y: win.maxY + 9, width: 92, height: 15), 5, 0x2a73f5ff)
                } else {      // SteamVR: title on top, wide bar below
                    rr(CGRect(x: win.minX, y: win.minY, width: win.width, height: 12), 4, 0x3d4a55ff)
                    rr(CGRect(x: p.minX + 18, y: win.maxY + 9, width: p.width - 36, height: 15), 7.5, 0x2a73f5ff)
                }
                txt(name, p.midX, p.maxY - 14, 25, sel ? 0xffffffff : 0xc9cfd8ff, bold: sel, align: 0.5)
            }
        } else {
            segmented("set:\(key)", CGRect(x: r.maxX - ctlW - 24, y: r.midY - 32, width: ctlW, height: 64), it.options, it.options.firstIndex(of: v) ?? 0, clip: clip) { [unowned self] i in
                settings.set(key, it.options[i])
            }
        }
        return h
    }
    private static var thumbs: [String: CGImage] = [:]
    /// Small preview of an environment panorama (nil for the procedural void, or in tests without the app bundle).
    static func envThumb(_ name: String) -> CGImage? {
        if let t = thumbs[name] { return t }
        guard let file = Dashboard.envFile(name), let url = Bundle.main.url(forResource: file, withExtension: "jpg", subdirectory: "environments"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary)
        else { return nil }
        thumbs[name] = img
        return img
    }
    static func envFile(_ name: String) -> String? {
        ["Golden Bay": "golden_bay", "Venice Sunset": "venice_sunset", "Rooftop Night": "rooftop_night",
         "Kloofendal Sky": "kloofendal_48d_partly_cloudy_puresky", "Lilienstein": "lilienstein", "Starry Night": "dikhololo_night",
         "Forest": "forest_slope", "Snowy Park": "snowy_park_01", "Fireside": "fireplace", "Sky On Fire": "the_sky_is_on_fire",
         "Harbour Sunset": "small_harbour_sunset", "Moonless Night": "moonless_golf"][name]
    }

    // MARK: game details: art, play history, actions and per-game options (resolution / world scale / theater)
    private func drawAppSettings() {
        guard let g = settingsFor else { view = "library"; return }
        let c = content
        let banner = CGRect(x: c.minX, y: c.minY, width: c.width, height: 300)
        cover(games.image(g.appid, "library_hero") ?? games.image(g.appid, "header"), banner, g.name, rad: 26)
        scrim(banner, 26, strength: 0.95)
        let back = CGRect(x: banner.minX + 20, y: banner.minY + 20, width: 64, height: 64)
        face(back, 32, on: btn("as:back", back) { [unowned self] in nav("library") }, base: 0x000000a0, hot: 0x46525dff)
        icon("back", back.midX - 2, back.midY, 0xffffffff, 0.9)
        txt(g.name, banner.minX + 36, banner.maxY - 66, 54, bold: true, maxW: banner.width - 72)
        var x = banner.minX + 36
        for (s, on) in [(g.vr ? "VR" : "Flatscreen", false), (g.installed ? "Installed" : g.progress.map { "Downloading \(Int($0 * 100))%" } ?? "Not installed", g.installed),
                        (isPinned(g.appid) ? "Pinned" : "", true)] where !s.isEmpty {
            let w = textW(s, 24, bold: true) + 36, r = CGRect(x: x, y: banner.maxY - 48, width: w, height: 38)
            rr(r, 19, on ? 0x2a73f5d0 : 0x000000a0); txt(s, r.midX, r.midY + 9, 24, bold: true, align: 0.5); x = r.maxX + 10
        }
        // actions
        let ay = banner.maxY + 24
        homeAction("as:play", g.installed ? (gameActive && playingGame == g ? "Resume" : "Play") : g.progress != nil ? "Downloading" : "Install",
                   g.installed ? "play" : "download", CGRect(x: c.minX, y: ay, width: 250, height: 76), primary: true) { [unowned self] in
            if gameActive && playingGame == g { close() } else { start(g) }
        }
        if g.installed {
            homeAction("as:theaterplay", "Theater", "theater", CGRect(x: c.minX + 266, y: ay, width: 230, height: 76)) { [unowned self] in
                if !theaterOn { theater(true) }; pushRecent(g.appid); sounds.play("launch"); launch(g)
            }
        }
        homeAction("as:pin", isPinned(g.appid) ? "Unpin" : "Pin to Dock", "pin", CGRect(x: c.minX + (g.installed ? 512 : 266), y: ay, width: 250, height: 76)) { [unowned self] in
            togglePin(g.appid); note(isPinned(g.appid) ? "\(g.name) pinned to the dock" : "\(g.name) unpinned", kind: "Games"); redraw()
        }
        // play history
        let last = Dashboard.lastPlayed(g.appid), played = Dashboard.playTime(g.appid) + (session?.id == g.appid ? Date().timeIntervalSince(session!.since) : 0)
        let stats = [("clock", "Last played", gameActive && playingGame == g ? "Now" : last > 0 ? Dashboard.ago(Date(timeIntervalSince1970: last)) : "Never"),
                     ("play", "Play time", played > 0 ? Dashboard.duration(played) : "None yet"),
                     ("controller", "Type", g.vr ? "VR" : "Flatscreen")]
        let sw: CGFloat = (820 - 2 * 16) / 3
        for (i, (ic, k, v)) in stats.enumerated() {
            let r = CGRect(x: c.minX + CGFloat(i) * (sw + 16), y: ay + 100, width: sw, height: 130)
            rr(r, 22, 0x2c343fff)
            icon(ic, r.minX + 38, r.minY + 40, 0x9cd7ffff, 0.7)
            caption(k, r.minX + 66, r.minY + 49)
            txt(v, r.minX + 26, r.maxY - 30, 32, bold: true, maxW: r.width - 40)
        }
        // the game's latest Steam news, else how to reach this page quickly
        let news = games.news.first { $0.appid == g.appid }
        let nr = CGRect(x: c.minX, y: ay + 250, width: 820, height: 100)
        rr(nr, 22, 0x2c343fff)
        icon(news == nil ? "tips" : "globe", nr.minX + 38, nr.minY + 36, 0x9cd7ffff, 0.7)
        caption(news.map { "News  ·  " + Dashboard.ago($0.date) } ?? "Tip", nr.minX + 66, nr.minY + 45)
        txt(news?.title ?? "Hold a game in the App Library, or grip it, to open this page.", nr.minX + 26, nr.maxY - 22, 26, maxW: nr.width - 50)
        // options
        let ox = c.minX + 860, ow = c.maxX - ox
        caption("Options", ox, ay + 20)
        txt("Scale changes live; resolution on the next launch.", ox, ay + 56, 24, 0xa4adb4ff, maxW: ow)
        var y = ay + 80
        for (key, label, opts) in [("render", "Render Resolution", [0, 50, 75, 100, 125, 150]), ("world", "World Scale", [0, 50, 75, 100, 125, 150, 200])] {
            txt(label, ox, y + 36, 28, bold: true)
            let cur = Dashboard.override(g.appid, key)
            segmented("as:" + key, CGRect(x: ox, y: y + 50, width: ow, height: 60), opts.map { $0 == 0 ? "Auto" : "\($0)%" },
                      opts.firstIndex(of: cur) ?? 0) { i in Dashboard.setOverride(g.appid, key, opts[i]) }
            y += 126
        }
        let t = CGRect(x: ox, y: y + 6, width: ow, height: 76), on = Dashboard.override(g.appid, "theater") == 1
        face(t, 22, on: btn("as:theater", t) { [unowned self] in Dashboard.setOverride(g.appid, "theater", on ? 0 : 1); sounds.play(on ? "off" : "on"); redraw() }, base: 0x2c343fff)
        txt("Always open in Theater", t.minX + 26, t.midY + 10, 28)
        toggle(CGRect(x: t.maxX - 124, y: t.midY - 24, width: 96, height: 48), on, id: "theater" + g.appid)
        if g.installed && g.appid.allSatisfy(\.isNumber) {
            let u = CGRect(x: c.minX, y: c.maxY - 66, width: 230, height: 60)
            face(u, 30, on: btn("as:uninstall", u) { [unowned self] in uninstall(g) }, base: 0x00000000, hot: 0x5a2a2aff)
            icon("trash", u.minX + 34, u.midY, 0xff7a7aff, 0.75); txt("Uninstall", u.minX + 64, u.midY + 10, 26, 0xff9a9aff, bold: true)
        }
    }

    // MARK: Notifications: grouped by kind, timestamped, with actions and dismiss
    private func drawNotifications() {
        let c = content
        let dnd = settings.bool("dnd")
        if drawingSlot == 1 || sideViews.contains("notifications") { unread = 0 }   // on screen = read
        txt(notices.isEmpty ? "Notifications" : "\(notices.count) notification\(notices.count == 1 ? "" : "s")", c.minX + 8, c.minY + 42, 36, bold: true)
        let dn = CGRect(x: c.maxX - (notices.isEmpty ? 300 : 560), y: c.minY, width: 300, height: 60)
        face(dn, 30, on: btn("n:dnd", dn) { [unowned self] in toggleSetting("dnd"); redraw() }, base: dnd ? 0x2d8cffff : 0x34404aff, hot: dnd ? 0x4a9dffff : 0x46525dff)
        icon("moon", dn.minX + 40, dn.midY, 0xffffffff, 0.7); txt("Do Not Disturb", dn.minX + 70, dn.midY + 10, 26, bold: true)
        guard !notices.isEmpty else {
            let m = CGPoint(x: c.midX, y: c.midY - 30)
            rr(CGRect(x: m.x - 90, y: m.y - 90, width: 180, height: 180), 90, 0x34404aff)
            icon("bell", m.x, m.y, 0xa4adb4ff, 2.6)
            txt("You're all caught up", c.midX, m.y + 150, 36, bold: true, align: 0.5)
            txt(dnd ? "Do Not Disturb is on. New notifications collect here quietly." : "Downloads, game launches and connection news show up here.", c.midX, m.y + 196, 27, 0xa4adb4ff, align: 0.5)
            return
        }
        let ca = CGRect(x: c.maxX - 240, y: c.minY, width: 240, height: 60)
        face(ca, 30, on: btn("n:clear", ca) { [unowned self] in clearNotices() }, base: 0x34404aff, hot: 0x46525dff)
        icon("trash", ca.minX + 40, ca.midY, 0xffffffff, 0.65); txt("Clear All", ca.minX + 70, ca.midY + 10, 26, bold: true)
        let area = CGRect(x: c.minX, y: c.minY + 84, width: c.width - 24, height: c.height - 84)
        let off = flicks["notes"]?.pos ?? 0
        var y = area.minY - off
        let groups = Dashboard.noticeKinds.map { k in (k, notices.filter { $0.kind == k.kind }) }.filter { !$0.1.isEmpty }.sorted { $0.1[0].date > $1.1[0].date }
        clipped(area.insetBy(dx: -8, dy: 0)) {
            for (k, items) in groups {
                rr(CGRect(x: area.minX + 4, y: y + 8, width: 44, height: 44), 22, k.color)
                icon(k.icon, area.minX + 26, y + 30, 0xffffffff, 0.6)
                txt(k.kind, area.minX + 64, y + 40, 29, bold: true)
                txt("\(items.count)", area.minX + 76 + textW(k.kind, 29, bold: true), y + 40, 26, 0xa4adb4ff)
                let gc = CGRect(x: area.maxX - 140, y: y + 4, width: 130, height: 52)
                if gc.intersection(area).height > 40 {
                    face(gc, 26, on: btn("n:clear:" + k.kind, gc) { [unowned self] in clearNotices(k.kind) }, base: 0x00000000, hot: 0x46525dff)
                    txt("Clear", gc.midX, gc.midY + 9, 25, 0xd2d8dcff, align: 0.5)
                }
                y += 64
                for n in items {
                    let aw = n.action.map { textW($0.label, 26, bold: true) + 56 } ?? 0
                    let tw = area.width - 300 - aw
                    let lines = wrap(n.text, 28, tw, maxLines: 3)
                    let r = CGRect(x: area.minX, y: y, width: area.width, height: max(92, 40 + CGFloat(lines.count) * 38 * textScale))
                    if r.maxY > area.minY && r.minY < area.maxY {
                        rr(r, 22, n.id == notices.first?.id && Date() < toastUntil ? 0x3a4a56ff : 0x2c343fff)
                        for (i, l) in lines.enumerated() { txt(l, r.minX + 28, r.minY + 56 + CGFloat(i) * 38 * textScale - (lines.count > 1 ? 10 : 0), 28, maxW: tw) }
                        txt(Dashboard.ago(n.date) + (n.count > 1 ? "  ·  ×\(n.count)" : ""), r.maxX - 96 - aw, r.minY + 56, 24, 0xa4adb4ff, align: 1)
                        if let a = n.action {
                            let p = CGRect(x: r.maxX - 80 - aw, y: r.midY - 28, width: aw - 12, height: 56)
                            if p.intersection(area).height > 40 {
                                face(p, 28, on: btn("n:act:\(n.id)", p) { [unowned self] in a.run(); dismissNotice(n.id) }, base: 0x2a73f5ff, hot: 0x4a88f7ff)
                            } else { rr(p, 28, 0x2a73f5ff) }
                            txt(a.label, p.midX, p.midY + 9, 26, bold: true, align: 0.5)
                        }
                        let xr = CGRect(x: r.maxX - 70, y: r.midY - 28, width: 56, height: 56)
                        if xr.intersection(area).height > 40 { face(xr, 28, on: btn("n:x:\(n.id)", xr) { [unowned self] in dismissNotice(n.id) }, base: 0x00000000, hot: 0x46525dff) }
                        icon("x", xr.midX, xr.midY, 0xd2d8dcff, 0.6)
                    }
                    y += r.height + 12
                }
                y += 16
            }
        }
        let maxOff = max(0, y + off - area.maxY)
        flicks["notes", default: Flick()].limit = maxOff
        scrollbar(area, off, maxOff)
    }
    private var toastShowing: Bool { Date() < toastUntil && notices.contains { $0.id == toastID } }
    /// Pop-up toast: slides down and fades in just above the dock (never over a window's controls), with the group's
    /// icon, an optional action, and a tap to open Notifications.
    private func drawToast() {
        guard Date() < toastUntil, let n = notices.first(where: { $0.id == toastID }) else { return }
        let age = now - toastSince, left = toastUntil.timeIntervalSinceNow
        let p = reduceMotion ? 1 : CGFloat(min(1, age / 0.3)), q = reduceMotion ? 1 : CGFloat(min(1, max(0, left / 0.25)))
        if p < 1 || q < 1 { keepAnimating() }
        let e = 1 - pow(1 - p, 3), a = min(e, q)
        let k = Dashboard.noticeKinds.first { $0.kind == n.kind } ?? Dashboard.noticeKinds[3]
        let tw = min(1100, textW(n.text, 28)), aw = n.action.map { textW($0.label, 26, bold: true) + 56 } ?? 0
        let w = 100 + tw + 36 + (aw > 0 ? aw + 12 : 0) + (n.count > 1 ? 70 : 0)
        let y0 = view == "welcome" ? Dashboard.WIN.minY + 24 : max(CGFloat(Dashboard.SPLIT) + 4, dockRect.minY - 82)   // the tour hides the dock
        let r = CGRect(x: CGFloat(Dashboard.W) / 2 - w / 2, y: y0 + 24 * (1 - e), width: w, height: 72)
        btn("toast", r) { [unowned self] in toastUntil = .distantPast; nav("notifications") }
        ctx.saveGState(); ctx.setAlpha(a); ctx.beginTransparencyLayer(in: r.insetBy(dx: -60, dy: -60), auxiliaryInfo: nil)
        ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.55))
        rr(r, 36, 0x0d1117f6); ctx.restoreGState()
        if hover == "toast" { outline(r, 36, 0xffffff60, 2) }
        rr(CGRect(x: r.minX + 14, y: r.midY - 22, width: 44, height: 44), 22, k.color)
        icon(k.icon, r.minX + 36, r.midY, 0xffffffff, 0.6)
        txt(n.text, r.minX + 76, r.midY + 10, 28, maxW: tw)
        if n.count > 1 { txt("×\(n.count)", r.minX + 90 + tw, r.midY + 10, 26, 0xa4adb4ff) }
        if let act = n.action {
            let pr = CGRect(x: r.maxX - aw - 8, y: r.minY + 9, width: aw - 4, height: 54)
            face(pr, 27, on: btn("toast:act", pr) { [unowned self] in act.run(); toastUntil = .distantPast; redraw() }, base: 0x2a73f5ff, hot: 0x4a88f7ff)
            txt(act.label, pr.midX, pr.midY + 9, 26, bold: true, align: 0.5)
        }
        ctx.endTransparencyLayer(); ctx.restoreGState()
        solidExtra.append(r)
    }

    // MARK: first-run welcome tour (questions first, then the controls, then "press your menu button")
    private static let tour: [(kind: String, title: String, body: String, part: String)] = [
        ("intro", "Welcome to MacVR OS", "Play your Steam VR games from your Mac. A few quick questions, then a short tour.", "none"),
        ("name", "What's your name?", "Type it with the keyboard below. Pull the trigger to press keys.", "trigger"),
        ("hand", "Which hand do you point with?", "That controller drives the menus first. Either one works anytime.", "none"),
        ("home", "Pick your home", "This is where you'll land between games. Change it anytime in Settings.", "none"),
        ("style", "Pick your menu", "Quest: a compact dock with app tiles under each window. SteamVR: a wide bar with the title on top. Change it anytime in Settings.", "none"),
        ("comfort", "Make it comfortable", "Pick a text size. High Contrast, Reduce Motion and a left-handed layout are in Settings > Accessibility.", "none"),
        ("info", "Point and select", "Aim at anything and pull the trigger to select it.", "trigger"),
        ("info", "Move windows", "Point at the bar under a window, hold the trigger and move. Push your hand forward to send it further away.", "trigger"),
        ("info", "Scroll", "Push the thumbstick up or down to scroll the library, settings and the Mac desktop. With your finger, just swipe.", "stick"),
        ("info", "More options", "Squeeze the grip on a game for options, or to right-click on the Mac desktop.", "grip"),
        ("hands", "Or use your hands", "Put the controllers down. Pinch your thumb and finger to click, pinch and drag to scroll, and pinch with your left palm facing you for the menu.", "none"),
        ("menu", "Press your menu button", "The menu button is the small ≡ button on your left controller. Press it now to step into your home, and anytime to open MacVR OS.", "none"),
    ]
    private var nameDraft = ""
    var liveTourController = false   // Engine: the 3D tour controller is being shown
    private static let homes = ["Golden Bay", "Venice Sunset", "Forest", "Fireside"]
    private func drawWelcome() {
        let c = content, t = Dashboard.tour[min(step, Dashboard.tour.count - 1)]
        // left: the real controller with the input for this step tinted blue (or the answer UI for questions)
        let box = CGRect(x: c.minX + 30, y: c.minY + 20, width: 560, height: 560)
        if t.kind == "hands" || t.kind == "comfort" {   // our own illustration: a hand (pinch) or big type
            rr(box.insetBy(dx: 60, dy: 60), 220, 0x34404aff)
            if t.kind == "hands" {
                icon("hand", box.midX, box.midY, 0xffffffff, 7)
                let pulse = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(now * 3)
                rr(CGRect(x: box.midX + 88 - 14 * pulse, y: box.midY - 150 - 14 * pulse, width: 28 + 28 * pulse, height: 28 + 28 * pulse), 28, 0x2d8cffc0); if !reduceMotion { keepAnimating() }
            } else { txt("Aa", box.midX, box.midY + 60, 170, bold: true, align: 0.5) }
        } else if t.kind != "home" {
            // the live 3D controller floats here (Compositor.setTourController); the picture is only a fallback
            if !liveTourController, let img = ControllerPortrait.image(headset, part: t.part) {
                ctx.saveGState(); ctx.translateBy(x: box.minX, y: box.maxY); ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(origin: .zero, size: box.size)); ctx.restoreGState()
            }
            let label = ["trigger": "Trigger · index finger", "grip": "Grip · middle finger", "stick": "Thumbstick", "none": t.kind == "menu" ? "≡ Menu button · left controller" : ""][t.part] ?? ""
            if !label.isEmpty {
                let w = textW(label, 28, bold: true) + 60, chip = CGRect(x: box.midX - w / 2, y: box.maxY - 10, width: w, height: 56)
                rr(chip, 28, 0x2d8cffff); txt(label, chip.midX, chip.midY + 10, 28, bold: true, align: 0.5)
            }
        }
        let tx = c.minX + 680, tw = c.maxX - tx - 20
        caption("Step \(step + 1) of \(Dashboard.tour.count)", tx, c.minY + 52)
        txt(t.title, tx, c.minY + 120, 54, bold: true, maxW: tw)
        var y = c.minY + 190 + para(t.body, tx, c.minY + 190, 32, 0xc9cfd8ff, maxW: tw)
        y += 30
        switch t.kind {
        case "name":   // typed on the pop-up keyboard below
            let f = CGRect(x: tx, y: y, width: tw, height: 84)
            rr(f, 42, 0x303945ff); outline(f.insetBy(dx: 1.5, dy: 1.5), 42, 0x2d8cffff, 3)
            txt(nameDraft.isEmpty ? "Your name" : nameDraft + "▏", f.minX + 36, f.midY + 12, 36, nameDraft.isEmpty ? 0x8a93a0ff : 0xffffffff, maxW: f.width - 60)
        case "hand":
            for (i, label) in ["Left", "Right"].enumerated() {
                let r = CGRect(x: tx + CGFloat(i) * (tw / 2 + 10), y: y, width: tw / 2 - 10, height: 150), sel = Dashboard.pointingHand == i
                face(r, 30, on: btn("tour:hand\(i)", r) { [unowned self] in Dashboard.pointingHand = i; sounds.play("on"); redraw() },
                     base: sel ? 0x2d8cffff : 0x353d49ff, hot: sel ? 0x4a9dffff : 0x46505eff)
                icon("hand", r.midX, r.midY - 20, 0xffffffff, 1.6)
                txt(label + " hand", r.midX, r.midY + 52, 32, bold: true, align: 0.5)
            }
        case "style":
            for (i, label) in ["Quest", "SteamVR"].enumerated() {
                let r = CGRect(x: tx + CGFloat(i) * (tw / 2 + 10), y: y, width: tw / 2 - 10, height: 150), sel = settings["menu_style"] == label
                face(r, 30, on: btn("tour:style\(i)", r) { [unowned self] in settings.set("menu_style", label); sounds.play("on"); redraw() },
                     base: sel ? 0x2d8cffff : 0x353d49ff, hot: sel ? 0x4a9dffff : 0x46505eff)
                icon(i == 0 ? "apps" : "grid", r.midX, r.midY - 20, 0xffffffff, 1.6)
                txt(label, r.midX, r.midY + 52, 32, bold: true, align: 0.5)
            }
        case "comfort":
            let sizes = Settings.items["text_size"]!.options
            for (i, label) in sizes.enumerated() {
                let r = CGRect(x: tx + CGFloat(i) * (tw / 3 + 7), y: y, width: tw / 3 - 14, height: 150), sel = settings["text_size"] == label
                face(r, 30, on: btn("tour:text\(i)", r) { [unowned self] in settings.set("text_size", label); sounds.play("on"); redraw() },
                     base: sel ? 0x2d8cffff : 0x353d49ff, hot: sel ? 0x4a9dffff : 0x46505eff)
                txt("Aa", r.midX, r.midY + 6, 40 + CGFloat(i) * 12, bold: true, align: 0.5)
                txt(label, r.midX, r.maxY - 22, 26, bold: sel, align: 0.5)
            }
        case "home":   // big thumbnails on the left area too
            let gw = (c.width - 40 - 3 * 28) / 4, gh = gw * 0.56
            for (i, e) in Dashboard.homes.enumerated() {
                let r = CGRect(x: c.minX + 20 + CGFloat(i) * (gw + 28), y: c.minY + 330, width: gw, height: gh)
                let sel = settings["environment"] == e
                let h = btn("tour:home\(i)", r) { [unowned self] in settings.set("environment", e); sounds.play("env"); redraw() }
                lifted("tour:home\(i)", r, 20, hot: h, ring: false) { b in
                    if let img = Dashboard.envThumb(e) { cover(img, b, e, rad: 20) } else { grad(b, 20, 0x3a2a6cff, 0x140c30ff) }
                }
                if sel { outline(r.insetBy(dx: -8, dy: -8), 26, 0x2d8cffff, 6) }
                txt(e, r.midX, r.maxY + 46, 30, sel ? 0xffffffff : 0xc9cfd8ff, bold: sel, align: 0.5)
            }
        default: break
        }
        for i in 0..<Dashboard.tour.count {   // progress: the current step's pill stretches in
            let x0 = tx + CGFloat(i) * 34 + (i > step ? 24 : 0) * ease("tourdot", 1)
            let wd = i == step ? 16 + 24 * ease("tourdot\(step)", 1, speed: 12) : 16
            rr(CGRect(x: x0, y: c.maxY - 160, width: wd, height: 16), 8, i == step ? 0x2d8cffff : i < step ? 0x8fbcffff : 0x5a6472ff)
        }
        guard t.kind != "menu" else {   // finished by pressing the real menu button (Engine -> finishTutorial)
            txt("Waiting for the menu button…", c.maxX - 20, c.maxY - 60, 30, 0x9ac7ffff, bold: true, align: 1); return
        }
        let canNext = t.kind != "name" || !nameDraft.trimmingCharacters(in: .whitespaces).isEmpty
        let next = CGRect(x: c.maxX - 340, y: c.maxY - 110, width: 320, height: 84)
        face(next, 42, on: btn("tour:next", next) { [unowned self] in
            guard canNext else { sounds.play("error"); return }
            if t.kind == "name" { Dashboard.userName = nameDraft.trimmingCharacters(in: .whitespaces) }
            step += 1; sounds.play("step"); redraw()
        }, base: canNext ? 0x2d8cffff : 0x3a4452ff, hot: canNext ? 0x4a9dffff : 0x46505eff)
        txt("Next", next.midX, next.midY + 11, 32, bold: true, align: 0.5)
        if step > 0 {
            let back = CGRect(x: next.minX - 250, y: next.minY, width: 230, height: 84)
            face(back, 42, on: btn("tour:back", back) { [unowned self] in step -= 1; sounds.play("back"); redraw() })
            txt("Back", back.midX, back.midY + 11, 32, bold: true, align: 0.5)
        }
    }

    // MARK: pop-up keyboard panel (below the Universal Menu): letters/symbols, shift and caps lock, word suggestions,
    // key-press previews; keys' hit areas cover the gaps between them (no dead zones for fingertips)
    private var kbLayer = 0, kbCaps = false, lastShift: CFTimeInterval = 0
    private var keyPop: (label: String, r: CGRect, at: CFTimeInterval)?
    private var typed = ""                // desktop: what was typed since the last space, Return or click (for suggestions)
    /// Common English words, most frequent first (suggestions while typing on the Mac).
    private static let common = ("the and you that was for are with his they this have from one had word but not what all were when your can said there use "
        + "each which she how their will other about out many then them these some her would make like him into time has look two more write see number way "
        + "could people than first water been call who now find long down day did get come made may part over new sound take only little work know place "
        + "year live back give most very after thing our just name good great where help through much before line right too mean old any same tell follow "
        + "came want show also around form three small set put end does another well large must big even such because turn here why ask went men read need "
        + "land different home move try kind hand picture again change off play spell away house point page letter answer found study still learn should "
        + "world high every near add food between own below country last school keep never start city thought head under story saw left few while along "
        + "might close something seem next hard open example begin life always those both paper together got group often run important until children side "
        + "feet night walk white began grow took carry state once book hear stop without second later miss idea enough eat face watch far really almost let "
        + "above girl sometimes young talk soon list song being leave family hello thanks thank please okay yes sorry today tomorrow tonight message email "
        + "password search download settings").split(separator: " ").map(String.init)
    /// Up to three completions for the word being typed (pure, tested): longer words starting with it, in `words` order,
    /// capitalised like what was typed.
    static func suggest(_ text: String, _ words: [String]) -> [String] {
        let w = String(text.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "'" }.reversed())
        guard !w.isEmpty else { return [] }
        var seen = Set<String>(), out: [String] = []
        for c in words where c.count > w.count && c.lowercased().hasPrefix(w.lowercased()) && seen.insert(c.lowercased()).inserted {
            out.append(w.first!.isUppercase ? c.prefix(1).uppercased() + c.dropFirst() : c)
            if out.count == 3 { break }
        }
        return out
    }
    private func kbText(_ target: String) -> String { ["search": searchText, "settings": settingsQuery, "name": nameDraft][target] ?? typed }
    private func kbWords(_ target: String) -> [String] {
        let names = library.flatMap { $0.name.split(separator: " ").map(String.init) }.filter { $0.count > 2 }
        switch target {
        case "search": return names + Dashboard.systemApps.compactMap { Dashboard.apps[$0]?.label } + Settings.items.values.map(\.label)
        case "settings": return Settings.items.values.flatMap { $0.label.split(separator: " ").map(String.init) } + Dashboard.sections.map(\.label)
        default: return Dashboard.common + names
        }
    }
    private func insert(_ s: String, _ target: String) {
        switch target {
        case "search": searchText += s; flicks["library"] = nil; commandPage = 0
        case "settings": settingsQuery += s; flicks["settings"] = nil
        case "name": if nameDraft.count < 24 && !(s == " " && nameDraft.isEmpty) { nameDraft += s }
        default: typeText(s); typed = s == " " ? "" : String((typed + s).suffix(40))
        }
        if kbShift && !kbCaps { kbShift = false }
    }
    private func deleteBack(_ target: String) {
        switch target {
        case "search": if !searchText.isEmpty { searchText.removeLast() }; commandPage = 0
        case "settings": if !settingsQuery.isEmpty { settingsQuery.removeLast() }
        case "name": if !nameDraft.isEmpty { nameDraft.removeLast() }
        default: keyCode(51); if !typed.isEmpty { typed.removeLast() }
        }
    }
    /// target "search" edits the library query, "settings" the settings search, "name" the tour's name, "desktop" types into the Mac.
    private func keyboardPanel(target: String) {
        let p = Dashboard.KB
        rr(p, 36, 0x1f252dff)
        let r = p.insetBy(dx: 30, dy: 26), gap: CGFloat = 12, top: CGFloat = 58
        let kh = (r.height - top - 4 * gap) / 4, kw = min(130, (r.width - 9 * gap) / 10)
        // top strip: the Mac's function keys (desktop), then word suggestions
        var x = r.minX
        if target == "desktop" {
            for (id, label, code) in [("esc", "Esc", 53), ("tab", "Tab", 48), ("left", "◀", 123), ("up", "▲", 126), ("down", "▼", 125), ("right", "▶", 124)] as [(String, String, UInt16)] {
                let k = CGRect(x: x, y: r.minY, width: 104, height: top)
                face(k, 16, on: btn("dt:" + id, k) { [unowned self] in keyCode(code); typed = ""; sounds.play("key") }, base: 0x2c343fff, hot: 0x46505eff)
                txt(label, k.midX, k.midY + 10, 26, bold: true, align: 0.5)
                x = k.maxX + 10
            }
            x += 14
        }
        let sugg = target == "name" ? [] : Dashboard.suggest(kbText(target), kbWords(target))
        if sugg.isEmpty {
            txt(target == "name" ? "Your name stays on this Mac." : "Suggestions appear as you type", (x + r.maxX) / 2, r.minY + top / 2 + 9, 24, 0x6b7685ff, align: 0.5)
        }
        let sw = (r.maxX - x - 2 * 10) / 3
        for (i, s) in sugg.enumerated() {
            let k = CGRect(x: x + CGFloat(i) * (sw + 10), y: r.minY, width: sw, height: top)
            face(k, 16, on: btn("kbsugg:\(i)", k) { [unowned self] in
                let w = String(kbText(target).reversed().prefix { $0.isLetter || $0.isNumber || $0 == "'" }.reversed())
                let rest = String(s.dropFirst(w.count))
                switch target {
                case "search": searchText += rest
                case "settings": settingsQuery += rest
                default: typeText(rest + " "); typed = ""
                }
                sounds.play("key"); redraw()
            }, base: i == 0 ? 0x34404aff : 0x2a313aff, hot: 0x46525dff)
            txt(s, k.midX, k.midY + 10, 28, i == 0 ? 0xffffffff : 0xd2d8dcff, bold: i == 0, align: 0.5, maxW: k.width - 20)
        }
        // keys
        let letters = kbLayer == 0, upper = letters && (kbShift || kbCaps)
        typealias Key = (id: String, label: String, u: CGFloat, char: Bool, fn: () -> Void)
        func ch(_ c: Character) -> Key {
            let s = upper ? String(c).uppercased() : String(c)
            return ("kb:" + String(c), s, 1, true, { [unowned self] in insert(s, target) })
        }
        let shift: Key = letters ? ("kbshift", kbCaps ? "⇪" : "⇧", 1.5, false, { [unowned self] in
            let t = CACurrentMediaTime()
            if kbCaps { kbCaps = false; kbShift = false } else if kbShift && t - lastShift < 0.4 { kbCaps = true; sounds.play("lock") } else { kbShift.toggle() }
            lastShift = t
        }) : ch(".")
        let del: Key = ("kbdel", "⌫", 1.5, false, { [unowned self] in deleteBack(target) })
        let doneLabel = ["desktop": "Return", "name": "Next", "search": "Search"][target] ?? "Done"
        let layer: Key = ("kblayer", letters ? "123" : "ABC", 1.5, false, { [unowned self] in kbLayer = 1 - kbLayer })
        let space: Key = ("kbspace", "space", 6, false, { [unowned self] in insert(" ", target) })
        let done: Key = ("kbdone", doneLabel, 2.5, false, { [unowned self] in
            switch target {
            case "search": if view == "commands" { commandKeyboard = false } else { view = "library" }
            case "settings": settingsSearch = false
            case "name": if !nameDraft.trimmingCharacters(in: .whitespaces).isEmpty { Dashboard.userName = nameDraft.trimmingCharacters(in: .whitespaces); step += 1 }
            default: keyCode(36); typed = ""
            }
        })
        var row3 = [shift] + (letters ? "zxcvbnm" : ",?!'%+=").map(ch) + [del], row4 = [layer, space, done]
        if leftHanded { row3 = [del] + row3.dropFirst().dropLast() + [shift]; row4.reverse() }
        let rows: [[Key]] = [(letters ? "qwertyuiop" : "1234567890").map(ch), (letters ? "asdfghjkl" : "-/:;()&@\"").map(ch), row3, row4]
        for (ri, row) in rows.enumerated() {
            let units = row.reduce(0) { $0 + $1.u }, w = units * kw + (units - 1) * gap
            var kx = r.midX - w / 2
            let ky = r.minY + top + gap + CGFloat(ri) * (kh + gap)
            for key in row {
                let k = CGRect(x: kx, y: ky, width: key.u * kw + (key.u - 1) * gap, height: kh)
                kx = k.maxX + gap
                let sel = key.id == "kbshift" && (kbShift || kbCaps), primary = key.id == "kbdone"
                let h = btn(key.id, k.insetBy(dx: -gap / 2, dy: -gap / 2)) { [unowned self] in
                    key.fn()
                    if key.char { keyPop = (key.label, k, CACurrentMediaTime()) }
                    sounds.play(["kbspace": "keyspace", "kbdel": "keydel", "kbdone": "keyret"][key.id] ?? "key"); redraw()
                }
                face(k, 16, on: h, base: sel || primary ? 0x2d8cffff : key.char ? 0x3a4452ff : 0x2f3742ff, hot: sel || primary ? 0x4a9dffff : 0x56606eff)
                txt(key.label, k.midX, k.midY + 11, key.label.count > 3 ? 28 : 32, bold: true, align: 0.5)
                if key.id == "kbshift" && kbCaps { rr(CGRect(x: k.midX - 14, y: k.maxY - 14, width: 28, height: 4), 2, 0xffffffff) }
                if key.char, touchPending?.0.id == key.id { keyPop = (key.label, k, CACurrentMediaTime()) }   // finger resting on it
            }
        }
        // the pressed key pops up above itself, bigger, then fades
        if let kp = keyPop {
            let age = now - kp.at, a = CGFloat(max(0, min(1, (0.32 - age) / 0.12)))
            if a > 0 {
                keepAnimating()
                let b = CGRect(x: kp.r.midX - kp.r.width * 0.62, y: kp.r.minY - kp.r.height * 1.05, width: kp.r.width * 1.24, height: kp.r.height * 1.05 + 10)
                ctx.saveGState(); ctx.setAlpha(a)
                ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: CGColor(gray: 0, alpha: 0.5))
                rr(b, 18, 0x5d6a75ff); ctx.restoreGState()
                ctx.saveGState(); ctx.setAlpha(a); txt(kp.label, b.midX, b.midY + 16, 48, bold: true, align: 0.5); ctx.restoreGState()
            } else { keyPop = nil }
        }
    }

    func testTourStep(_ n: Int) { view = "welcome"; step = n; redraw() }
    var context: CGContext { mainCtx }
    // test support (headless interaction verification)
    var testQuery: String { query }
    var testSettingsQuery: String { settingsQuery }
    var testPowerOpen: Bool { powerOpen }
    var testFilter: Int { get { filter } set { filter = newValue } }
    func testRegionCount() -> Int { regions.count }
    var testQuiet: Bool { quiet }
    var testNoticeCount: Int { notices.count }
    var testToastVisible: Bool { Date() < toastUntil }
    func testDockGeometry() -> Bool {
        let controls = regions.filter { $0.id.hasPrefix("dock:") }
        for (i, control) in controls.enumerated() {
            if !dockRect.contains(control.r) { return false }
            for other in controls.dropFirst(i + 1) where control.r.intersects(other.r) { return false }
        }
        return true
    }
    func testHasRegion(_ id: String) -> Bool { regions.contains { $0.id == id } }
    func testRegion(_ id: String) -> CGRect? { regions.last { $0.id == id }?.r }
    func testScroll(_ key: String) -> Flick? { flicks[key] }
    /// uv of the centre of a region, for clicking it in tests.
    func testUV(_ id: String, fx: CGFloat = 0.5, slot: Int = 1) -> CGPoint? {
        let list = slot == 1 ? regions : sideRegions[slot == 0 ? 0 : 1]
        return list.last { $0.id == id }.map { CGPoint(x: ($0.r.minX + $0.r.width * fx) / CGFloat(Dashboard.W), y: $0.r.midY / CGFloat(slot == 1 ? Dashboard.H : Dashboard.SPLIT)) }
    }

    /// The side windows, each into its own canvas with its own hit regions.
    private func drawSides() {
        let saved = (view, windowOpen, regions)
        for i in 0..<2 {
            guard let v = sideViews[i] else { continue }
            ctx = sideCtx(i); regions = []; drawingSlot = i == 0 ? 0 : 2; view = v
            ctx.clear(CGRect(x: 0, y: 0, width: Dashboard.W, height: Dashboard.SPLIT))
            chrome()
            drawView()
            sideRegions[i] = regions; sideViews[i] = view
        }
        ctx = mainCtx; drawingSlot = 1; view = saved.0; windowOpen = saved.1; regions = saved.2
    }
    private func drawView() {
        switch view {
        case "overview": drawOverview()
        case "commands": drawCommands()
        case "home": drawHome()
        case "spaces": drawSpaces()
        case "playing": drawPlaying()
        case "desktop": drawDesktop()
        case "quick": if quest { drawQuickQuest() } else { drawQuick() }
        case "settings": drawSettings()
        case "notifications": drawNotifications()
        case "appsettings": drawAppSettings()
        case "welcome": drawWelcome()
        default: drawLibrary()
        }
    }
    func draw() {
        defer { solidLock.lock(); solidState = (windowOpen, keyboardOpen, dockRect, solidExtra); sideOpen = sideViews.map { $0 != nil }; solidLock.unlock() }
        defer { if quest { drawSides() } else { sideViews = [nil, nil] } }
        regions = []; solidExtra = []
        now = CACurrentMediaTime(); dt = now - lastDraw > 0.1 ? 1.0 / 60 : CGFloat(now - lastDraw); lastDraw = now
        quest = settings["menu_style"] != "SteamVR"
        contrast = settings.bool("high_contrast"); reduceMotion = settings.bool("reduce_motion"); leftHanded = settings.bool("left_handed")
        textScale = ["Large": 1.1, "Largest": 1.2][settings["text_size"]] ?? 1
        MenuFallback.questActive = quest ? 1 : 0
        if view == "welcome" { windowOpen = true }   // the tour window can never be closed (no softlock)
        ctx.clear(CGRect(x: 0, y: 0, width: Dashboard.W, height: Dashboard.H))
        if view == "desktop" && !settings.bool("show_desktop_tabs") || view == "playing" && !gameActive { view = "library" }
        // physics: coasting lists, then a long-press on a game opens its menu
        for k in Array(flicks.keys) {
            if reduceMotion && !(flicks[k]!.held) { let p = flicks[k]!.pos; flicks[k]!.set(p) }
            if flicks[k]!.step(dt) { keepAnimating() }
        }
        if let (r, _) = touchPending, r.id.hasPrefix("tile:"), touchScroll?.active != true {
            if now - touchSince > 0.6 { menuFor = String(r.id.dropFirst(5)); touchPending = nil; sounds.play("open") } else { keepAnimating() }
        }
        if windowOpen {
            chrome()
            transition { drawView() }
            if powerOpen && view != "welcome" { drawPower() } else { eased["1/power"] = nil }
        }
        if windowOpen && !quest && !games.status.isEmpty { txt(games.status, Dashboard.WIN.minX + 40, Dashboard.WIN.minY + 60, 26, 0x9aa3afff, maxW: 700) }
        if view != "welcome" { if quest { questDock() } else { dock() } }   // no Universal Menu during the first-run tour
        if keyboardOpen {
            keyboardPanel(target: view == "desktop" || macKeyboard ? "desktop" : view == "welcome" ? "name" : view == "settings" ? "settings" : "search")
            grabBar("grabkb", Dashboard.KBGRAB)
        }
        drawToast()
        // brightness: dims only what was painted (transparent gaps stay transparent)
        let dim = Float(100 - sounds.brightness) / 100 * 0.6
        if dim > 0.01 {
            ctx.saveGState(); ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: CGFloat(dim)))
            ctx.fill(CGRect(x: 0, y: 0, width: Dashboard.W, height: Dashboard.H))
            ctx.restoreGState()
        }
    }
}

/// Fallback to the SteamVR menu: if MacVR crashes while the Quest menu is in use, the crash handler drops a marker and
/// the next launch switches Menu Style to SteamVR (the older, proven menu) and says so. Switch back in Settings.
enum MenuFallback {
    nonisolated(unsafe) static var questActive: sig_atomic_t = 0   // set by Dashboard.draw
    nonisolated(unsafe) private static var marker: UnsafeMutablePointer<CChar>?
    static let url = appSupport.appendingPathComponent("crashed-in-quest-menu")
    /// Call once at launch. Returns true if the last run crashed in the Quest menu (and switches the style).
    @discardableResult static func install(_ settings: Settings) -> Bool {
        marker = strdup(url.path)
        for sig in [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT, SIGFPE] {
            signal(sig) { s in   // async-signal-safe only: open/close, then die the normal way
                if MenuFallback.questActive != 0, let m = MenuFallback.marker { close(open(m, O_CREAT | O_WRONLY, 0o644)) }
                signal(s, SIG_DFL); raise(s)
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        settings.set("menu_style", "SteamVR")
        return true
    }
}
