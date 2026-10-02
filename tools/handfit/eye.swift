import SceneKit
import AppKit
/// Render recorded tracking frame `idx` from the left eye with controllers + hands, like the headset.
func eyeRender(_ idx: Int, _ out: String, buttons: UInt32? = nil, trigger: Float? = nil) {
    let d = try! Data(contentsOf: URL(fileURLWithPath: "../track.bin"))
    var t = VR4Tracking()
    _ = withUnsafeMutableBytes(of: &t) { d.copyBytes(to: $0, from: idx * MemoryLayout<VR4Tracking>.size ..< (idx + 1) * MemoryLayout<VR4Tracking>.size) }
    if ProcessInfo.processInfo.environment["SYN"] != nil {   // held controllers at chest height, eye at origin looking ahead/down
        let rel = simd_quatf(angle: -.pi / 3, axis: SIMD3(1, 0, 0))   // aim = grip rotated -60 deg about x (measured)
        func held(_ x: Float, yaw: Float) -> VR4Pose {
            let aim = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: -0.25, axis: SIMD3(1, 0, 0))
            let g = aim * rel.inverse
            return VR4Pose(px: x, py: -0.3, pz: -0.38, qx: g.imag.x, qy: g.imag.y, qz: g.imag.z, qw: g.real)
        }
        t.hand.0.grip = held(-0.16, yaw: 0.15); t.hand.1.grip = held(0.16, yaw: -0.15)
        t.hand.0.flags = 3; t.hand.1.flags = 3
        let look = simd_quatf(angle: -0.45, axis: SIMD3(1, 0, 0))
        t.eye.0.pose = VR4Pose(px: -0.03, py: 0, pz: 0, qx: look.imag.x, qy: look.imag.y, qz: look.imag.z, qw: look.real)
        if let v = ProcessInfo.processInfo.environment["VIEW"], v.hasPrefix("face") {   // straight down onto the face buttons
            let g = v == "face_r" ? t.hand.1.grip : t.hand.0.grip
            let q = simd_quatf(ix: g.qx, iy: g.qy, iz: g.qz, r: g.qw), o = SIMD3(g.px, g.py, g.pz)
            let target = o + q.act(SIMD3(0, 0.01, -0.022)), from = o + q.act(SIMD3(0, 0.16, 0.0))
            let fwd = simd_normalize(target - from), right = simd_normalize(simd_cross(fwd, q.act(SIMD3(0, 0, -1)))), up = simd_cross(right, fwd)
            let cq = simd_quatf(simd_float3x3(columns: (right, up, -fwd)))
            t.eye.0.pose = VR4Pose(px: from.x, py: from.y, pz: from.z, qx: cq.imag.x, qy: cq.imag.y, qz: cq.imag.z, qw: cq.real)
        } else if let v = ProcessInfo.processInfo.environment["VIEW"] {   // inspection cameras around the left controller
            let target = SIMD3<Float>(v.hasSuffix("r") ? 0.16 : -0.16, -0.3, -0.38)
            let from: SIMD3<Float> = v == "top" ? SIMD3(-0.17, -0.18, -0.36) : v == "trig" ? SIMD3(-0.24, -0.33, -0.48) : v == "fp2r" ? SIMD3(0.1, -0.08, -0.12) : v == "fp2" ? SIMD3(-0.1, -0.08, -0.12) : v == "under" ? SIMD3(-0.2, -0.62, -0.3) : v == "under_r" ? SIMD3(0.2, -0.62, -0.3) : v == "side_r" ? SIMD3(0.5, -0.2, -0.32) : v == "side" ? SIMD3(-0.5, -0.2, -0.32) : v == "front" ? SIMD3(-0.12, -0.18, -0.8) : SIMD3(0.18, -0.24, -0.34)
            let fwd = simd_normalize(target - from), right = simd_normalize(simd_cross(fwd, SIMD3(0, 1, 0))), up = simd_cross(right, fwd)
            let q = simd_quatf(simd_float3x3(columns: (right, up, -fwd)))
            t.eye.0.pose = VR4Pose(px: from.x, py: from.y, pz: from.z, qx: q.imag.x, qy: q.imag.y, qz: q.imag.z, qw: q.real)
        }
        let z = Float(ProcessInfo.processInfo.environment["Z"] ?? "0.32")!, o: Float = ProcessInfo.processInfo.environment["VIEW"] == nil ? 0.12 : 0; t.eye.0.fov = VR4Fov(left: -z - o, right: z - o, up: z - o, down: -z - o)
    }
    let scene = SCNScene(); scene.background.contents = NSImage(contentsOfFile: "/Users/elywright/VR4Mac/mac/Resources/environments/forest_slope.jpg")
    scene.lightingEnvironment.contents = Compositor_studio(); scene.lightingEnvironment.intensity = 1.6
    let model: HeadsetModel = [ "q2": .quest2, "q3": .quest3][ProcessInfo.processInfo.environment["M"] ?? ""] ?? .quest1
    for (i, var h) in [t.hand.0, t.hand.1].enumerated() {
        if let b = buttons { h.buttons = b }; if let tr = trigger { h.trigger = tr }
        let env = ProcessInfo.processInfo.environment
        h.squeeze = Float(env["SQ"] ?? "0")!; h.stick_x = Float(env["SX"] ?? "0")!; h.stick_y = Float(env["SY"] ?? "0")!
        let grip = SCNNode(); grip.simdPosition = SIMD3(h.grip.px, h.grip.py, h.grip.pz); grip.simdOrientation = simd_quatf(ix: h.grip.qx, iy: h.grip.qy, iz: h.grip.qz, r: h.grip.qw)
        let ctl = ControllerModels.build(model, hand: i), rig = ControllerRig(ctl, hand: i); rig.update(h)
        let hm = HandModel(hand: i, model: model, controller: ctl)!; hm.update(h, targets: rig.targets(), poke: ProcessInfo.processInfo.environment["POKE"] != nil)
        grip.addChildNode(ctl); grip.addChildNode(hm.node); scene.rootNode.addChildNode(grip)
        if ProcessInfo.processInfo.environment["MARK"] != nil, let tg = rig.targets() {   // red = targets, green = index pad
            func dot(_ p: SIMD3<Float>, _ c: NSColor, _ r: CGFloat = 0.0025) { let n = SCNNode(geometry: SCNSphere(radius: r)); n.geometry!.firstMaterial!.diffuse.contents = c; n.geometry!.firstMaterial!.lightingModel = .constant; n.geometry!.firstMaterial!.readsFromDepthBuffer = false; n.renderingOrder = 100; n.simdPosition = p; grip.addChildNode(n) }
            for p in [tg.trigger, tg.stick, tg.rest] + Array(tg.buttons.values) { dot(p, .red) }
            dot(hm.indexTip, .green); dot(hm.thumbTip, .cyan)
        }
    }
    let e = t.eye.0, cam = SCNNode(); cam.camera = SCNCamera()
    cam.simdPosition = SIMD3(e.pose.px, e.pose.py, e.pose.pz); cam.simdOrientation = simd_quatf(ix: e.pose.qx, iy: e.pose.qy, iz: e.pose.qz, r: e.pose.qw)
    let n: Float = 0.02, f: Float = 50, l = tan(e.fov.left) * n, r = tan(e.fov.right) * n, u = tan(e.fov.up) * n, dn = tan(e.fov.down) * n
    var m = SCNMatrix4(); m.m11 = CGFloat(2 * n / (r - l)); m.m22 = CGFloat(2 * n / (u - dn)); m.m31 = CGFloat((r + l) / (r - l)); m.m32 = CGFloat((u + dn) / (u - dn))
    m.m33 = CGFloat(-(f + n) / (f - n)); m.m34 = -1; m.m43 = CGFloat(-2 * f * n / (f - n))
    cam.camera!.projectionTransform = m
    scene.rootNode.addChildNode(cam)
    let rr = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil); rr.scene = scene; rr.pointOfView = cam
    let img = rr.snapshot(atTime: 0, with: CGSize(width: 900, height: 900), antialiasingMode: .multisampling4X)
    if let label = ProcessInfo.processInfo.environment["LABEL"] {
        img.lockFocus(); NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black]).draw(at: NSPoint(x: 14, y: 850)); img.unlockFocus()
    }
    try! NSBitmapImageRep(cgImage: img.cgImage(forProposedRect: nil, context: nil, hints: nil)!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}
