import Foundation
import CoreVideo
import simd
import SceneKit

/// MacVR OS shell checks (Compositor/Engine logic that needs no headset): run with Tests/run-shell.sh.
@main enum ShellTest {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        overlayStereo()
        pinchCursor()
        skySphereMatchesBackground()
        springSettle()
        theaterLights()
        macWindowPanels()
        autoBitrate()
        slotFocus()
        print("ALL SHELL CHECKS PASSED")
    }

    /// Theater presets size and place the screen; Dim lights darken the sky around it; a dark room picks up the
    /// picture's colour (spill), averaged from the capture's smallest mip.
    static func theaterLights() {
        let comp = Compositor(); comp.reduceMotion = true; comp.setDashVisible(false); comp.setEnvironment("Void")
        var screen: CVPixelBuffer?
        CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &screen)
        CVPixelBufferLockBaseAddress(screen!, []); let b = CVPixelBufferGetBaseAddress(screen!)!.assumingMemoryBound(to: UInt32.self)
        for i in 0..<(CVPixelBufferGetBytesPerRow(screen!) / 4 * 90) { b[i] = 0xff_ff_20_10 }   // BGRA little-endian: red picture
        CVPixelBufferUnlockBaseAddress(screen!, [])
        let p = VR4Pose(px: 0, py: 1.6, pz: 0, qx: 0, qy: 0, qz: 0, qw: 1), f = VR4Fov(left: -0.7, right: 0.7, up: 0.7, down: -0.7)
        var t = VR4Tracking(); t.head = p; t.eye = (VR4Eye(pose: p, fov: f), VR4Eye(pose: p, fov: f))
        func corner(_ lights: String) -> UInt8 {   // top-left pixel of the left eye: sky, beside the screen
            comp.setTheaterStyle(Compositor.theaterStyle(screen: "Small", curved: true, lights: lights))
            comp.setTheater(screen, head: p)
            let pb = comp.render(t, eyeW: 64, eyeH: 64)!
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let px = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            return max(px[0], px[1], px[2])
        }
        let home = corner("Home"), dim = corner("Dim"), dark = corner("Dark")
        assert(home > 60 && Double(dim) < Double(home) * 0.6 && dim > 3 && dark < 10, "sky beside the screen: home \(home), dim \(dim), dark \(dark)")
        Thread.sleep(forTimeInterval: 0.1); _ = corner("Dark")   // the average lands a frame later
        let avg = comp.screenAverage
        assert(avg.x > 0.9 && avg.y < 0.05 && avg.z < 0.05, "average of a red picture \(avg)")
        let s = Compositor.theaterStyle(screen: "IMAX", curved: false, lights: "Dark")
        assert(s.width > 12 && s.distance > 7 && !s.curved && Compositor.theaterStyle(screen: "?", curved: true, lights: "Dark").width == 6.4, "presets")
        print("PASS: theater lights (sky home \(home), dim \(dim), dark \(dark)) and picture average")
    }

    /// Mac windows in VR: a ray at a spot on the panel maps to the same spot on the real window; the bar's buttons, the
    /// picker's cards, moving (stays under the ray, faces you), resizing, pinning (stays with the menu closed).
    static func macWindowPanels() {
        let comp = Compositor(), head = VR4Pose(px: 0, py: 1.6, pz: 0, qx: 0, qy: 0, qz: 0, qw: 1)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1600, 1000, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
        comp.addWindow(7, width: 1.0, head: head)
        comp.setWindow(7, pb, bar: MacWindows.barImage(app: "Notes", title: "", icon: nil, pinned: false, focused: true, hover: nil))
        comp.showWindows(menu: true, focus: 7)
        var t = VR4Tracking(); t.head = head; t.eye = (VR4Eye(pose: head, fov: VR4Fov(left: -1, right: 1, up: 1, down: -1)), VR4Eye(pose: head, fov: VR4Fov(left: -1, right: 1, up: 1, down: -1)))
        _ = comp.render(t, eyeW: 32, eyeH: 32)   // SceneKit hit tests need one render of the scene
        let p = comp.windowPanels[7]!, c = p.content.simdWorldPosition, right = p.root.simdWorldOrientation.act(SIMD3<Float>(1, 0, 0))
        func aim(at w: SIMD3<Float>) -> VR4Pose {   // from the head straight at a world point
            let q = simd_quatf(from: SIMD3(0, 0, -1), to: simd_normalize(w - SIMD3(0, 1.6, 0)))
            return VR4Pose(px: 0, py: 1.6, pz: 0, qx: q.imag.x, qy: q.imag.y, qz: q.imag.z, qw: q.real)
        }
        // a point 1/4 in from the left and 1/4 down from the top of the 1.0 x 0.625 m window
        guard let h = comp.hitWindow(aim(at: c - right * 0.25 + SIMD3(0, 0.156, 0))) else { fatalError("no hit on the window") }
        assert(!h.bar && abs(h.uv.x - 0.25) < 0.02 && abs(h.uv.y - 0.25) < 0.02, "uv \(h.uv)")
        let frame = CGRect(x: 100, y: 50, width: 1600, height: 1000), pt = MacWindow.point(h.uv, in: frame)
        assert(abs(pt.x - 500) < 33 && abs(pt.y - 300) < 21, "screen point \(pt)")
        let barHit = comp.hitWindow(aim(at: p.bar.simdWorldPosition + right * 0.36))!   // near the bar's right end: close
        assert(barHit.bar && MacWindows.barPart(barHit.uv.x) == .close && MacWindows.barPart(0.2) == .grab, "bar \(barHit.uv)")
        // move: grab the bar, swing the ray 0.3 rad left; the window follows and turns to face the head
        comp.beginWindowMove(7, aim(at: p.bar.simdWorldPosition), dist: barHit.dist)
        let q = simd_quatf(angle: 0.3, axis: SIMD3(0, 1, 0)) * simd_quatf(from: SIMD3(0, 0, -1), to: simd_normalize(p.bar.simdWorldPosition - SIMD3(0, 1.6, 0)))
        let moved = VR4Pose(px: 0, py: 1.6, pz: 0, qx: q.imag.x, qy: q.imag.y, qz: q.imag.z, qw: q.real)
        let before = p.root.simdWorldPosition
        Thread.sleep(forTimeInterval: 0.2); comp.updateWindowMove(moved, head: head, push: 0); comp.endWindowMove()
        let after = p.root.simdWorldPosition, toHead = simd_normalize(SIMD3(0, 1.6, 0) - after), facing = p.root.simdWorldOrientation.act(SIMD3<Float>(0, 0, 1))
        assert(abs(simd_length(SIMD2(after.x, after.z)) - simd_length(SIMD2(before.x, before.z))) < 0.05 && simd_dot(facing, toHead) > 0.97, "moved around you, facing you: before \(before) after \(after) facing \(simd_dot(facing, toHead))")
        comp.scaleWindow(7, by: 10); assert(comp.windowScale(7) == 3, "resize clamps at 3x")
        comp.showWindows(menu: false, focus: nil); assert(p.root.isHidden, "unpinned: hides with the menu")
        comp.setWindowPinned(7, true); comp.showWindows(menu: false, focus: nil); assert(!p.root.isHidden, "pinned: stays")
        assert(MacWindows.pick(CGPoint(x: (40 + 230) / 1500.0, y: (140 + 140) / 1060.0), count: 4) == 0 && MacWindows.pick(CGPoint(x: 1420 / 1500.0, y: 70 / 1060.0), count: 4) == -1
               && MacWindows.pick(CGPoint(x: 0.5, y: 0.9), count: 4) == nil, "picker cards and close")
        comp.showPicker(MacWindows.pickerImage([], hover: nil), head: head); _ = comp.render(t, eyeW: 32, eyeH: 32)
        let ph = comp.hitPicker(aim(at: SIMD3(-0.3, 1.8, -0.8)))!   // upper left of the picker
        assert(ph.uv.x < 0.2 && ph.uv.y < 0.2, "picker uv is top-left origin \(ph.uv)")
        comp.removeWindow(7); assert(comp.windowPanels.isEmpty && p.root.parent == nil, "closed")
        print("PASS: Mac window panels (uv to screen, bar, move, resize, pin, picker)")
    }

    /// Multitasking: with side windows open, the one you point at stays lit and the others dim; alone, nothing dims.
    static func slotFocus() {
        let comp = Compositor(); comp.reduceMotion = true
        comp.setLayout(quest: true, compact: true); comp.setRadius(0.7)
        let head = VR4Pose(px: 0, py: 1.6, pz: 0, qx: 0, qy: 0, qz: 0, qw: 1); comp.place(head: head)
        var t = VR4Tracking(); t.head = head; t.eye = (VR4Eye(pose: head, fov: VR4Fov(left: -1, right: 1, up: 1, down: -1)), VR4Eye(pose: head, fov: VR4Fov(left: -1, right: 1, up: 1, down: -1)))
        func white(_ n: SCNNode) -> CGFloat { (n.geometry?.firstMaterial?.multiply.contents as? NSColor)?.usingColorSpace(.sRGB)?.redComponent ?? 1 }
        _ = comp.render(t, eyeW: 16, eyeH: 16)
        assert(white(comp.sides[0]) > 0.99, "no side windows: nothing dims")
        let tex = comp.device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 4, height: 4, mipmapped: false))
        comp.setSide(0, tex); comp.setSide(1, tex); comp.setSlotFocus(0)
        _ = comp.render(t, eyeW: 16, eyeH: 16)
        assert(white(comp.sides[0]) > 0.99 && abs(white(comp.sides[1]) - 0.8) < 0.02, "left focused, right dimmed")
        print("PASS: multitasking focus dimming")
    }

    /// Auto bitrate: a congested link backs off fast, then it creeps back to the ceiling once things are clean.
    static func autoBitrate() {
        var r = 100
        for _ in 0..<3 { r = Engine.adaptBitrate(r, ceiling: 100, congested: true, cleanFor: 0) }
        assert(r == 51, "three bad seconds: 100 -> 80 -> 64 -> 51 (\(r))")
        assert(Engine.adaptBitrate(r, ceiling: 100, congested: false, cleanFor: 3) == r, "holds while it's only been clean briefly")
        var s = 0; while r < 100 && s < 30 { r = Engine.adaptBitrate(r, ceiling: 100, congested: false, cleanFor: 8 + Double(s)); s += 1 }
        assert(r == 100 && s < 10, "back to the ceiling in \(s) clean seconds, not past it")
        var low = 20; for _ in 0..<10 { low = Engine.adaptBitrate(low, ceiling: 40, congested: true, cleanFor: 0) }
        assert(low == 15, "floor 15 Mbps")
        print("PASS: auto bitrate")
    }

    /// Windows spring into their slot: quick, a little overshoot, settled when the glide ends (0.45 s).
    static func springSettle() {
        let curve = stride(from: Float(0), through: 0.45, by: 0.005).map(Compositor.spring), peak = curve.max()!
        assert(peak > 1.03 && peak < 1.08, "a little overshoot (\(peak))")
        assert(Compositor.spring(0) == 0 && Compositor.spring(0.06) > 0.3 && abs(Compositor.spring(0.4) - 1) < 0.012, "fast and settled")
        print("PASS: slot spring (peak \(String(format: "%.3f", peak)))")
    }

    /// Crossfades put the old panorama on a sphere: it must line up with SceneKit's background mapping in every direction,
    /// or the sky would visibly jump when a fade starts.
    static func skySphereMatchesBackground() {
        let w = 256, h = 128   // equirect test card: hue around, brightness up
        let c = Compositor.overlayCanvas(w, h)
        for x in 0..<w { for y in 0..<h {
            c.setFillColor(NSColor(hue: CGFloat(x) / CGFloat(w), saturation: 0.9, brightness: 0.3 + 0.7 * CGFloat(y) / CGFloat(h), alpha: 1).cgColor)
            c.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        let img = c.makeImage()!
        let comp = Compositor(); comp.setDashVisible(false); comp.setGrid(false)
        Thread.sleep(forTimeInterval: 0.15)
        func shot(yaw: Float) -> [UInt8] {
            let q = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: 0.35, axis: SIMD3(1, 0, 0))
            let p = VR4Pose(px: 0, py: 1.6, pz: 0, qx: q.imag.x, qy: q.imag.y, qz: q.imag.z, qw: q.real), f = VR4Fov(left: -0.7, right: 0.7, up: 0.7, down: -0.7)
            var t = VR4Tracking(); t.head = p; t.eye = (VR4Eye(pose: p, fov: f), VR4Eye(pose: p, fov: f))
            let pb = comp.render(t, eyeW: 64, eyeH: 64)!
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let b = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), rb = CVPixelBufferGetBytesPerRow(pb)
            return (0..<64).flatMap { y in (0..<64 * 4).map { b[y * rb + $0] } }   // left eye
        }
        let yaws: [Float] = [0, 1.6, 3.1, 4.7]
        comp.scene.background.contents = img
        let ref = yaws.map(shot)
        comp.scene.background.contents = NSColor.black
        let s = Compositor.skySphere(radius: 120); s.geometry?.firstMaterial?.diffuse.contents = img; comp.scene.rootNode.addChildNode(s)
        func err() -> Double { zip(yaws.map(shot), ref).map { a, b in zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count) }.max()! }
        let e = err()
        let others = (1..<4).map { k -> Double in s.simdEulerAngles.y = Compositor.skyYaw + Float(k) * .pi / 2; return err() }
        assert(e < 6 && others.allSatisfy { $0 > e * 8 }, "sky sphere matches the background (mean error \(e), other seams \(others))")
        print("PASS: crossfade sky sphere lines up with the background (mean error \(String(format: "%.2f", e)), other seams \(others.map { Int($0) }))")
    }

    /// The pointer cursor sits at the laser's hit, faces back along it, keeps its angular size, and its ring closes in
    /// with pinch (hands) or trigger (controllers) progress, filling on the press.
    static func pinchCursor() {
        let comp = Compositor()
        let head = VR4Pose(px: 0, py: 1.6, pz: 0, qx: 0, qy: 0, qz: 0, qw: 1)
        comp.place(head: head); comp.setDashVisible(true)
        var t = VR4Tracking(); t.head = head
        var h = VR4Hand(); h.flags = UInt32(VR4_HAND_ACTIVE | VR4_HAND_POSE_VALID); h.aim = VR4Pose(px: 0.2, py: 1.3, pz: -0.2, qx: 0, qy: 0, qz: 0, qw: 1); h.grip = h.aim
        func cursor(_ trigger: Float, tracked: Bool, ray: Float) -> SCNNode {
            var hh = h; hh.trigger = trigger; if tracked { hh.flags |= UInt32(VR4_HAND_TRACKED) }
            t.hand.1 = hh
            comp.updateHands(t, rays: [nil, ray])
            return comp.scene.rootNode.childNodes.first { $0.childNodes.count == 2 && $0.childNodes.allSatisfy { $0.renderingOrder == 200 } && !$0.isHidden }!
        }
        let idle = cursor(0, tracked: true, ray: 1)
        assert(simd_distance(idle.simdWorldPosition, SIMD3(0.2, 1.3, -1.198)) < 0.001, "at the hit \(idle.simdWorldPosition)")
        assert(abs(idle.simdScale.x - 0.06) < 1e-4 && idle.childNodes[0].simdScale.x == 1, "1 m: 6 cm, ring open")
        let near = cursor(0.25, tracked: true, ray: 2)
        assert(abs(near.simdScale.x - 0.12) < 1e-4, "constant angle: twice as far, twice as big")
        assert(abs(near.childNodes[0].simdScale.x - 0.825) < 1e-3 && near.childNodes[1].simdScale.x < 0.4, "half way to a pinch: ring closing, not filled")
        let pinched = cursor(1, tracked: true, ray: 1)
        assert(abs(pinched.childNodes[0].simdScale.x - 0.65) < 1e-3 && pinched.childNodes[1].simdScale.x > 0.6, "pinched: filled")
        assert(cursor(0.5, tracked: false, ray: 1).childNodes[1].simdScale.x < 0.4 && cursor(0.6, tracked: false, ray: 1).childNodes[1].simdScale.x > 0.6, "controller fills past the click point")
        print("PASS: pinch cursor")
    }

    /// Head-locked overlays land in each eye at that eye's projection (stereo depth), blended, clipped to the eye.
    static func overlayStereo() {
        let comp = Compositor()
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 200, 100, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pb else { fatalError("pixel buffer") }
        CVPixelBufferLockBaseAddress(pb, []); memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetDataSize(pb)); CVPixelBufferUnlockBaseAddress(pb, [])
        let img = Compositor.overlayCanvas(10, 10)
        img.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); img.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let eye = { (x: Float) in VR4Pose(px: x, py: 1.6, pz: 0, qx: 0, qy: 0, qz: 0, qw: 1) }
        let fov = VR4Fov(left: -.pi / 4, right: .pi / 4, up: .pi / 4, down: -.pi / 4)
        comp.stamp(pb, eyes: [eye(-0.032), eye(0.032)], fovs: [fov, fov], [(img, SIMD3(0, 0, -1)), (img, SIMD3(3, 0, -1))])   // second: off to the right, clipped
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), rb = CVPixelBufferGetBytesPerRow(pb)
        func red(_ x: Int, _ y: Int) -> Bool { base[y * rb + x * 4 + 2] > 200 && base[y * rb + x * 4] < 50 }   // BGRA
        // left eye sees a point straight ahead of the head slightly right of its centre, the right eye slightly left
        assert(red(51, 50) && !red(44, 50) && red(55, 50), "left eye overlay at u 0.516")
        assert(red(148, 50) && red(144, 50) && !red(155, 50), "right eye overlay at u 0.484")
        var count = 0
        for y in 0..<100 { for x in 0..<200 where red(x, y) { count += 1 } }
        assert(count == 200, "two 10x10 blits, the far-right one is outside both eyes (\(count))")
        print("PASS: stereo overlays")
    }
}
