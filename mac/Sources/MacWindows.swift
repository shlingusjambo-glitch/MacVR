import Foundation
import AppKit
import ScreenCaptureKit
import ApplicationServices

/// Mac windows in VR: one Mac app window captured on its own (ScreenCaptureKit) for a floating panel you can click,
/// scroll and type into. Input lands on the real window: it is raised, then the pointer events go to its spot on screen.
final class MacWindow: NSObject, SCStreamOutput {
    let id: CGWindowID, pid: pid_t, app: String
    private(set) var title: String
    /// Where the window is on the Mac (global display points, top-left origin), refreshed while it's shown.
    private(set) var frame: CGRect
    private var stream: SCStream?
    private let lock = NSLock()
    private var _latest: CVPixelBuffer?
    var latest: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return _latest }

    init(_ w: SCWindow) {
        id = w.windowID; pid = w.owningApplication?.processID ?? 0; app = w.owningApplication?.applicationName ?? "App"
        title = w.title ?? ""; frame = w.frame
    }

    func start(_ w: SCWindow) {
        let cfg = SCStreamConfiguration()
        let s = min(Double(NSScreen.screens.map(\.backingScaleFactor).max() ?? 2), 3840 / max(1, Double(frame.width)))   // Retina pixels (sharp text), at most 4K wide
        cfg.width = max(64, Int(Double(frame.width) * s) / 2 * 2); cfg.height = max(64, Int(Double(frame.height) * s) / 2 * 2)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.ignoreShadowsSingleWindow = true   // the picture is exactly the window's frame, so panel uv maps 1:1 to the screen
        cfg.showsCursor = true
        let st = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg, delegate: nil)
        try? st.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "vr4.window.\(id)"))
        stream = st
        st.startCapture { err in if let err { NSLog("VR4Mac: window capture failed: %@", "\(err)") } }
    }
    func stop() { stream?.stopCapture { _ in }; stream = nil; lock.lock(); _latest = nil; lock.unlock() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = sb.imageBuffer else { return }   // idle windows send status-only buffers without one
        lock.lock(); _latest = pb; lock.unlock()
    }

    /// Re-reads the window's frame and title; false once it's gone (closed, or its app quit).
    func refresh() -> Bool {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return false }
        frame = r
        if let t = info[kCGWindowName as String] as? String, !t.isEmpty { title = t }
        return true
    }
    /// Panel uv (0-1, top-left) -> global display point on the real window.
    func point(_ uv: CGPoint) -> CGPoint { MacWindow.point(uv, in: frame) }
    static func point(_ uv: CGPoint, in f: CGRect) -> CGPoint {
        CGPoint(x: f.minX + min(1, max(0, uv.x)) * f.width, y: f.minY + min(1, max(0, uv.y)) * f.height)
    }

    /// Bring the real window to the front so clicks and typing reach it (Accessibility).
    func raise() {
        NSRunningApplication(processIdentifier: pid)?.activate()
        let ax = AXUIElementCreateApplication(pid)
        var list: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &list) == .success, let wins = list as? [AXUIElement] else { return }
        for w in wins {
            var pv: CFTypeRef?, sv: CFTypeRef?, p = CGPoint.zero, s = CGSize.zero
            AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv); AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv)
            if let pv { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }; if let sv { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
            if abs(p.x - frame.minX) < 3 && abs(p.y - frame.minY) < 3 && abs(s.width - frame.width) < 3 && abs(s.height - frame.height) < 3 {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString); return
            }
        }
    }
}

/// The window picker: open Mac windows as cards (thumbnail, app icon, app and window name).
enum MacWindows {
    struct Entry { let window: SCWindow?; let app: String; let title: String; let icon: NSImage?; var thumb: CGImage? }   // window nil: snapshot stand-ins
    /// Normal app windows on screen, front to back (not MacVR's own, not tiny palettes).
    static func list() async -> [Entry] {
        guard let c = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [Entry] = []
        for w in c.windows where w.windowLayer == 0 && w.frame.width >= 200 && w.frame.height >= 120 && w.isOnScreen {
            guard let a = w.owningApplication, a.processID != me, !a.applicationName.isEmpty else { continue }
            out.append(Entry(window: w, app: a.applicationName, title: w.title ?? "", icon: NSRunningApplication(processIdentifier: a.processID)?.icon, thumb: nil))
        }
        for i in out.indices.prefix(cards) {   // small thumbnails for the cards
            guard let w = out[i].window else { continue }
            let cfg = SCStreamConfiguration(); cfg.width = 480; cfg.height = max(2, Int(480 * w.frame.height / max(1, w.frame.width))); cfg.ignoreShadowsSingleWindow = true
            out[i].thumb = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
        }
        return Array(out.prefix(cards))
    }

