import Foundation
import CoreGraphics
import CoreText
import AppKit
import ImageIO

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

    var view = "library" { didSet { windowOpen = true } }   // opening any view (dock, tiles) brings the window back
    /// The window's close dot hides just the window; the Universal Menu stays.
    var windowOpen = true
    var hover: String?
    var fps = 0
    var gameActive = false
    var gameName = ""
    var desktopStreaming = false
    var desktopAspect: CGFloat = 16.0 / 10
    var desktopTrusted = false
    var macVolume = -1                    // -1 = unknown until the Engine reads it
    var linkStatus = "USB"
    var headset: HeadsetModel = .quest2
    var streamInfo = ""                   // e.g. "2432x1344 @ 72 Hz"
    var version = "MacVR OS"
    /// The pop-up keyboard panel is showing (search, or typing into the Mac desktop).
    var keyboardOpen: Bool { view == "keyboard" || (view == "desktop" && desktopKeyboard) || (view == "welcome" && step == 1) }
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
        return ["home", "hand", "style"].contains(t.kind) ? nil : t.part
    }
    /// Close dot beside a grab bar (grows into an X on hover).
    static func dotRect(_ g: CGRect) -> CGRect { CGRect(x: g.midX + 120, y: g.midY - 30, width: 60, height: 60) }   // just past the pill's end
    /// Engine keeps redrawing (~60 Hz) while this is in the future, so the dot's grow animation plays.
    var animatingUntil: CFTimeInterval = 0
    private var dotSince: [String: CFTimeInterval] = [:]
    /// Called by the Engine when the menu button is pressed on the tour's last step.
    func finishTutorial() { Dashboard.tutorialDone = true; view = gameActive ? "playing" : "library"; sounds.play("launch") }

    // callbacks (Engine)
    var launch: (Game) -> Void = { _ in }
    var install: (Game) -> Void = { _ in }
    var uninstall: (Game) -> Void = { _ in }
    var openSteam: () -> Void = {}
    /// Theater mode: the Mac screen (where a flatscreen game runs) on a big curved screen in a dark room.
    var theater: (Bool) -> Void = { _ in }
    var theaterOn = false
    var power: () -> Void = {}
    var recenter: () -> Void = {}
    var close: () -> Void = {}
    var redraw: () -> Void = {}
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
    private var toast = "", toastUntil = Date.distantPast
    private var notices: [(Date, String)] = [], unread = 0
    private let settings: Settings, games: Games
    private let ctx: CGContext
    private let sounds = UISounds.shared
    private var query = "", kbShift = false, desktopKeyboard = false
    private var libScroll: CGFloat = 0, setScroll: CGFloat = 0, libMax: CGFloat = 0, setMax: CGFloat = 0, scrollTick: CGFloat = 0
    private var filter = 0                // library: 0 all, 1 installed, 2 VR
    private var menuFor: String?          // library tile whose "..." menu is open
    private var section = "general"       // settings sidebar
    private var step = 0                  // welcome tutorial page
    private var lastDesktopUV: CGPoint?
    var grabbing: String?                 // grab bar held (Engine sets/clears), keeps it highlighted
    private var pressed: (String, CFTimeInterval)?, inPress = false, navved = false
    private let solidLock = NSLock()
    private var solidState = (true, false, Dashboard.DOCK)   // (windowOpen, keyboardOpen, dock) as of the last draw
    /// Menu style (Settings > Universal Menu): "Quest" = compact OS dock + windows with a bottom title bar;
    /// otherwise the SteamVR-like wide bar with the title on top. Read once per draw.
    private var quest = true
    private var dockRect = Dashboard.DOCK
    /// Window area below the title (Quest: the title bar is at the bottom, so content starts higher).
    private var content: CGRect { quest ? CGRect(x: 164, y: 64, width: 1720, height: 764) : Dashboard.content }
    /// The control was just clicked: shows a brief depressed state (a fraction of a second).
    private func isPressed(_ id: String) -> Bool { touchPending?.0.id == id || (pressed.map { $0.0 == id && CACurrentMediaTime() - $0.1 < 0.12 } ?? false) }

    init(settings: Settings, games: Games) {
        self.settings = settings; self.games = games
        ctx = CGContext(data: nil, width: Dashboard.W, height: Dashboard.H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(Dashboard.H)); ctx.scaleBy(x: 1, y: -1)
    }

    func say(_ s: String) { sounds.play("error"); note(s, 3.5) }
    /// Toast + notification history (the dock bell).
    func note(_ s: String, _ secs: Double = 2.5) {
        toast = s; toastUntil = Date().addingTimeInterval(secs)
        notices.insert((Date(), s), at: 0); notices = Array(notices.prefix(30)); unread += 1
        DispatchQueue.global().asyncAfter(deadline: .now() + secs + 0.1) { [weak self] in self?.redraw() }
    }

    /// Called when the menu opens: land on the running game, otherwise the library (the tutorial keeps its place).
    func opened() {
        capture = nil; menuFor = nil
        if view != "welcome" { view = gameActive ? "playing" : (view == "playing" || view == "keyboard" ? "library" : view) }
    }
    static var tutorialDone: Bool {
        get { UserDefaults.standard.bool(forKey: "oobe.done") } set { UserDefaults.standard.set(newValue, forKey: "oobe.done") }
    }
    /// First-run welcome tour (the Engine starts it on the first headset connection; Settings > About replays it).
    func startTutorial() { step = 0; nameDraft = Dashboard.userName; view = "welcome"; sounds.play("welcome"); redraw() }

    // MARK: input (uv from the SceneKit hit test, origin top-left)
    private func px(_ uv: CGPoint) -> CGPoint { CGPoint(x: uv.x * CGFloat(Dashboard.W), y: uv.y * CGFloat(Dashboard.H)) }
    private func region(_ uv: CGPoint) -> Region? { let p = px(uv); return regions.last { $0.r.contains(p) } }

    /// True where the menu is opaque (window, bars, dock, open keyboard); lasers pass through the transparent gaps.
    /// Called on the render queue (laser hit tests) while the menu draws on its own: reads a snapshot taken after each draw.
    func solid(_ uv: CGPoint) -> Bool {
        let p = px(uv)
        solidLock.lock(); let (windowOpen, keyboardOpen, dock) = solidState; solidLock.unlock()
        return windowOpen && (Dashboard.WIN.contains(p) || Dashboard.GRAB.contains(p) || Dashboard.dotRect(Dashboard.GRAB).contains(p))
            || dock.contains(p) || Dashboard.DOCKGRAB.contains(p) || Dashboard.dotRect(Dashboard.DOCKGRAB).contains(p)
            || (keyboardOpen && (Dashboard.KB.contains(p) || Dashboard.KBGRAB.contains(p) || Dashboard.dotRect(Dashboard.KBGRAB).contains(p)))
    }

    /// Hover update; returns true when the hovered element changed (for redraw + haptic tick).
    func pointer(_ uv: CGPoint?) -> Bool {
        let r = uv.flatMap { region($0) }
        if let uv, let r, r.id == "desktop", capture == nil, desktopTrusted { r.drag?(px(uv), 0); lastDesktopUV = uv }
        let id = r?.id
        defer { hover = id }
        if id != hover, id != nil, id != "desktop" { sounds.play("hover") }
        return id != hover
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
        if menuFor != nil && !r.id.hasPrefix("ctx:") && !r.id.hasPrefix("more:") { menuFor = nil }
        pressed = (r.id, CACurrentMediaTime()); animatingUntil = max(animatingUntil, CACurrentMediaTime() + 0.15)
        navved = false; inPress = true; r.fn?(); inPress = false
        sounds.play(navved ? "open" : "tap")   // at commit: a soft confirm when a window opens, else a tick
        return .handled
    }
    /// Direct touch: a fingertip landing on a control. Sliders and the Mac desktop act at once (and follow the finger);
    /// buttons and keys only light up and fire when the finger lifts (touchUp), like Horizon OS.
    private var touchPending: (Region, CGPoint)?
    func touchDown(_ uv: CGPoint) {
        guard let r = region(uv), !r.id.hasPrefix("grab") else { return }
        if let d = r.drag { capture = r; d(px(uv), 1); return }
        touchPending = (r, px(uv)); sounds.play("hover")
    }
    /// Finger lifted: fires the touched button if the finger is still on it (a few px of slide while lifting is fine).
    func touchUp(_ uv: CGPoint?) {
        if capture != nil { release(uv); return }
        guard let (r, at) = touchPending else { return }
        touchPending = nil
        let p = uv.map(px) ?? at
        guard r.r.insetBy(dx: -18, dy: -18).contains(p) || hypot(p.x - at.x, p.y - at.y) < 30 else { return }
        if menuFor != nil && !r.id.hasPrefix("ctx:") && !r.id.hasPrefix("more:") { menuFor = nil }
        pressed = (r.id, CACurrentMediaTime()); animatingUntil = max(animatingUntil, CACurrentMediaTime() + 0.15)
        navved = false; inPress = true; r.fn?(); inPress = false
        sounds.play(navved ? "open" : "tap")
    }
    func drag(_ uv: CGPoint) { capture?.drag?(px(uv), 2) }
    func release(_ uv: CGPoint?) {
        if let c = capture { c.drag?(uv.map(px) ?? CGPoint(x: -1e4, y: -1e4), 3) }   // no uv: release in place, off-panel
        capture = nil
    }
    /// One-shot click (tests): press + release.
    func click(_ uv: CGPoint) { if press(uv) == .handled { release(uv) } }
    /// Grip: right click on the desktop; opens the "..." menu on a library tile.
    func secondary(_ uv: CGPoint) {
        guard let r = region(uv) else { return }
        if r.id == "desktop", let n = desktopNormalized(px(uv)) { desktopRightClick(n); sounds.play("tap") }
        if r.id.hasPrefix("tile:") { menuFor = String(r.id.dropFirst(5)); sounds.play("open") }
    }
    /// Thumbstick Y on the hovered view: scrolls lists, or scrolls the Mac. Returns true if something changed.
    func scroll(_ dy: Float, at uv: CGPoint) -> Bool {
        let r = region(uv)
        if r?.id == "desktop" { desktopScroll(Int32((dy * 18).rounded())); return false }
        // anywhere over the window scrolls it (not only over a tile: gaps between tiles used to stop the scroll dead)
        guard Dashboard.WIN.contains(px(uv)) else { return false }
        func move(_ v: inout CGFloat, _ m: CGFloat) -> Bool {
            let o = v; v = min(m, max(0, v - CGFloat(dy) * 28))
            if abs(v - scrollTick) > 120 { scrollTick = v; sounds.play("tick") }   // detent ticks while scrolling
            return o != v
        }
        switch view {
        case "library", "keyboard": return move(&libScroll, libMax)
        case "settings": return move(&setScroll, setMax)
        default: return false
        }
    }

    func nav(_ id: String) {
        menuFor = nil
        switch id {
        case "power": power()
        default: if view != id { view = id; if inPress { navved = true } else { sounds.play("pop") } }
        }
        if id == "notifications" { unread = 0 }
        redraw()
    }

    // MARK: drawing helpers
    @discardableResult
    private func btn(_ id: String, _ r: CGRect, _ fn: @escaping () -> Void) -> Bool {
        regions.append(Region(id: id, r: r, fn: fn, drag: nil)); return hover == id
    }
    private func dragRegion(_ id: String, _ r: CGRect, _ d: @escaping (CGPoint, Int) -> Void) -> Bool {
        regions.append(Region(id: id, r: r, fn: nil, drag: d)); return hover == id || capture?.id == id
    }
    private func path(_ r: CGRect, _ rad: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: min(rad, r.width / 2), cornerHeight: min(rad, r.height / 2), transform: nil)
    }
    private func rr(_ r: CGRect, _ rad: CGFloat, _ c: UInt32) { ctx.setFillColor(col(c)); ctx.addPath(path(r, rad)); ctx.fillPath() }
    private func outline(_ r: CGRect, _ rad: CGFloat, _ c: UInt32, _ w: CGFloat = 3) {
        ctx.setStrokeColor(col(c)); ctx.setLineWidth(w); ctx.addPath(path(r, rad)); ctx.strokePath()
    }
    /// Flat tile fill for app icons and system tiles (the brighter palette colour, no gradient).
    private func grad(_ r: CGRect, _ rad: CGFloat, _ top: UInt32, _ bottom: UInt32) { rr(r, rad, top) }
    /// Quest style: the same layouts in neutral greys with Meta's blue (SteamVR style keeps its blue-grey slate).
    private static let questPalette: [UInt32: UInt32] = [   // Horizon OS slate (sampled from the headset's own UI)
        0x1f252dff: 0x243039ff, 0x353d49ff: 0x46525dff, 0x4f5a69ff: 0x56636fff, 0x2a313aff: 0x3a4550ff, 0x2c343fff: 0x34404aff,
        0x303945ff: 0x34404aff, 0x3c4654ff: 0x3d4a55ff, 0x3a4452ff: 0x46525dff, 0x56606eff: 0x56636fff, 0x46505eff: 0x515e69ff,
        0x4a5462ff: 0x4f5c67ff, 0x5a6472ff: 0x5d6a75ff, 0x222932ff: 0x1d2830ff, 0x323b47ff: 0x34404aff, 0x3c4755ff: 0x3d4a55ff,
        0x1b2129ff: 0x1f2b33ff, 0x2f3742ff: 0x34404aff, 0x0d1117ff: 0x1a242bff, 0x15181df2: 0x1c272ef2,
        0x2d8cffff: 0x2a73f5ff, 0x4a9dffff: 0x4a88f7ff, 0x9aa3afff: 0xa4adb4ff, 0xc9cfd8ff: 0xd2d8dcff, 0xd8dde4ff: 0xe0e5e8ff,
    ]
    private func col(_ c: UInt32) -> CGColor {   // 0xRRGGBBAA
        let c = quest ? Dashboard.questPalette[c] ?? c : c
        return CGColor(srgbRed: CGFloat(c >> 24 & 255) / 255, green: CGFloat(c >> 16 & 255) / 255, blue: CGFloat(c >> 8 & 255) / 255, alpha: CGFloat(c & 255) / 255)
    }
    /// Button background; hover is a lighter flat fill.
    private func face(_ r: CGRect, _ rad: CGFloat, on: Bool, base: UInt32 = 0x353d49ff, hot: UInt32 = 0x4f5a69ff) {
        rr(r, rad, on && (touchPending != nil || pressed.map({ CACurrentMediaTime() - $0.1 < 0.12 }) == true) ? 0x2a313aff : on ? hot : base)
    }
    private func txt(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: UInt32 = 0xffffffff, bold: Bool = false,
                     align: CGFloat = 0, maxW: CGFloat = 5000) {
        var font = NSFont.systemFont(ofSize: max(size, 26), weight: bold ? .semibold : .medium)   // VR legibility floor; Quest text is medium, not bold
        if quest, let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: font.pointSize) ?? font }   // Horizon OS's rounded type
        func line(_ s: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: col(c))!]))
        }
        var str = s, l = line(s)
        while CTLineGetTypographicBounds(l, nil, nil, nil) > maxW, str.count > 1 { str = String(str.dropLast(2)) + "…"; l = line(str) }
        let w = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x - w * align, y: y)
        CTLineDraw(l, ctx)
        ctx.restoreGState()
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
        ctx.saveGState(); ctx.translateBy(x: cx, y: cy); ctx.scaleBy(x: s, y: s)
        ctx.setStrokeColor(col(c)); ctx.setFillColor(col(c)); ctx.setLineWidth(3.2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        func L(_ p: CGFloat...) { ctx.move(to: CGPoint(x: p[0], y: p[1])); stride(from: 2, to: p.count, by: 2).forEach { ctx.addLine(to: CGPoint(x: p[$0], y: p[$0 + 1])) }; ctx.strokePath() }
        func C(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ a0: CGFloat = 0, _ a1: CGFloat = 2 * .pi) { ctx.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: a0, endAngle: a1, clockwise: false); ctx.strokePath() }
        func D(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) { ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
        switch n {
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
        default: break
        }
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
        let k = CGRect(x: r.minX + CGFloat(value) * (r.width - 44), y: r.midY - 22, width: 44, height: 44)
        rr(k.insetBy(dx: on ? -4 : 0, dy: on ? -4 : 0), 26, 0xffffffff)
    }
    private func toggle(_ r: CGRect, _ on: Bool) {
        rr(r, r.height / 2, on ? 0x2d8cffff : 0x5a6472ff)
        let d = r.height - 10
        rr(CGRect(x: on ? r.maxX - d - 5 : r.minX + 5, y: r.minY + 5, width: d, height: d), d / 2, 0xffffffff)
    }
    /// Segmented control (one row of options).
    private func segmented(_ id: String, _ r: CGRect, _ opts: [String], _ sel: Int, _ pick: @escaping (Int) -> Void) {
        rr(r, 18, 0x222932ff)
        let w = r.width / CGFloat(opts.count)
        for (i, o) in opts.enumerated() {
            let c = CGRect(x: r.minX + CGFloat(i) * w + 5, y: r.minY + 5, width: w - 10, height: r.height - 10)
            let h = btn("\(id):\(i)", c) { [unowned self] in pick(i); sounds.play("on"); redraw() }
            if i == sel { rr(c, 14, 0x2d8cffff) } else if h { face(c, 14, on: true) }
            txt(o, c.midX, c.midY + 10, 26, i == sel ? 0xffffffff : 0xc9cfd8ff, bold: i == sel, align: 0.5, maxW: c.width - 12)
        }
    }
    private func clipped(_ r: CGRect, _ body: () -> Void) { ctx.saveGState(); ctx.clip(to: r); body(); ctx.restoreGState() }
    private func status(_ extra: [String]) -> String { ([headset.label, linkStatus, streamInfo] + extra).filter { !$0.isEmpty }.joined(separator: "  ·  ") }
    private func scrollbar(_ area: CGRect, _ off: CGFloat, _ maxOff: CGFloat) {   // thumbstick scrolls
        guard maxOff > 0 else { return }
        let track = CGRect(x: area.maxX + 12, y: area.minY, width: 8, height: area.height)
        rr(track, 4, 0xffffff22)
        let hgt = max(60, track.height * track.height / (track.height + maxOff))
        rr(CGRect(x: track.minX, y: track.minY + (track.height - hgt) * off / maxOff, width: 8, height: hgt), 4, 0xffffffaa)
    }

    // MARK: app icons (flat colour tiles)
    private static let apps: [String: (icon: String, label: String, top: UInt32, bottom: UInt32)] = [
        "playing": ("play", "Now Playing", 0x3aa0ffff, 0x1467e0ff),
        "desktop": ("monitor", "Mac Desktop", 0xb07cffff, 0x7040e0ff),
        "quick": ("sliders", "Quick Settings", 0xffb23dff, 0xf07b12ff),
        "settings": ("gear", "Settings", 0x4fd18bff, 0x1f9d5cff),
        "steam": ("steam", "Steam", 0x1b2838ff, 0x0e141cff),
        "tips": ("tips", "Tips", 0x3ad1c6ff, 0x1a9a9aff),
        "theater": ("theater", "Theater", 0x4a4f63ff, 0x1c1e2aff),
        "appsettings": ("gear", "Game Settings", 0x4fd18bff, 0x1f9d5cff),
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
        let x = CGRect(x: bar.minX + 14, y: bar.minY + 8, width: 56, height: 56), m = CGRect(x: x.maxX + 8, y: x.minY, width: 56, height: 56)
        if btn("win:close", x, { [unowned self] in windowOpen = false; sounds.play("close"); redraw() }) || isPressed("win:close") { rr(x, 16, 0xffffff1c) }
        icon("x", x.midX, x.midY, 0xffffffff, 0.8)
        if btn("win:min", m, { [unowned self] in windowOpen = false; sounds.play("back"); redraw() }) || isPressed("win:min") { rr(m, 16, 0xffffff1c) }
        rr(CGRect(x: m.midX - 13, y: m.midY - 2, width: 26, height: 4), 2, 0xffffffff)
        txt(title, bar.midX, bar.midY + 10, 27, 0xd2d8dcff, align: 0.5)
        if !games.status.isEmpty { txt(games.status, m.maxX + 24, bar.midY + 10, 26, 0xa4adb4ff, maxW: bar.width / 2 - 260) }
        if view == "desktop" { desktopKeyboardButton(CGRect(x: bar.maxX - 70, y: bar.minY + 8, width: 56, height: 56)) }
        grabBar("grab", Dashboard.GRAB)
    }
    /// Quest-style pill; brighter and wider while hovered or held. A small dot beside it grows into an X and closes
    /// what the bar carries (window/menu, or the keyboard).
    private func grabBar(_ id: String, _ g: CGRect) {
        let hot = hover == id || grabbing == id
        regions.append(Region(id: id, r: g, fn: nil, drag: nil))
        rr(CGRect(x: g.midX - (hot ? 120 : 95), y: g.midY - 8, width: hot ? 240 : 190, height: 16), 8, hot ? 0xffffffff : 0xffffffb0)
        if id == "grab" && view == "welcome" || quest && id != "grabkb" { return }   // Quest: the window's X is in its title bar
        let d = Dashboard.dotRect(g)
        let dotHot = btn("x:" + id, d) { [unowned self] in
            if id == "grabkb" {   // close the keyboard
                if view == "desktop" { desktopKeyboard = false } else if view == "keyboard" { view = "library" }
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
        var t = dotSince[id].map { min(1, (now - abs($0)) / dur) } ?? 1
        if t < 1 { animatingUntil = max(animatingUntil, now + 0.05) }
        if !dotHot { t = 1 - t }
        let back = 1 + 2.2 * pow(t - 1, 3) + 1.2 * pow(t - 1, 2)   // easeOutBack
        let rad = 9 + 17 * CGFloat(back)
        let a = UInt32(176 + 79 * min(1, max(0, t)))
        rr(CGRect(x: d.midX - rad, y: d.midY - rad, width: 2 * rad, height: 2 * rad), rad, 0xffffff00 | a)
        if t > 0.15 { icon("x", d.midX, d.midY, 0x1b212900 | UInt32(255 * min(1, (t - 0.15) / 0.6)), CGFloat(0.4 + 0.35 * back)) }
    }

    // MARK: the Universal Menu (dock)
    private var recents: [String] {   // most recently launched first, pinned games first
        let pinned = UserDefaults.standard.stringArray(forKey: "dock.pinned") ?? []
        let recent = UserDefaults.standard.stringArray(forKey: "dock.recent") ?? []
        return Array((pinned + recent.filter { !pinned.contains($0) }).prefix(4))
    }
    private func pushRecent(_ id: String) {
        var r = UserDefaults.standard.stringArray(forKey: "dock.recent") ?? []
        r.removeAll { $0 == id }; r.insert(id, at: 0)
        UserDefaults.standard.set(Array(r.prefix(8)), forKey: "dock.recent")
    }
    private func isPinned(_ id: String) -> Bool { (UserDefaults.standard.stringArray(forKey: "dock.pinned") ?? []).contains(id) }
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
        if g.installed { pushRecent(g.appid); sounds.play("launch"); launch(g) }
        else if let p = g.progress { note("Downloading \(g.name): \(Int(p * 100))%") }
        else { sounds.play("on"); install(g) }
    }

    /// Quest Universal Menu (late v60-v76 style): a thin near-black bar. Left: avatar, clock and status (-> Quick
    /// Settings), notifications. Right: white system glyphs, colourful app icons, recent games, App Library grid.
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
        if btn("dock:notifications", bell, { [unowned self] in nav("notifications") }) { tip = (bell, "Notifications") }
        plate("dock:notifications", bell, 22)
        icon("bell", bell.midX, bell.midY, 0xffffffff, 0.95)
        if unread > 0 { rr(CGRect(x: bell.maxX - 22, y: bell.minY + 12, width: 14, height: 14), 7, 0x2d8cffff) }
        indicator(bell.midX, view == "notifications")
        // system destinations | apps | recent games | App Library
        var items: [String] = gameActive ? ["playing"] : []
        items += settings.bool("show_desktop_tabs") ? ["desktop", "steam"] : ["steam"]
        if settings.bool("show_settings_tab") { items.append("settings") }
        let games = recents.compactMap { id in self.games.library.first { $0.appid == id } }
        let tile: CGFloat = 72, gap: CGFloat = 30
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
            }, { [unowned self] in
                if id == "steam" { openSteam(); nav("desktop"); note("Opening Steam on the Mac desktop") } else { nav(id) }
            }, active: view == id)
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
    /// Quest Universal Menu (Horizon OS): a slim slate pill under the window. Left: avatar, notifications and a status
    /// pill (link, time) that opens Quick Settings. Then small rounded app tiles and recent games, a divider and the
    /// App Library on a slate plate. The active app gets a short bar under its tile; hover shows the name above.
    private func questDock() {
        var items: [String] = gameActive ? ["playing"] : []
        items += settings.bool("show_desktop_tabs") ? ["desktop", "steam"] : ["steam"]
        if settings.bool("show_settings_tab") { items.append("settings") }
        let recent = recents.compactMap { id in self.games.library.first { $0.appid == id } }
        let tile: CGFloat = 66, gap: CGFloat = 16, statusW: CGFloat = 330
        let tiles = CGFloat(items.count + recent.count)
        let width = 18 + statusW + 70 + tiles * (tile + gap) + 22 + tile + 22
        let d = CGRect(x: Dashboard.DOCK.midX - width / 2, y: Dashboard.DOCK.midY - 46, width: width, height: 92)
        dockRect = d
        rr(d, 46, 0x1f2b33ff)
        var tip: (CGRect, String)?
        // avatar with presence dot
        let av = CGRect(x: d.minX + 22, y: d.midY - 22, width: 44, height: 44)
        rr(av, 22, 0xd9467aff)
        if let first = Dashboard.userName.first { txt(String(first).uppercased(), av.midX, av.midY + 9, 26, bold: true, align: 0.5) }
        else { icon("person", av.midX, av.midY, 0xffffffff, 0.6) }
        rr(CGRect(x: av.maxX - 13, y: av.maxY - 13, width: 15, height: 15), 7.5, 0x1f2b33ff)
        rr(CGRect(x: av.maxX - 11, y: av.maxY - 11, width: 11, height: 11), 5.5, 0x45d36bff)   // headset connected
        // notifications
        let bell = CGRect(x: av.maxX + 12, y: d.midY - 26, width: 52, height: 52)
        if btn("dock:notifications", bell, { [unowned self] in nav("notifications") }) { tip = (bell, "Notifications"); rr(bell, 26, 0xffffff1c) }
        icon("bell", bell.midX, bell.midY, 0xe0e5e8ff, 0.6)
        if unread > 0 { rr(CGRect(x: bell.maxX - 16, y: bell.minY + 8, width: 11, height: 11), 5.5, 0x2a73f5ff) }
        // status pill: link, fps, time -> Quick Settings
        let tf = DateFormatter(); tf.dateFormat = "h:mm"
        let time = tf.string(from: Date()), fpsText = settings.bool("show_fps") ? "\(fps)" : ""
        let pw = 130 + CGFloat(time.count + fpsText.count) * 15
        let st = CGRect(x: bell.maxX + 12, y: d.midY - 26, width: pw, height: 52)
        if btn("dock:quick", st, { [unowned self] in nav("quick") }) { tip = (st, "Quick Settings") }
        rr(st, 26, isPressed("dock:quick") ? 0x46525dff : hover == "dock:quick" ? 0x3e4c55ff : 0x34434bff)
        icon(linkStatus == "USB" ? "usb" : "wifi", st.minX + 32, st.midY, 0xe0e5e8ff, 0.55)
        if !fpsText.isEmpty { txt(fpsText, st.minX + 58, st.midY + 9, 26, 0x5ee07aff) }
        txt(time, st.maxX - 22, st.midY + 9, 26, 0xe0e5e8ff, align: 1)
        if view == "quick" { rr(CGRect(x: st.midX - 12, y: d.maxY - 10, width: 24, height: 4), 2, 0xc8d0d6ff) }
        // app tiles
        var x = max(st.maxX + 40, d.minX + 18 + statusW + 70)
        func slot(_ id: String, _ label: String, _ draw: (CGRect) -> Void, _ fn: @escaping () -> Void, active: Bool) {
            let r = CGRect(x: x, y: d.midY - tile / 2 - 3, width: tile, height: tile)
            let h = btn("dock:" + id, r, fn)
            draw(r)
            if isPressed("dock:" + id) { rr(r, 18, 0x00000050) } else if h { outline(r.insetBy(dx: -4, dy: -4), 21, 0xffffffc0, 3) }
            if active { rr(CGRect(x: r.midX - 12, y: d.maxY - 10, width: 24, height: 4), 2, 0xc8d0d6ff) }
            if h { tip = (r, label) }
            x += tile + gap
        }
        for id in items {
            slot(id, Dashboard.apps[id]!.label, { [unowned self] r in
                if id == "playing", let gm = playingGame { gameIcon(gm, r) } else { appIcon(id, r, hot: false) }
            }, { [unowned self] in
                if id == "steam" { openSteam(); nav("desktop"); note("Opening Steam on the Mac desktop") } else { nav(id) }
            }, active: view == id)
        }
        for g in recent {
            slot("game:" + g.appid, g.name, { [unowned self] r in gameIcon(g, r) }, { [unowned self] in start(g) },
                 active: gameActive && self.games.playing(gameName) == g)
        }
        rr(CGRect(x: x + 2, y: d.minY + 24, width: 2, height: d.height - 48), 1, 0xffffff2a); x += 22
        slot("library", "App Library", { [unowned self] r in rr(r, 18, 0x46525dff); icon("apps", r.midX, r.midY, 0xffffffff, 0.85) },
             { [unowned self] in nav("library") }, active: view == "library" || view == "keyboard")
        if let (r, label) = tip {
            let w = CGFloat(label.count) * 15 + 44, tt = CGRect(x: min(max(r.midX - w / 2, 20), CGFloat(Dashboard.W) - w - 20), y: d.minY - 58, width: w, height: 46)
            rr(tt, 12, 0x1c272ef2); txt(label, tt.midX, tt.midY + 9, 26, align: 0.5)
        }
        grabBar("grabdock", Dashboard.DOCKGRAB)
    }
    /// A game's small square Steam icon (the Quest dock uses icon assets, not marketing art); cropped art until it loads.
    private func gameIcon(_ g: Game, _ r: CGRect) {
        if let ic = games.icon(g.appid) { cover(ic, r, "", rad: r.width * 0.22) }
        else { cover(games.image(g.appid, "library_600x900"), r, "", rad: r.width * 0.22) }
    }

    // MARK: App Library
    private func drawLibrary() {
        let c = content
        let s = CGRect(x: c.midX - 380, y: c.minY - 4, width: 760, height: 64)
        let searching = view == "keyboard"
        face(s, 32, on: btn("search", s) { [unowned self] in view = "keyboard"; sounds.play("open"); redraw() },
             base: searching ? 0x3c4654ff : 0x303945ff)
        if searching { outline(s.insetBy(dx: 1.5, dy: 1.5), 32, 0x2d8cffff, 3) }
        icon("search", s.minX + 40, s.midY, 0x9aa3afff, 1.0)
        txt(query.isEmpty ? "Search apps" : query + (searching ? "▏" : ""), s.minX + 76, s.midY + 10, 28, query.isEmpty ? 0x9aa3afff : 0xffffffff, maxW: 600)
        if !query.isEmpty {
            let x = CGRect(x: s.maxX - 62, y: s.minY + 6, width: 52, height: 52)
            face(x, 26, on: btn("clearq", x) { [unowned self] in query = ""; libScroll = 0; sounds.play("back"); redraw() }, base: 0x00000000)
            icon("x", x.midX, x.midY, 0xffffffff, 0.8)
        }
        segmented("filter", CGRect(x: c.minX, y: c.minY - 4, width: 420, height: 64), ["All", "Installed", "VR"], filter) { [unowned self] i in
            filter = i; libScroll = 0
        }
        let rf = CGRect(x: c.maxX - 64, y: c.minY - 4, width: 64, height: 64)
        face(rf, 32, on: btn("rescan", rf) { [unowned self] in games.scan(); note("Library refreshed") })
        icon("refresh", rf.midX, rf.midY, 0xffffffff, 1.0)

        let lib = games.library.filter { (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
            && (filter != 1 || $0.installed || $0.progress != nil) && (filter != 2 || $0.vr) }
        txt("\(lib.count) game\(lib.count == 1 ? "" : "s")", rf.minX - 20, c.minY + 40, 26, 0x9aa3afff, align: 1)
        // system tiles first (flat colour, like the Quest's Store/Camera/Browser), then the games' landscape art
        // built-in apps (always listed, searchable; hidden only under the VR filter)
        let system: [String] = filter == 2 ? [] : ["desktop", "steam", "theater", "settings", "quick", "notifications", "tips"]
            .filter { query.isEmpty || Dashboard.apps[$0]!.label.localizedCaseInsensitiveContains(query) }
        let area = CGRect(x: c.minX, y: c.minY + 84, width: c.width, height: c.height - 84)
        let cols = 4, gap: CGFloat = 36, pad: CGFloat = 18, tw = (area.width - 20 - 2 * pad - CGFloat(cols - 1) * gap) / CGFloat(cols), th = tw * 0.467, rowH = th + 74
        let total = system.count + lib.count
        libMax = max(0, CGFloat((total + cols - 1) / cols) * rowH - area.height)
        libScroll = min(libScroll, libMax)
        var menuTile: (CGRect, Game)?
        clipped(area.insetBy(dx: -4, dy: -4)) {
            for i in 0..<total {
                let r = CGRect(x: area.minX + pad + CGFloat(i % cols) * (tw + gap), y: area.minY + pad + CGFloat(i / cols) * rowH - libScroll, width: tw, height: th)
                guard r.maxY + 60 > area.minY, r.minY < area.maxY else { continue }
                let vis = r.intersection(area)
                if i < system.count {
                    let id = system[i], a = Dashboard.apps[id]!
                    let h = vis.height > 40 && btn("sys:" + id, vis) { [unowned self] in
                        switch id {
                        case "steam": openSteam(); nav("desktop"); note("Opening Steam on the Mac desktop")
                        case "tips": startTutorial()
                        case "theater": theater(!theaterOn); note(theaterOn ? "Theater mode" : "Theater off")
                        default: nav(id)
                        }
                    }
                    let big = r   // hover: thin rim, no enlarging (Quest: precise and calm); the name sits below
                    grad(big, 20, a.top, a.bottom)
                    if id == "steam", let logo = games.steamIcon {
                        cover(logo, CGRect(x: big.midX - 40, y: big.midY - 40, width: 80, height: 80), "", rad: 40)
                    } else { icon(a.icon, big.midX, big.midY, 0xffffffff, 1.6) }
                    if isPressed("sys:" + id) { rr(big, 20, 0x00000040) }
                    if h { outline(big.insetBy(dx: -4, dy: -4), 23, 0xffffffb0, 3) }
                    txt(a.label, r.midX, r.maxY + 44, 26, 0xdfe3e8ff, align: 0.5, maxW: tw)
                    continue
                }
                let g = lib[i - system.count]
                let h = vis.height > 40 && btn("tile:" + g.appid, vis) { [unowned self] in start(g) }
                let big = r
                cover(games.image(g.appid, "header"), big, g.name, rad: 18)
                if isPressed("tile:" + g.appid) { rr(big, 18, 0x00000040) }
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
                if isPinned(g.appid) { icon("pin", big.maxX - 30, big.maxY - 30, 0xffffffff, 0.9) }
                if h {
                    outline(big.insetBy(dx: -4, dy: -4), 21, 0xffffffb0, 3)
                    let more = CGRect(x: big.maxX - 64, y: big.minY + 10, width: 54, height: 42)
                    rr(more, 21, 0x000000c8); txt("•••", more.midX, more.midY + 9, 26, bold: true, align: 0.5)
                }
                // "..." hit area sits on top of the tile (registered after it) while hovered or open
                if h || menuFor == g.appid {
                    let more = CGRect(x: big.maxX - 64, y: big.minY + 10, width: 54, height: 42)
                    btn("more:" + g.appid, more) { [unowned self] in menuFor = menuFor == g.appid ? nil : g.appid; redraw() }
                }
                if menuFor == g.appid { menuTile = (r, g) }
                txt(g.name, r.midX, r.maxY + 44, 26, 0xdfe3e8ff, align: 0.5, maxW: tw)
            }
        }
        if lib.isEmpty && system.isEmpty { txt(query.isEmpty ? "No games here yet. Sign in to Steam, then refresh." : "No games match \"\(query)\"", area.midX, area.midY, 30, 0x9aa3afff, align: 0.5) }
        scrollbar(area, libScroll, libMax)
        if let (r, g) = menuTile { contextMenu(g, at: r) }
    }
    /// Quest-style tile menu: Play/Install, Pin to Universal Menu, Uninstall.
    private func contextMenu(_ g: Game, at r: CGRect) {
        var items: [(String, String, String, () -> Void)] = [
            ("ctx:play", g.installed ? "play" : "download", g.installed ? "Play" : (g.progress != nil ? "Downloading…" : "Install"), { [unowned self] in menuFor = nil; start(g) }),
            ("ctx:pin", "pin", isPinned(g.appid) ? "Unpin from Universal Menu" : "Pin to Universal Menu", { [unowned self] in
                togglePin(g.appid); menuFor = nil; note(isPinned(g.appid) ? "\(g.name) pinned" : "\(g.name) unpinned") }),
        ]
        if g.installed { items.append(("ctx:theater", "monitor", "Play in Theater", { [unowned self] in
            menuFor = nil; if !theaterOn { theater(true) }; pushRecent(g.appid); sounds.play("launch"); launch(g) })) }
        items.append(("ctx:settings", "gear", "Game Settings", { [unowned self] in menuFor = nil; settingsFor = g; nav("appsettings") }))
        if g.installed && g.appid.allSatisfy(\.isNumber) { items.append(("ctx:uninstall", "trash", "Uninstall", { [unowned self] in menuFor = nil; uninstall(g) })) }
        let w: CGFloat = 470, h = CGFloat(items.count) * 76 + 20
        var m = CGRect(x: r.maxX - w + 20, y: r.minY + 60, width: w, height: h)
        if m.maxY > Dashboard.WIN.maxY - 20 { m.origin.y = Dashboard.WIN.maxY - 20 - h }
        if m.minX < Dashboard.WIN.minX + 20 { m.origin.x = Dashboard.WIN.minX + 20 }
        rr(m, 22, 0x1b2129ff)
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
            ctx.saveGState(); ctx.setAlpha(0.4)
            cover(art, CGRect(x: c.minX, y: c.minY, width: c.width, height: c.height - 250), "", rad: 26)
            ctx.restoreGState()
        }
        txt(g?.name ?? (gameName.isEmpty ? "VR Game" : gameName), c.minX + 20, c.maxY - 250, 64, bold: true, maxW: c.width - 40)
        let round: [(String, String, String, () -> Void)] = [
            ("p:recenter", "recenter", "Recenter", { [unowned self] in recenter(); note("View recentered") }),
            ("p:desktop", "monitor", "Mac Desktop", { [unowned self] in nav("desktop") }),
            ("p:quick", "sliders", "Quick Settings", { [unowned self] in nav("quick") }),
            ("p:library", "apps", "App Library", { [unowned self] in nav("library") }),
        ]
        for (i, (id, ic, label, fn)) in round.enumerated() {
            let r = CGRect(x: c.minX + 20 + CGFloat(i) * 104, y: c.maxY - 210, width: 84, height: 84)
            let h = btn(id, r, fn)
            rr(r, 42, h ? 0x56606eff : 0x3a4452ff)
            icon(ic, r.midX, r.midY, 0xffffffff, 1.05)
            if h { txt(label, c.minX + 20 + CGFloat(round.count) * 104 + 10, r.midY + 10, 28, 0xc9cfd8ff) }
        }
        let resume = CGRect(x: c.minX + 20, y: c.maxY - 100, width: 360, height: 84)
        face(resume, 42, on: btn("resume", resume) { [unowned self] in sounds.play("menuClose"); close() }, base: 0x2d8cffff, hot: 0x4a9dffff)
        txt("Resume", resume.midX, resume.midY + 11, 32, bold: true, align: 0.5)
        let quit = CGRect(x: resume.maxX + 24, y: resume.minY, width: 360, height: 84)
        face(quit, 42, on: btn("quit", quit) { [unowned self] in power() }, base: 0x3a4452ff, hot: 0x56606eff)
        txt("Quit", quit.midX, quit.midY + 11, 32, bold: true, align: 0.5)
        txt(status(["\(fps) fps"]), c.maxX - 20, c.maxY - 48, 26, 0x9aa3afff, align: 1, maxW: 800)
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
                if let n = desktopNormalized(p) { desktopPointer(n, phase) } else if phase == 3 { desktopPointer(CGPoint(x: -1, y: -1), 3) }
            }
        } else {
            let b = CGRect(x: r.midX - 520, y: r.maxY - 130, width: 1040, height: 100)
            face(b, 30, on: btn("trust", b) { [unowned self] in requestTrust(); note("Approve VR4Mac under Privacy & Security > Accessibility", 5) }, base: 0x2d8cffff, hot: 0x4a9dffff)
            txt("Allow control: enable VR4Mac in Accessibility", b.midX, b.midY + 10, 30, bold: true, align: 0.5, maxW: b.width - 40)
        }
    }

    // MARK: Quick Settings (deliberately small: shortcuts, two sliders, status)
    private func drawQuick() {
        let c = content
        let envs = Settings.items["environment"]!.options
        var shortcuts: [(String, String, String, Bool, () -> Void)] = gameActive ? [
            ("q:resume", "play", "Resume", false, { [unowned self] in close() }),   // straight back into the game
        ] : []
        shortcuts += [
            ("q:recenter", "recenter", "Recenter", false, { [unowned self] in recenter(); note("View recentered") }),
            ("q:theater", "theater", "Theater", theaterOn, { [unowned self] in theater(!theaterOn) }),
            ("q:desktop", "monitor", "Mac Desktop", false, { [unowned self] in nav("desktop") }),
            ("q:env", "mountain", settings["environment"], false, { [unowned self] in
                let i = ((envs.firstIndex(of: settings["environment"]) ?? 0) + 1) % envs.count
                settings.set("environment", envs[i]); sounds.play("env") }),
        ]
        shortcuts.append(("q:mic", "mic", "Headset Mic", Mic.shared.useHeadset, { [unowned self] in   // one tap: talk in games through the headset
            Mic.shared.choice = Mic.shared.useHeadset ? "" : Mic.headset
            note(Mic.shared.useHeadset ? "Headset mic on" : "Headset mic off"); sounds.play(Mic.shared.useHeadset ? "on" : "off") }))
        if gameActive { shortcuts.append(("q:quit", "power", "Quit Game", false, { [unowned self] in power() })) }
        let d: CGFloat = 150, gap: CGFloat = shortcuts.count > 5 ? 60 : 90, total = CGFloat(shortcuts.count) * d + CGFloat(shortcuts.count - 1) * gap
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
        txt(status(fps > 0 ? ["\(fps) fps"] : []), c.minX + 10, c.maxY - 40, 28, 0x9aa3afff, maxW: c.width - 420)
        let all = CGRect(x: c.maxX - 340, y: c.maxY - 100, width: 320, height: 84)
        face(all, 42, on: btn("q:all", all) { [unowned self] in nav("settings") })
        icon("gear", all.minX + 52, all.midY, 0xffffffff, 1.0); txt("All Settings", all.minX + 92, all.midY + 11, 30, bold: true)
    }

    /// Quest Quick Settings (Horizon OS): status and date on top, thick pill sliders, big cards, then small toggle tiles.
    private func drawQuickQuest() {
        let c = content
        let df = DateFormatter(); df.dateFormat = "EEE, MMM d, yyyy"
        txt(status(fps > 0 ? ["\(fps) fps"] : []), c.minX, c.minY + 30, 26, 0xa4adb4ff, maxW: 560)
        txt(df.string(from: Date()), c.midX, c.minY + 30, 28, 0xe0e5e8ff, align: 0.5)
        let gear = CGRect(x: c.maxX - 230, y: c.minY - 6, width: 230, height: 60)
        face(gear, 30, on: btn("q:all", gear) { [unowned self] in nav("settings") }, base: 0x00000000, hot: 0x46525dff)
        icon("gear", gear.minX + 38, gear.midY, 0xffffffff, 0.95); txt("Settings", gear.minX + 72, gear.midY + 10, 28, bold: true)
        // pill sliders: blue fill, white knob carrying the icon
        func pill(_ id: String, _ r: CGRect, _ value: Float, _ ic: String, _ set: @escaping (Float) -> Void) {
            let hot = dragRegion(id, r.insetBy(dx: -6, dy: -10)) { [unowned self] p, phase in
                guard phase != 3 else { sounds.play("slider"); return }
                set(min(1, max(0, Float((p.x - r.minX - r.height / 2) / (r.width - r.height))))); redraw()
            }
            rr(r, r.height / 2, 0x34404aff)
            let kx = r.minX + CGFloat(value) * (r.width - r.height)
            rr(CGRect(x: r.minX, y: r.minY, width: kx - r.minX + r.height, height: r.height), r.height / 2, 0x2a73f5ff)
            let k = CGRect(x: kx + 5, y: r.minY + 5, width: r.height - 10, height: r.height - 10).insetBy(dx: hot ? -3 : 0, dy: hot ? -3 : 0)
            rr(k, k.height / 2, 0xffffffff)
            icon(ic, k.midX, k.midY, 0x1f2b33ff, 0.75)
        }
        let sw = (c.width - 30) / 2
        pill("q:vol", CGRect(x: c.minX, y: c.minY + 74, width: sw, height: 66), Float(sounds.streamVolume) / 100, "speaker") { [unowned self] v in sounds.streamVolume = Int(v * 100) }
        pill("q:bright", CGRect(x: c.minX + sw + 30, y: c.minY + 74, width: sw, height: 66), Float(sounds.brightness - 20) / 80, "sun") { [unowned self] v in sounds.brightness = 20 + Int(v * 80) }
        // big cards: icon top-left, title + subtitle bottom-left
        let envs = Settings.items["environment"]!.options
        let cards: [(String, String, String, String, () -> Void)] = [
            ("q:desktop", "monitor", "Mac Desktop", desktopStreaming ? "Streaming" : "See and use your Mac", { [unowned self] in nav("desktop") }),
            ("q:env", "mountain", "Environment", settings["environment"], { [unowned self] in
                let i = ((envs.firstIndex(of: settings["environment"]) ?? 0) + 1) % envs.count
                settings.set("environment", envs[i]); sounds.play("env") }),
        ]
        for (i, (id, ic, title, sub, fn)) in cards.enumerated() {
            let r = CGRect(x: c.minX + CGFloat(i) * (sw + 30), y: c.minY + 172, width: sw, height: 220)
            let h = btn(id, r) { fn(); self.redraw() }
            rr(r, 30, isPressed(id) ? 0x3a4550ff : h ? 0x56636fff : 0x46525dff)
            icon(ic, r.minX + 50, r.minY + 52, 0xffffffff, 1.1)
            txt(title, r.minX + 34, r.maxY - 72, 36, bold: true, maxW: r.width - 60)
            txt(sub, r.minX + 34, r.maxY - 32, 26, 0xc0c8ceff, maxW: r.width - 60)
        }
        // small tiles: icon over label; on = blue
        var tiles: [(String, String, String, Bool, () -> Void)] = gameActive ? [("q:resume", "play", "Resume", false, { [unowned self] in close() })] : []
        tiles += [
            ("q:recenter", "recenter", "Reset view", false, { [unowned self] in recenter(); note("View recentered") }),
            ("q:theater", "theater", "Theater", theaterOn, { [unowned self] in theater(!theaterOn) }),
            ("q:mic", "mic", "Headset Mic", Mic.shared.useHeadset, { [unowned self] in
                Mic.shared.choice = Mic.shared.useHeadset ? "" : Mic.headset
                note(Mic.shared.useHeadset ? "Headset mic on" : "Headset mic off"); sounds.play(Mic.shared.useHeadset ? "on" : "off") }),
            ("q:notes", "bell", "Notifications", false, { [unowned self] in nav("notifications") }),
        ]
        if gameActive { tiles.append(("q:quit", "power", "Quit Game", false, { [unowned self] in power() })) }
        let tw = (c.width - CGFloat(tiles.count - 1) * 24) / CGFloat(tiles.count), ty = c.minY + 420
        for (i, (id, ic, label, on, fn)) in tiles.enumerated() {
            let r = CGRect(x: c.minX + CGFloat(i) * (tw + 24), y: ty, width: tw, height: 170)
            let h = btn(id, r) { [unowned self] in fn(); redraw() }
            rr(r, 30, isPressed(id) ? 0x3a4550ff : on ? (h ? 0x4a88f7ff : 0x2a73f5ff) : h ? 0x56636fff : 0x46525dff)
            icon(ic, r.midX, r.minY + 62, 0xffffffff, 1.05)
            txt(label, r.midX, r.maxY - 34, 27, align: 0.5, maxW: r.width - 24)
        }
    }

    // MARK: Settings (sidebar like the Quest's System settings)
    private static let sections: [(id: String, icon: String, label: String)] = [
        ("general", "gear", "General"), ("video", "monitor", "Display & Video"), ("controllers", "controller", "Controllers"),
        ("audio", "speaker", "Audio"), ("environment", "mountain", "Environment"), ("menu", "apps", "Universal Menu"),
        ("developer", "code", "Developer"), ("about", "info", "About"),
    ]
    private static let sectionKeys: [String: [String]] = [
        "general": ["render_scale", "refresh_rate"], "video": ["bitrate", "codec", "show_fps"],
        "controllers": ["controller_model", "system_button"], "environment": ["floor_grid"],
        "menu": ["menu_style", "direct_touch", "dashboard_position", "ui_curved", "show_desktop_tabs", "show_settings_tab", "show_power"], "developer": ["show_fps"],
    ]
    private func drawSettings() {
        let w = Dashboard.WIN
        let side = CGRect(x: w.minX + 24, y: content.minY, width: 440, height: content.height - 4)
        for (i, s) in Dashboard.sections.enumerated() {
            let r = CGRect(x: side.minX, y: side.minY + CGFloat(i) * 86, width: side.width, height: 76)
            let sel = section == s.id
            let h = btn("sec:" + s.id, r) { [unowned self] in if section != s.id { section = s.id; setScroll = 0; sounds.play("tap") }; redraw() }
            if sel || h { rr(r, 20, sel ? (quest ? 0x2d8cffff : 0x3c4755ff) : 0x323b47ff) }
            icon(s.icon, r.minX + 44, r.midY, sel ? 0xffffffff : 0xc9cfd8ff, 1.05)
            txt(s.label, r.minX + 88, r.midY + 10, 29, sel ? 0xffffffff : 0xc9cfd8ff, bold: sel)
        }
        rr(CGRect(x: side.maxX + 22, y: side.minY, width: 2, height: side.height), 1, 0xffffff18)
        let c = CGRect(x: side.maxX + 60, y: side.minY, width: w.maxX - side.maxX - 100, height: side.height)
        txt(Dashboard.sections.first { $0.id == section }?.label ?? "", c.minX, c.minY + 34, 36, bold: true)
        let body = CGRect(x: c.minX, y: c.minY + 70, width: c.width, height: c.height - 70)
        var y = body.minY - setScroll
        clipped(body) {
            for key in Dashboard.sectionKeys[section] ?? [] {
                guard let it = Settings.items[key] else { continue }
                let r = CGRect(x: body.minX, y: y, width: body.width - 24, height: 84), v = settings[key]
                let vis = r.intersection(body)
                let h = vis.height > 30 && btn("set:" + key, vis) { [unowned self] in
                    settings.cycle(key); sounds.play(it.options == Settings.offOn ? (v == "On" ? "off" : "on") : "tap"); redraw()
                }
                face(r, 22, on: h, base: 0x2c343fff)
                txt(it.label, r.minX + 30, r.midY + 11, 30, maxW: r.width - 360)
                if it.options == Settings.offOn { toggle(CGRect(x: r.maxX - 130, y: r.midY - 24, width: 96, height: 48), v == "On") }
                else {
                    let p = CGRect(x: r.maxX - 290, y: r.midY - 28, width: 256, height: 56)
                    rr(p, 28, 0x46505eff); txt(v + "  ›", p.midX, p.midY + 10, 28, bold: true, align: 0.5)
                }
                y += 96
            }
            switch section {
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
                    y += 100
                }
                // Microphone: click cycles Mac inputs and the headset mic (games record from the chosen one)
                let mic = CGRect(x: body.minX, y: y, width: body.width - 24, height: 84)
                face(mic, 22, on: btn("s:mic", mic) { [unowned self] in
                    let o = Mic.shared.options(), i = o.firstIndex { $0.0 == Mic.shared.choice } ?? 0
                    Mic.shared.choice = o[(i + 1) % o.count].0; note("Microphone: " + Mic.shared.label); redraw()
                }, base: 0x2c343fff)
                icon("mic", mic.minX + 40, mic.midY, 0xffffffff, 0.9)
                txt("Microphone", mic.minX + 76, mic.midY + 11, 30)
                txt(Mic.shared.label + "  ›", mic.maxX - 30, mic.midY + 11, 28, 0xc9cfd8ff, align: 1, maxW: mic.width - 360)
                y += 100
                let mr = CGRect(x: body.minX, y: y, width: body.width - 24, height: 84)
                face(mr, 22, on: btn("s:mono", mr) { [unowned self] in sounds.mono.toggle(); sounds.play(sounds.mono ? "on" : "off"); redraw() }, base: 0x2c343fff)
                txt("Mono Audio", mr.minX + 30, mr.midY + 11, 30)
                toggle(CGRect(x: mr.maxX - 130, y: mr.midY - 24, width: 96, height: 48), sounds.mono)
                y += 100
            case "environment":
                let envs = Settings.items["environment"]!.options, tw = (body.width - 24 - 40) / 3, th = tw * 0.5
                for (i, e) in envs.enumerated() {
                    let r = CGRect(x: body.minX + CGFloat(i % 3) * (tw + 20), y: y + CGFloat(i / 3) * (th + 70), width: tw, height: th)
                    let sel = settings["environment"] == e
                    let h = btn("env:\(i)", r) { [unowned self] in settings.set("environment", e); sounds.play("env"); note("Home: \(e)") }
                    if let img = Dashboard.envThumb(e) { cover(img, r, e, rad: 18) } else { grad(r, 18, 0x3a2a6cff, 0x140c30ff) }
                    if sel || h { outline(r.insetBy(dx: -5, dy: -5), 22, sel ? 0x2d8cffff : 0xffffffcc, 5) }
                    txt(e, r.midX, r.maxY + 44, 28, sel ? 0xffffffff : 0xc9cfd8ff, bold: sel, align: 0.5)
                }
                y += CGFloat((envs.count + 2) / 3) * (th + 70)
            case "developer":
                txt("Runtime log: /tmp/vr4mac/runtime.log", body.minX + 10, y + 40, 26, 0x9aa3afff)
                txt("MacVR log: ~/Library/Application Support/VR4Mac/macvr.log", body.minX + 10, y + 80, 26, 0x9aa3afff); y += 110
            case "about":
                for (k, v) in [("Version", version), ("Headset", headset.label), ("Link", linkStatus), ("Stream", streamInfo.isEmpty ? "not connected" : streamInfo),
                               ("Games", "\(games.library.count) owned · \(games.library.filter(\.installed).count) installed")] {
                    txt(k, body.minX + 10, y + 44, 30, bold: true); txt(v, body.minX + 330, y + 44, 30, 0xc9cfd8ff, maxW: body.width - 360); y += 70
                }
                let t = CGRect(x: body.minX, y: y + 20, width: 460, height: 80)
                face(t, 40, on: btn("s:tutorial", t) { [unowned self] in startTutorial() }, base: 0x2d8cffff, hot: 0x4a9dffff)
                txt("Replay Welcome Tour", t.midX, t.midY + 10, 29, bold: true, align: 0.5); y += 120
                txt("Environments: Poly Haven (CC0) · Controller models: WebXR Input Profiles (MIT)", body.minX + 10, y + 30, 26, 0x9aa3afff, maxW: body.width); y += 60
            default: break
            }
        }
        setMax = max(0, y + setScroll - body.maxY)
        setScroll = min(setScroll, setMax)
        scrollbar(body, setScroll, setMax)
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

    // MARK: per-game settings (resolution / world scale / theater)
    private func drawAppSettings() {
        guard let g = settingsFor else { view = "library"; return }
        let c = content
        cover(games.image(g.appid, "header"), CGRect(x: c.minX, y: c.minY, width: 420, height: 196), g.name, rad: 18)
        txt(g.name, c.minX + 460, c.minY + 70, 44, bold: true, maxW: c.width - 480)
        txt(g.vr ? "VR game" : "Flatscreen game: try Theater", c.minX + 460, c.minY + 120, 28, 0x9aa3afff)
        txt("World scale updates live. Resolution needs a restart.", c.minX + 460, c.minY + 166, 24, 0x9aa3afff)
        var y = c.minY + 250
        let rows: [(String, String, [Int])] = [("render", "Render Resolution", [0, 50, 75, 100, 125, 150]), ("world", "World Scale", [0, 50, 75, 100, 125, 150, 200])]
        for (key, label, opts) in rows {
            txt(label, c.minX + 10, y + 46, 30, bold: true)
            let cur = Dashboard.override(g.appid, key)
            segmented("as:" + key, CGRect(x: c.minX + 380, y: y, width: c.width - 400, height: 72), opts.map { $0 == 0 ? "Default" : "\($0)%" },
                      opts.firstIndex(of: cur) ?? 0) { i in Dashboard.setOverride(g.appid, key, opts[i]) }
            y += 110
        }
        let t = CGRect(x: c.minX, y: y, width: c.width - 20, height: 84), on = Dashboard.override(g.appid, "theater") == 1
        face(t, 22, on: btn("as:theater", t) { [unowned self] in Dashboard.setOverride(g.appid, "theater", on ? 0 : 1); sounds.play(on ? "off" : "on"); redraw() }, base: 0x2c343fff)
        txt("Always open in Theater", t.minX + 30, t.midY + 11, 30)
        toggle(CGRect(x: t.maxX - 130, y: t.midY - 24, width: 96, height: 48), on)
        let b = CGRect(x: c.minX, y: c.maxY - 90, width: 300, height: 80)
        face(b, 40, on: btn("as:back", b) { [unowned self] in nav("library") })
        icon("back", b.minX + 50, b.midY, 0xffffffff, 1.0); txt("App Library", b.minX + 90, b.midY + 11, 30, bold: true)
    }

    // MARK: notifications
    private func drawNotifications() {
        let c = content
        if notices.isEmpty { txt("You're all caught up.", c.midX, c.midY, 32, 0x9aa3afff, align: 0.5); return }
        let tf = DateFormatter(); tf.timeStyle = .short
        for (i, (d, s)) in notices.prefix(8).enumerated() {
            let r = CGRect(x: c.minX, y: c.minY + CGFloat(i) * 94, width: c.width, height: 84)
            rr(r, 22, 0x2c343fff)
            icon("bell", r.minX + 44, r.midY, 0x9ac7ffff, 0.95)
            txt(s, r.minX + 90, r.midY + 11, 29, maxW: r.width - 300)
            txt(tf.string(from: d), r.maxX - 30, r.midY + 11, 26, 0x9aa3afff, align: 1)
        }
    }

    // MARK: first-run welcome tour (questions first, then the controls, then "press your menu button")
    private static let tour: [(kind: String, title: String, body: String, part: String)] = [
        ("intro", "Welcome to MacVR OS", "Play your Steam VR games from your Mac. A few quick questions, then a short tour.", "none"),
        ("name", "What's your name?", "Type it with the keyboard below. Pull the trigger to press keys.", "trigger"),
        ("hand", "Which hand do you point with?", "That controller drives the menus first. Either one works anytime.", "none"),
        ("home", "Pick your home", "This is where you'll land between games. Change it anytime in Settings.", "none"),
        ("style", "Pick your menu", "Quest: a compact dock with app tiles under each window. SteamVR: a wide bar with the title on top. Change it anytime in Settings.", "none"),
        ("info", "Point and select", "Aim at anything and pull the trigger to select it.", "trigger"),
        ("info", "Move windows", "Point at the bar under a window, hold the trigger and move. Push your hand forward to send it further away.", "trigger"),
        ("info", "Scroll", "Push the thumbstick up or down to scroll the library, settings and the Mac desktop.", "stick"),
        ("info", "More options", "Squeeze the grip on a game for options, or to right-click on the Mac desktop.", "grip"),
        ("menu", "Press your menu button", "The menu button is the small ≡ button on your left controller. Press it now to step into your home, and anytime to open MacVR OS.", "none"),
    ]
    private var nameDraft = ""
    var liveTourController = false   // Engine: the 3D tour controller is being shown
    private static let homes = ["Golden Bay", "Venice Sunset", "Forest", "Fireside"]
    private func drawWelcome() {
        let c = content, t = Dashboard.tour[min(step, Dashboard.tour.count - 1)]
        // left: the real controller with the input for this step tinted blue (or the answer UI for questions)
        let box = CGRect(x: c.minX + 30, y: c.minY + 20, width: 560, height: 560)
        if t.kind != "home" {
            // the live 3D controller floats here (Compositor.setTourController); the picture is only a fallback
            if !liveTourController, let img = ControllerPortrait.image(headset, part: t.part) {
                ctx.saveGState(); ctx.translateBy(x: box.minX, y: box.maxY); ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(origin: .zero, size: box.size)); ctx.restoreGState()
            }
            let label = ["trigger": "Trigger · index finger", "grip": "Grip · middle finger", "stick": "Thumbstick", "none": t.kind == "menu" ? "≡ Menu button · left controller" : ""][t.part] ?? ""
            if !label.isEmpty {
                let w = CGFloat(label.count) * 17 + 60, chip = CGRect(x: box.midX - w / 2, y: box.maxY - 10, width: w, height: 56)
                rr(chip, 28, 0x2d8cffff); txt(label, chip.midX, chip.midY + 10, 28, bold: true, align: 0.5)
            }
        }
        let tx = c.minX + 680, tw = c.maxX - tx - 20
        txt(t.title, tx, c.minY + 120, 54, bold: true, maxW: tw)
        var y = c.minY + 190
        var words = t.body.split(separator: " ").map(String.init), line = ""   // simple word wrap
        while !words.isEmpty {
            let w = words.removeFirst(), next = line.isEmpty ? w : line + " " + w
            if next.count > 44 { txt(line, tx, y, 32, 0xc9cfd8ff); y += 48; line = w } else { line = next }
        }
        if !line.isEmpty { txt(line, tx, y, 32, 0xc9cfd8ff) }
        y += 70
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
        case "home":   // big thumbnails on the left area too
            let gw = (c.width - 40 - 3 * 28) / 4, gh = gw * 0.56
            for (i, e) in Dashboard.homes.enumerated() {
                let r = CGRect(x: c.minX + 20 + CGFloat(i) * (gw + 28), y: c.minY + 330, width: gw, height: gh)
                let sel = settings["environment"] == e
                let h = btn("tour:home\(i)", r) { [unowned self] in settings.set("environment", e); sounds.play("env"); redraw() }
                if let img = Dashboard.envThumb(e) { cover(img, h ? r.insetBy(dx: -6, dy: -6) : r, e, rad: 20) } else { grad(r, 20, 0x3a2a6cff, 0x140c30ff) }
                if sel { outline(r.insetBy(dx: -8, dy: -8), 26, 0x2d8cffff, 6) }
                txt(e, r.midX, r.maxY + 46, 30, sel ? 0xffffffff : 0xc9cfd8ff, bold: sel, align: 0.5)
            }
        default: break
        }
        for i in 0..<Dashboard.tour.count {   // progress dots
            rr(CGRect(x: tx + CGFloat(i) * 34, y: c.maxY - 160, width: i == step ? 40 : 16, height: 16), 8, i == step ? 0x2d8cffff : 0x5a6472ff)
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

    // MARK: pop-up keyboard panel (below the Universal Menu)
    /// target "search" edits the library query, "desktop" types into the Mac.
    private func keyboardPanel(target: String) {
        let p = Dashboard.KB
        rr(p, 36, 0x1f252dff)
        var r = p.insetBy(dx: 30, dy: 26)
        if target == "desktop" {
            let fn: [(String, String, UInt16)] = [("esc", "Esc", 53), ("tab", "Tab", 48), ("left", "◀", 123), ("up", "▲", 126), ("down", "▼", 125), ("right", "▶", 124)]
            let fw = (r.width - CGFloat(fn.count - 1) * 12) / CGFloat(fn.count)
            for (i, (id, label, code)) in fn.enumerated() {
                let k = CGRect(x: r.minX + CGFloat(i) * (fw + 12), y: r.minY - 6, width: fw, height: 62)
                face(k, 16, on: btn("dt:" + id, k) { [unowned self] in keyCode(code); sounds.play("key") }, base: 0x2c343fff, hot: 0x46505eff)
                txt(label, k.midX, k.midY + 10, 28, bold: true, align: 0.5)
            }
            r = CGRect(x: r.minX, y: r.minY + 66, width: r.width, height: r.height - 66)
        }
        let rows = ["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"]
        let gap: CGFloat = 12, kh = (r.height - 4 * gap) / 5, kw = min(130, (r.width - 9 * gap) / 10)
        for (ri, row) in rows.enumerated() {
            let n = CGFloat(row.count), w = n * kw + (n - 1) * gap, x0 = r.midX - w / 2
            for (i, ch) in row.enumerated() {
                let k = CGRect(x: x0 + CGFloat(i) * (kw + gap), y: r.minY + CGFloat(ri) * (kh + gap), width: kw, height: kh)
                let s = kbShift ? String(ch).uppercased() : String(ch)
                face(k, 16, on: btn("kb:" + String(ch), k) { [unowned self] in
                    if target == "search" { query += s; libScroll = 0 } else if target == "name" { if nameDraft.count < 24 { nameDraft += s } } else { typeText(s) }
                    if kbShift { kbShift = false }
                    sounds.play("key"); redraw()
                }, base: 0x3a4452ff, hot: 0x56606eff)
                txt(s, k.midX, k.midY + 11, 32, bold: true, align: 0.5)
            }
        }
        let y = r.minY + 4 * (kh + gap), total = 10 * kw + 9 * gap, x0 = r.midX - total / 2
        let keys: [(String, String, CGFloat, () -> Void)] = [
            ("shift", "⇧", 1.5, { [unowned self] in kbShift.toggle() }),
            ("space", "space", 4.5, { [unowned self] in
                if target == "search" { query += " " } else if target == "name" { if !nameDraft.isEmpty { nameDraft += " " } } else { typeText(" ") } }),
            ("del", "⌫", 1.5, { [unowned self] in
                if target == "search" { if !query.isEmpty { query.removeLast() } } else if target == "name" { if !nameDraft.isEmpty { nameDraft.removeLast() } } else { keyCode(51) } }),
            ("done", target == "desktop" ? "Return" : "Done", 2.5, { [unowned self] in
                if target == "search" { view = "library" } else if target == "name" { if !nameDraft.isEmpty { Dashboard.userName = nameDraft; step += 1 } } else { keyCode(36) } }),
        ]
        var x = x0
        for (id, label, units, fn) in keys {
            let w = units * kw + (units - 1) * gap
            let k = CGRect(x: x, y: y, width: w, height: kh)
            let sel = id == "shift" && kbShift, primary = id == "done"
            face(k, 16, on: btn("kb" + id, k) { [unowned self] in fn(); sounds.play(["space": "keyspace", "del": "keydel", "done": "keyret"][id] ?? "key"); redraw() },
                 base: sel || primary ? 0x2d8cffff : 0x3a4452ff, hot: sel || primary ? 0x4a9dffff : 0x56606eff)
            txt(label, k.midX, k.midY + 11, 30, bold: true, align: 0.5)
            x += w + gap
        }
    }

    func testTourStep(_ n: Int) { view = "welcome"; step = n; redraw() }
    var context: CGContext { ctx }
    // test support (headless interaction verification)
    var testQuery: String { query }
    func testRegionCount() -> Int { regions.count }
    func testHasRegion(_ id: String) -> Bool { regions.contains { $0.id == id } }
    /// uv of the centre of a region, for clicking it in tests.
    func testUV(_ id: String, fx: CGFloat = 0.5) -> CGPoint? {
        regions.last { $0.id == id }.map { CGPoint(x: ($0.r.minX + $0.r.width * fx) / CGFloat(Dashboard.W), y: $0.r.midY / CGFloat(Dashboard.H)) }
    }

    func draw() {
        defer { solidLock.lock(); solidState = (windowOpen, keyboardOpen, dockRect); solidLock.unlock() }
        regions = []
        quest = settings["menu_style"] != "SteamVR"
        ctx.clear(CGRect(x: 0, y: 0, width: Dashboard.W, height: Dashboard.H))
        if view == "settings" && !settings.bool("show_settings_tab") || view == "desktop" && !settings.bool("show_desktop_tabs")
            || view == "playing" && !gameActive { view = "library" }
        if windowOpen {
            chrome()
            switch view {
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
        if windowOpen && !quest && !games.status.isEmpty { txt(games.status, Dashboard.WIN.minX + 40, Dashboard.WIN.minY + 60, 26, 0x9aa3afff, maxW: 700) }
        if view != "welcome" { if quest { questDock() } else { dock() } }   // no Universal Menu during the first-run tour
        if keyboardOpen {
            keyboardPanel(target: view == "desktop" ? "desktop" : view == "welcome" ? "name" : "search")
            grabBar("grabkb", Dashboard.KBGRAB)
        }
        if Date() < toastUntil {
            let w = min(1500, CGFloat(toast.count) * 16 + 80), r = CGRect(x: CGFloat(Dashboard.W) / 2 - w / 2, y: Dashboard.WIN.minY + 84, width: w, height: 64)
            rr(r, 32, 0x0d1117ff)
            txt(toast, r.midX, r.midY + 10, 28, align: 0.5, maxW: w - 40)
        }
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