    // Picker canvas: 3 x 3 cards, a title and a close button (y-down layout in canvas px; the texture is drawn y-up).
    static let W = 1500, H = 1060, cards = 9
    static let close = CGRect(x: 1380, y: 30, width: 80, height: 80)
    static func card(_ i: Int) -> CGRect { CGRect(x: 40 + (i % 3) * 480, y: 140 + (i / 3) * 300, width: 460, height: 280) }
    /// What a picker uv points at: a card index, -1 = close, nil = nothing.
    static func pick(_ uv: CGPoint, count: Int) -> Int? {
        let p = CGPoint(x: uv.x * CGFloat(W), y: uv.y * CGFloat(H))
        if close.contains(p) { return -1 }
        return (0..<min(count, cards)).first { card($0).contains(p) }
    }
    static func pickerImage(_ entries: [Entry], hover: Int?) -> CGImage {
        let c = Compositor.overlayCanvas(W, H), h = CGFloat(H)
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
        func round(_ r: CGRect, _ rad: CGFloat, _ col: CGColor) { c.addPath(CGPath(roundedRect: flip(r), cornerWidth: rad, cornerHeight: rad, transform: nil)); c.setFillColor(col); c.fillPath() }
        round(CGRect(x: 0, y: 0, width: W, height: H), 48, CGColor(srgbRed: 0.1, green: 0.115, blue: 0.14, alpha: 0.97))
        Compositor.draw("Mac Windows", in: c, at: CGPoint(x: 48, y: h - 92), size: 50, bold: true)
        Compositor.draw(entries.isEmpty ? "No windows to show. Open an app on your Mac, or allow Screen Recording." : "Pick a window to bring it into VR",
                        in: c, at: CGPoint(x: 400, y: h - 88), size: 30, color: CGColor(srgbRed: 0.65, green: 0.7, blue: 0.76, alpha: 1), maxW: 960)
        round(close, 40, hover == -1 ? CGColor(srgbRed: 0.85, green: 0.3, blue: 0.3, alpha: 1) : CGColor(srgbRed: 0.25, green: 0.28, blue: 0.33, alpha: 1))
        c.setStrokeColor(CGColor(gray: 1, alpha: 1)); c.setLineWidth(6); c.setLineCap(.round)
        let x = flip(close).insetBy(dx: 26, dy: 26)
        c.move(to: CGPoint(x: x.minX, y: x.minY)); c.addLine(to: CGPoint(x: x.maxX, y: x.maxY)); c.move(to: CGPoint(x: x.minX, y: x.maxY)); c.addLine(to: CGPoint(x: x.maxX, y: x.minY)); c.strokePath()
        for (i, e) in entries.prefix(cards).enumerated() {
            let r = card(i)
            round(r, 28, hover == i ? CGColor(srgbRed: 0.24, green: 0.4, blue: 0.72, alpha: 1) : CGColor(srgbRed: 0.18, green: 0.2, blue: 0.24, alpha: 1))
            let shot = CGRect(x: r.minX + 16, y: r.minY + 16, width: r.width - 32, height: r.height - 100)
            if let t = e.thumb {   // aspect-fit
                let s = min(shot.width / CGFloat(t.width), shot.height / CGFloat(t.height)), w = CGFloat(t.width) * s, hh = CGFloat(t.height) * s
                c.draw(t, in: flip(CGRect(x: shot.midX - w / 2, y: shot.midY - hh / 2, width: w, height: hh)))
            } else { round(shot, 14, CGColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1)) }
            if let icon = e.icon?.cgImage(forProposedRect: nil, context: nil, hints: nil) { c.draw(icon, in: flip(CGRect(x: r.minX + 18, y: r.maxY - 74, width: 56, height: 56))) }
            Compositor.draw(e.app, in: c, at: CGPoint(x: r.minX + 88, y: h - r.maxY + 44), size: 27, bold: true, maxW: r.width - 110)
            Compositor.draw(e.title.isEmpty ? " " : e.title, in: c, at: CGPoint(x: r.minX + 88, y: h - r.maxY + 14), size: 22, color: CGColor(srgbRed: 0.7, green: 0.74, blue: 0.8, alpha: 1), maxW: r.width - 110)
        }
        return c.makeImage()!
    }

    // Window bar: under each Mac window, Quest style: app icon and name, then keyboard, pin and close buttons.
    static let barW = 1200, barH = 96
    enum BarPart { case grab, keyboard, pin, close }
    static func barPart(_ u: CGFloat) -> BarPart {
        let x = u * CGFloat(barW)
        return x > CGFloat(barW) - 110 ? .close : x > CGFloat(barW) - 210 ? .pin : x > CGFloat(barW) - 310 ? .keyboard : .grab
    }
    static func barImage(app: String, title: String, icon: NSImage?, pinned: Bool, focused: Bool, hover: BarPart?) -> CGImage {
        let c = Compositor.overlayCanvas(barW, barH), w = CGFloat(barW), h = CGFloat(barH)
        c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        c.setFillColor(CGColor(srgbRed: 0.1, green: 0.11, blue: 0.13, alpha: focused || hover != nil ? 0.95 : 0.8)); c.fillPath()
        if let icon = icon?.cgImage(forProposedRect: nil, context: nil, hints: nil) { c.draw(icon, in: CGRect(x: 24, y: 16, width: 64, height: 64)) }
        Compositor.draw(title.isEmpty ? app : "\(app) — \(title)", in: c, at: CGPoint(x: 104, y: 36), size: 32, bold: true, maxW: w - 450)
        for (part, x) in [(BarPart.keyboard, w - 260), (.pin, w - 160), (.close, w - 60)] {
            let r = CGRect(x: x - 38, y: h / 2 - 38, width: 76, height: 76)
            let on = part == .pin && pinned
            c.setFillColor(hover == part ? (part == .close ? CGColor(srgbRed: 0.85, green: 0.3, blue: 0.3, alpha: 1) : CGColor(srgbRed: 0.35, green: 0.4, blue: 0.48, alpha: 1))
                           : on ? CGColor(srgbRed: 0.18, green: 0.55, blue: 1, alpha: 1) : CGColor(srgbRed: 0.22, green: 0.25, blue: 0.3, alpha: 1))
            c.fillEllipse(in: r)
            c.setStrokeColor(CGColor(gray: 1, alpha: 1)); c.setFillColor(CGColor(gray: 1, alpha: 1)); c.setLineWidth(5); c.setLineCap(.round)
            let g = r.insetBy(dx: 24, dy: 24)
            switch part {
            case .close: c.move(to: CGPoint(x: g.minX, y: g.minY)); c.addLine(to: CGPoint(x: g.maxX, y: g.maxY)); c.move(to: CGPoint(x: g.minX, y: g.maxY)); c.addLine(to: CGPoint(x: g.maxX, y: g.minY)); c.strokePath()
            case .pin:   // a push pin: head, needle
                c.fillEllipse(in: CGRect(x: g.midX - 9, y: g.midY - 2, width: 18, height: 18)); c.move(to: CGPoint(x: g.midX, y: g.midY)); c.addLine(to: CGPoint(x: g.midX, y: g.minY - 4)); c.strokePath()
            case .keyboard:   // keys
                c.stroke(CGRect(x: g.minX - 4, y: g.minY + 4, width: g.width + 8, height: g.height - 8))
                for k in 0..<3 { c.fill(CGRect(x: g.minX + 2 + CGFloat(k) * 10, y: g.midY + 1, width: 5, height: 5)) }
                c.fill(CGRect(x: g.minX + 6, y: g.minY + 9, width: g.width - 12, height: 4))
            case .grab: break
            }
        }
        return c.makeImage()!
    }
}
