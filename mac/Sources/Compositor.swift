import Foundation
import SceneKit
import Metal
import CoreVideo
import ScreenCaptureKit
import VideoToolbox
import Accelerate

/// Renders the VR home + dashboard + controllers for both eyes (side by side) into a CVPixelBuffer.
final class Compositor {
    let device = MTLCreateSystemDefaultDevice()!
    private lazy var cq = device.makeCommandQueue()!
    private let renderer: SCNRenderer
    let scene = SCNScene()
    private let eyes = [SCNNode(), SCNNode()]
    let dash = SCNNode()
    /// The window (with its grab bar) and the dock (with its grab bar) are separate panels cut from the one menu texture,
    /// each movable on its own. `winContent` is what animates when a window opens.
    private let win = SCNNode(), winContent = SCNNode(), panel = SCNNode(), screen = SCNNode(), dockNode = SCNNode(), dockPanel = SCNNode()
    private let kbNode = SCNNode(), kbPanel = SCNNode()   // pop-up keyboard, floats below the Universal Menu while typing
    private let grid: SCNNode
    enum Part { case window, dock, keyboard }
    private static let split = Float(Dashboard.SPLIT) / Float(Dashboard.H)   // canvas v where the dock part starts
    private static let split2 = Float(Dashboard.SPLIT2) / Float(Dashboard.H) // canvas v where the keyboard part starts
    private var hands: [(grip: SCNNode, aim: SCNNode, laser: SCNNode, dot: SCNNode)] = []
    private var rigs: [ControllerRig] = [], handModels: [HandModel?] = []
    /// Connected headset generation (default Quest 2). Engine should call
    /// setControllerModel(HeadsetModel.detect(device:)) on HELLO.
    private var controllerModel: HeadsetModel = .quest2
    /// Swap controller geometry per headset generation. Additive only:
    /// grip nodes (positions driven by updateHands) are preserved.
    func setControllerModel(_ m: HeadsetModel) {
        guard m != controllerModel else { return }
        controllerModel = m
        for (i, h) in hands.enumerated() {
            h.grip.childNodes.forEach { $0.removeFromParentNode() }
            attachController(h.grip, hand: i)
        }
    }
    private(set) var radius: Float = 0
    private var cache: CVMetalTextureCache!
    private var pool: CVPixelBufferPool?, poolSize = (0, 0)
    private var depth: MTLTexture?

    init() {
        renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.usesReverseZ = false          // we supply our own (OpenXR-style) projection
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)

        scene.background.contents = Compositor.sky()
        let plane = SCNPlane(width: 60, height: 60)
        let gm = plane.firstMaterial!
        gm.diffuse.contents = Compositor.gridTile(); gm.diffuse.wrapS = .repeat; gm.diffuse.wrapT = .repeat
        gm.diffuse.contentsTransform = SCNMatrix4MakeScale(60, 60, 1)
        gm.lightingModel = .constant; gm.isDoubleSided = true; gm.writesToDepthBuffer = false
        grid = SCNNode(geometry: plane); grid.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(grid)

        for e in eyes { e.camera = SCNCamera(); scene.rootNode.addChildNode(e) }
        // light for the physically based controller meshes (menu, grid and sky are unlit)
        scene.lightingEnvironment.contents = Compositor.studio(); scene.lightingEnvironment.intensity = 1.6
        let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 900
        key.eulerAngles = SCNVector3(-0.9, 0.4, 0); scene.rootNode.addChildNode(key)
        dash.addChildNode(win); win.addChildNode(winContent); winContent.addChildNode(panel); winContent.addChildNode(screen)
        dash.addChildNode(dockNode); dockNode.addChildNode(dockPanel)
        dash.addChildNode(kbNode); kbNode.addChildNode(kbPanel); kbNode.isHidden = true
        scene.rootNode.addChildNode(dash)

        for i in 0..<2 {
            let grip = SCNNode(), aim = SCNNode()
            attachController(grip, hand: i)
            let laser = SCNNode(geometry: SCNCylinder(radius: 0.0015, height: 1))
            laser.pivot = SCNMatrix4MakeTranslation(0, -0.5, 0); laser.eulerAngles.x = -.pi / 2
            laser.geometry?.firstMaterial?.diffuse.contents = NSColor(red: 0.4, green: 0.75, blue: 0.96, alpha: 1)
            laser.geometry?.firstMaterial?.lightingModel = .constant
            aim.addChildNode(laser)
            let dot = SCNNode(geometry: SCNSphere(radius: 0.007)); dot.geometry?.firstMaterial?.lightingModel = .constant
            [grip, aim, dot].forEach(scene.rootNode.addChildNode)
            hands.append((grip, aim, laser, dot))
        }
    }
    /// Controller mesh plus the translucent hand holding it (rigs index by hand).
    private func attachController(_ grip: SCNNode, hand i: Int) {
        let ctl = ControllerModels.build(controllerModel, hand: i), hm = HandModel(hand: i)
        grip.addChildNode(ctl)
        if let hm { grip.addChildNode(hm.node) }
        if rigs.count > i { rigs[i] = ControllerRig(ctl, hand: i); handModels[i] = hm } else { rigs.append(ControllerRig(ctl, hand: i)); handModels.append(hm) }
    }

    // MARK: scene content
    static func sky() -> CGImage {  // 2:1 equirectangular vertical gradient (purple void like SteamVR)
        let w = 512, h = 256
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cols = [CGColor(srgbRed: 0.1, green: 0.05, blue: 0.22, alpha: 1), CGColor(srgbRed: 0.42, green: 0.26, blue: 0.72, alpha: 1),
                    CGColor(srgbRed: 0.05, green: 0.03, blue: 0.16, alpha: 1)]   // bottom, horizon, top (CG y-up)
        c.drawLinearGradient(CGGradient(colorsSpace: nil, colors: cols as CFArray, locations: [0.3, 0.5, 1])!, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        return c.makeImage()!
    }
    /// Neutral studio environment (bright top, dim floor) used only as image-based light.
    static func studio() -> CGImage {
        let w = 256, h = 128
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cols = [CGColor(gray: 0.12, alpha: 1), CGColor(gray: 0.55, alpha: 1), CGColor(gray: 0.95, alpha: 1)]   // bottom, horizon, top
        c.drawLinearGradient(CGGradient(colorsSpace: nil, colors: cols as CFArray, locations: [0, 0.5, 1])!, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        return c.makeImage()!
    }
    static func gridTile() -> CGImage {
        let c = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setStrokeColor(CGColor(srgbRed: 0.64, green: 0.49, blue: 1, alpha: 0.35)); c.setLineWidth(2)
        c.stroke(CGRect(x: 0, y: 0, width: 64, height: 64))
        return c.makeImage()!
    }

    /// Plane of width w wrapped around a cylinder of radius r whose axis passes through the viewer; texture v=0 at top.
    /// Settings > Universal Menu > Curved UI. Off = flat panels.
    static var curved = true
    static func bent(w: Float, h: Float, r: Float, seg: Int = 64, v0: CGFloat = 0, v1: CGFloat = 1) -> SCNGeometry {
        var v: [SCNVector3] = [], t: [CGPoint] = [], idx: [Int32] = []
        for i in 0...seg {
            let u = Float(i) / Float(seg), a = (u - 0.5) * w / r
            let x = curved ? CGFloat(r * sin(a)) : CGFloat((u - 0.5) * w), z = curved ? CGFloat(r - r * cos(a)) : 0
            v += [SCNVector3(x, CGFloat(h / 2), z), SCNVector3(x, CGFloat(-h / 2), z)]
            t += [CGPoint(x: CGFloat(u), y: v0), CGPoint(x: CGFloat(u), y: v1)]
        }
        for i in 0..<Int32(seg) { let a = i * 2; idx += [a, a + 1, a + 2, a + 2, a + 1, a + 3] }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: v), SCNGeometrySource(textureCoordinates: t)],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        g.firstMaterial?.lightingModel = .constant; g.firstMaterial?.isDoubleSided = true
        return g
    }

    /// Meters per dashboard-canvas pixel at the current radius (constant angular size).
    var metersPerPx: Float { 2.2 / Float(Dashboard.W) * radius / 1.3 }   // ~85° wide, like SteamVR

    func setCurved(_ on: Bool) {
        guard on != Compositor.curved else { return }
        Compositor.curved = on
        let r = radius; radius = 0; setRadius(r)             // rebuild every panel
        theater.geometry = nil; theaterAspect = 0
    }
    func setRadius(_ r: Float) {
        guard r != radius else { return }
        radius = r
        let m = metersPerPx, w = Float(Dashboard.W) * m, h = Float(Dashboard.H) * m, sp = Compositor.split, sp2 = Compositor.split2
        let old = panel.geometry?.firstMaterial?.diffuse.contents
        panel.geometry = Compositor.bent(w: w, h: h * sp, r: r, v0: 0, v1: CGFloat(sp))
        dockPanel.geometry = Compositor.bent(w: w, h: h * (sp2 - sp), r: r, v0: CGFloat(sp), v1: CGFloat(sp2))
        kbPanel.geometry = Compositor.bent(w: w, h: h * (1 - sp2), r: r, v0: CGFloat(sp2), v1: 1)
        for n in [panel, dockPanel, kbPanel] {   // the menu texture has transparent gaps around the window, bars and dock
            guard let mat = n.geometry?.firstMaterial else { continue }
            mat.diffuse.contents = old; mat.blendMode = .alpha; mat.writesToDepthBuffer = false
            mat.diffuse.mipFilter = .linear; mat.diffuse.maxAnisotropy = 16   // readable text when the panel is far/small
            n.renderingOrder = 10
        }
        screen.renderingOrder = 11
        screen.geometry = nil
        resetLayout()
    }
    /// Window above, dock below, exactly as laid out on the canvas.
    private func resetLayout() {
        let m = metersPerPx
        win.simdTransform = matrix_identity_float4x4; dockNode.simdTransform = matrix_identity_float4x4; kbNode.simdTransform = matrix_identity_float4x4
        win.simdPosition = SIMD3(0, 0.12, 0)
        win.simdScale = SIMD3(repeating: 0.78)               // Quest-sized window (~60° wide)
        // dock: chest height, a little closer, tilted up toward the eyes (dock art sits at canvas y ~1124 of its 990-1262 part)
        let winBottom = 0.12 - 0.78 * Float(Dashboard.SPLIT) * m / 2
        dockNode.simdPosition = SIMD3(0, winBottom - 0.2, 0.3)
        dockNode.simdEulerAngles = SIMD3(-0.35, 0, 0)
        dockNode.simdScale = SIMD3(repeating: 0.78)
        // keyboard: just below the dock and nearer the hands, tilted like a desk
        kbNode.simdPosition = SIMD3(0, winBottom - 0.52, 0.55)
        kbNode.simdEulerAngles = SIMD3(-0.7, 0, 0)
        kbNode.simdScale = SIMD3(repeating: 0.62)
    }
    func setDashboard(_ tex: MTLTexture?) {
        for n in [panel, dockPanel, kbPanel] { n.geometry?.firstMaterial?.diffuse.contents = tex }
    }
    // MARK: live 3D controller for the welcome tour
    // The real left-controller mesh floats in front of the tour window. On each step it turns and slides so the input
    // being taught faces you, the input fades in blue, then it presses itself in a loop (trigger/grip/buttons) or rocks
    // (thumbstick) until the step changes. Press poses come from the WebXR assets' *_pressed_min/max nodes.
    private let tourRoot = SCNNode()
    private var tourCtl: SCNNode?, tourModel: HeadsetModel?, tourPart = "", tourStart: CFTimeInterval = 0
    private var tourFrom = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), tourTo = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    private var tourPanFrom = SIMD3<Float>(0, 0, 0), tourPanTo = SIMD3<Float>(0, 0, 0), tourCenter = SIMD3<Float>(0, 0, 0)
    private var tourMats: [SCNMaterial] = []
    private static let tourParts: [String: (mesh: [String], anim: String)] = [
        "trigger": (["trigger"], "xr_standard_trigger_pressed"), "grip": (["squeeze"], "xr_standard_squeeze_pressed"),
        "stick": (["thumbstick"], "xr_standard_thumbstick_yaxis_pressed"), "buttons": (["x_button", "y_button"], "x_button_pressed"),
    ]
    /// nil hides it. Call every dashboard redraw; it only animates when the step's part changes.
    func setTourController(_ model: HeadsetModel?, part: String?) {
        guard let model, let part else { tourRoot.isHidden = true; return }
        if tourRoot.parent == nil { winContent.addChildNode(tourRoot) }
        tourRoot.isHidden = false
        // stage: left part of the tour window (canvas box x 194..754, y 132..692), a little in front of the panel
        let m = metersPerPx, cx = (474 - Float(Dashboard.W) / 2) * m, cy = (Float(Dashboard.SPLIT) / 2 - 412) * m
        let z: Float = Compositor.curved ? radius - radius * cos(cx / radius) + 0.16 : 0.16
        tourRoot.simdPosition = SIMD3(Compositor.curved ? radius * sin(cx / radius) : cx, cy, z)
        tourRoot.simdEulerAngles = SIMD3(0, Compositor.curved ? -cx / radius : 0, 0)
        if tourModel != model {
            tourCtl?.removeFromParentNode()
            let n = ControllerModels.build(model, hand: 0)
            n.enumerateHierarchy { c, _ in   // private copies: tinting must not touch the hands' shared materials
                if let g = c.geometry?.copy() as? SCNGeometry { g.materials = g.materials.map { $0.copy() as! SCNMaterial }; c.geometry = g }
            }
            let (lo, hi) = n.boundingBox
            tourCenter = SIMD3(Float(lo.x + hi.x) / 2, Float(lo.y + hi.y) / 2, Float(lo.z + hi.z) / 2)
            let size = simd_length(SIMD3(Float(hi.x - lo.x), Float(hi.y - lo.y), Float(hi.z - lo.z)))
            n.simdScale = SIMD3(repeating: 0.8 / max(size, 0.01))   // ~80 cm across on the stage
            tourRoot.addChildNode(n); tourCtl = n; tourModel = model; tourPart = "-"
        }
        guard part != tourPart, let n = tourCtl else { return }
        // new step: from the current pose, turn the part toward the viewer (+z) and slide it to the centre of the stage
        tourFrom = n.simdOrientation; tourPanFrom = n.simdPosition
        tourMats.forEach { $0.emission.contents = NSColor.black }
        tourMats = []
        // hand-picked viewpoints (model space, toward the camera) that show each input; a fixed "up" so it never rolls
        let views: [String: (dir: SIMD3<Float>, up: SIMD3<Float>)] = [
            "none": (SIMD3(0.7, -0.3, -0.6), SIMD3(0, 1, 0)), "trigger": (SIMD3(0.2, -0.65, -0.75), SIMD3(0, 1, 0)),
            "grip": (SIMD3(0.95, -0.15, -0.35), SIMD3(0, 1, 0)), "stick": (SIMD3(-0.35, 0.85, 0.45), SIMD3(0, 0, -1)),
            "buttons": (SIMD3(-0.35, 0.85, 0.45), SIMD3(0, 0, -1))]
        let v = views[part] ?? views["none"]!
        let f = simd_normalize(v.dir), r = simd_normalize(simd_cross(v.up, f)), u = simd_cross(f, r)
        let target = simd_quatf(simd_float3x3(columns: (r, u, f)).transpose)   // maps the viewpoint onto the viewer (+z)
        var focus = tourCenter
        if let p = Compositor.tourParts[part] {
            let nodes = p.mesh.compactMap { n.childNode(withName: $0, recursively: true) }
            if let first = nodes.first {
                let (a, b) = first.boundingBox
                focus = n.simdConvertPosition(first.simdConvertPosition(SIMD3(Float(a.x + b.x) / 2, Float(a.y + b.y) / 2, Float(a.z + b.z) / 2), to: nil), from: nil)
            }
            nodes.forEach { $0.enumerateHierarchy { c, _ in tourMats += c.geometry?.materials ?? [] } }
        }
        tourTo = target
        tourPanTo = -target.act((focus - tourCenter) * 0.5 + tourCenter) * n.simdScale.x
        tourPart = part; tourStart = CACurrentMediaTime()
    }
    private func animateTour() {
        guard !tourRoot.isHidden, let n = tourCtl else { return }
        let t = Float(CACurrentMediaTime() - tourStart)
        let e = min(1, t / 0.9), ease = e * e * (3 - 2 * e)       // 0.9 s pan
        n.simdOrientation = simd_slerp(tourFrom, tourTo, ease)
        n.simdPosition = tourPanFrom + (tourPanTo - tourPanFrom) * ease
        let glow = CGFloat(min(1, max(0, (t - 0.9) / 0.5)))       // then the highlight fades in
        tourMats.forEach { $0.emission.contents = NSColor(red: 0.08 * glow, green: 0.4 * glow, blue: 1.0 * glow, alpha: 1) }
        guard let anim = Compositor.tourParts[tourPart]?.anim,
              let v = n.childNode(withName: anim + "_value", recursively: true),
              let lo = n.childNode(withName: anim + "_min", recursively: true),
              let hi = n.childNode(withName: anim + "_max", recursively: true) else { return }
        // then it presses itself: 1.2 s cycle once the highlight is in (thumbstick: rocks between both ends)
        let phase = max(0, t - 1.4)
        var k = Float(0.5 - 0.5 * cos(Double(phase) * 2 * .pi / 1.2))
        if tourPart == "stick" { k = Float(0.5 + 0.5 * sin(Double(phase) * 2 * .pi / 1.6)) }
        v.simdOrientation = simd_slerp(lo.simdOrientation, hi.simdOrientation, k)
        v.simdPosition = lo.simdPosition + (hi.simdPosition - lo.simdPosition) * k
    }

    /// First-run tour: no Universal Menu.
    func setDockHidden(_ hidden: Bool) { dockNode.isHidden = hidden }
    func setWindowHidden(_ hidden: Bool) { win.isHidden = hidden }

    // MARK: space backdrop for the first-run tour; fades away to reveal the home environment
    private let space = SCNNode()
    private var spaceFade: (from: CGFloat, start: CFTimeInterval)?
    /// on: starfield all around; off (animated): it fades out over 3 s, showing the home environment behind it.
    func setSpace(_ on: Bool) {
        if space.geometry == nil {
            let g = SCNSphere(radius: 100); g.segmentCount = 96   // well inside the 300 m far plane, or the home leaks through
            let m = g.firstMaterial!; m.diffuse.contents = Compositor.starfield(); m.lightingModel = .constant
            m.cullMode = .front; m.writesToDepthBuffer = false; m.readsFromDepthBuffer = false
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(-1, 1, 1); m.diffuse.wrapS = .repeat   // seen from inside
            space.geometry = g; space.renderingOrder = -150; space.isHidden = true
            scene.rootNode.addChildNode(space)
        }
        if on { spaceFade = nil; space.opacity = 1; space.isHidden = false }
        else if !space.isHidden && spaceFade == nil { spaceFade = (space.opacity, CACurrentMediaTime()) }
    }
    private func animateSpace() {
        guard let f = spaceFade else { return }
        let t = CGFloat(min(1, (CACurrentMediaTime() - f.start) / 3))
        space.opacity = f.from * (1 - t * t * (3 - 2 * t))   // smoothstep
        if t >= 1 { space.isHidden = true; spaceFade = nil }
    }
    /// Procedural deep-space panorama: dark blue-black sky, two soft nebulae, a few thousand stars.
    static func starfield() -> CGImage {
        let w = 4096, h = 2048
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0.008, green: 0.012, blue: 0.035, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (x, y, r, col) in [(1300.0, 1150.0, 900.0, (0.35, 0.18, 0.55)), (3100.0, 800.0, 750.0, (0.1, 0.28, 0.5)), (2200.0, 1500.0, 500.0, (0.4, 0.15, 0.3))] {
            let g = CGGradient(colorsSpace: nil, colors: [CGColor(srgbRed: col.0, green: col.1, blue: col.2, alpha: 0.22), CGColor(srgbRed: col.0, green: col.1, blue: col.2, alpha: 0)] as CFArray, locations: [0, 1])!
            c.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
        }
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        for _ in 0..<5000 {
            let x = rnd() * Double(w), y = rnd() * Double(h), b = pow(rnd(), 3)
            let r = 0.6 + b * 2.6, tint = rnd()
            c.setFillColor(CGColor(srgbRed: 0.85 + 0.15 * tint, green: 0.88, blue: 1 - 0.15 * tint, alpha: 0.35 + 0.65 * b))
            c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        return c.makeImage()!
    }

    /// Show/hide the pop-up keyboard panel (it rises in with the same ease as a window).
    func setKeyboard(_ open: Bool) {
        guard kbNode.isHidden == open else { return }
        kbNode.isHidden = !open
        if open { kbPop = CACurrentMediaTime() }
    }
    private var kbPop: CFTimeInterval = 0

    // MARK: home environments (CC0 panoramas) or the purple void
    private var envName = ""
    func setEnvironment(_ name: String) {
        guard name != envName else { return }
        envName = name
        var contents: Any = Compositor.sky(), isVoid = true   // (`is CGImage` is always true for CF types, so track it)
        if let f = Dashboard.envFile(name), let url = Bundle.main.url(forResource: f, withExtension: "jpg", subdirectory: "environments"),
           let img = NSImage(contentsOf: url) { contents = img; isVoid = false }
        if scene.background.contents != nil { scene.background.contents = contents }   // nil = a game is behind the menu
        skyContents = contents
        voidEnv = isVoid
        grid.isHidden = !gridOn || !isVoid || scene.background.contents == nil
    }
    private var voidEnv = true
    private lazy var dashQueue = device.makeCommandQueue()

    private var dashTex: [MTLTexture] = [], dashIdx = 0   // dashboard queue only
    /// Copies the dashboard bitmap into one of two textures (off the render queue) and returns it.
    func uploadDashboard(_ ctx: CGContext) -> MTLTexture? {
        if dashTex.isEmpty {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: ctx.width, height: ctx.height, mipmapped: true)
            d.usage = .shaderRead; d.storageMode = .shared
            dashTex = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
        }
        guard let data = ctx.data, dashTex.count == 2 else { return nil }
        dashIdx ^= 1
        dashTex[dashIdx].replace(region: MTLRegionMake2D(0, 0, ctx.width, ctx.height), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        if let cb = dashQueue?.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: dashTex[dashIdx]); blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        }
        return dashTex[dashIdx]
    }
    private var gridOn = true
    func setGrid(_ on: Bool) { gridOn = on; grid.isHidden = !on || !voidEnv || scene.background.contents == nil }

    // MARK: grab bars: the window or the dock follows the pointer ray while the trigger is held
    private var grabPart = Part.window, grabDist0: Float = 1, grabScale: Float = 1, grabLocal = SIMD3<Float>(0, 0, 0)
    private var handDist0: Float = 0, grabPush: Float = 0, grabDist: Float = 1, atStop = false
    private var carried: [(SCNNode, simd_float4x4)] = []   // dragging the dock carries the window + keyboard along
    private func node(_ p: Part) -> SCNNode { p == .window ? win : p == .dock ? dockNode : kbNode }
    private func horizontal(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_length(SIMD2(a.x - b.x, a.z - b.z)) }
    /// Start dragging `part` at the ray's current hit.
    func beginGrab(_ part: Part, _ aim: VR4Pose, dist: Float, head: VR4Pose) {
        let (o, d) = ray(aim), n = node(part)
        grabPart = part; grabDist0 = dist; grabDist = dist; grabScale = n.simdScale.x; grabPush = 0; atStop = false
        handDist0 = horizontal(o, SIMD3(head.px, head.py, head.pz))
        grabLocal = n.simdConvertPosition(o + d * dist, from: nil)
        carried = part == .dock ? [win, kbNode].map { ($0, n.simdWorldTransform.inverse * $0.simdWorldTransform) } : []
    }
    /// The grabbed point stays on the ray, upright and facing the head. Moving the hand forward/back (x3) or pushing the
    /// stick sends it further or nearer; the window grows as it recedes (sqrt, so it still visibly moves back), then stops
    /// at a limit and stays there when released. Returns true the moment it hits a stop (haptic + sound cue).
    @discardableResult
    func updateGrab(_ aim: VR4Pose, head: VR4Pose, push: Float) -> Bool {
        let (o, d) = ray(aim), n = node(grabPart), h = SIMD3(head.px, head.py, head.pz)
        grabPush += push
        let maxD: Float = grabPart == .window ? 3 : 2, want = grabDist0 + grabPush + 3 * (horizontal(o, h) - handDist0)
        grabDist = min(maxD, max(0.45, want))
        let hit = (want >= maxD || want <= 0.45) && !atStop
        atStop = want >= maxD || want <= 0.45
        if atStop { grabPush = grabDist - grabDist0 - 3 * (horizontal(o, h) - handDist0) }   // no wind-up past the stop
        let p = o + d * grabDist, v = h - p
        let q = simd_quatf(angle: atan2(v.x, v.z), axis: SIMD3(0, 1, 0))
        // Upright near eye level; once dragged well above or below the head it pitches to face you (smoothly, from ~20 deg).
        let elev = atan2(v.y, simd_length(SIMD2(v.x, v.z)))
        let blend = min(1, max(0, (abs(elev) - 0.35) / 0.3))
        let base: Float = grabPart == .dock ? -0.35 : grabPart == .keyboard ? -0.7 : 0
        let tilt = simd_quatf(angle: base + (-elev - base) * blend, axis: SIMD3(1, 0, 0))
        let sc = grabPart == .window ? min(2.2, max(0.45, grabScale * (grabDist / grabDist0).squareRoot())) : grabScale
        n.simdScale = SIMD3(repeating: sc)
        n.simdWorldOrientation = q * tilt
        n.simdWorldPosition = p - (q * tilt).act(grabLocal * sc)
        for (c, rel) in carried { c.simdWorldTransform = n.simdWorldTransform * rel }
        return hit
    }

    /// Thumbstick left/right on the Mac desktop: resize the window (bigger = more readable desktop text).
    func zoomWindow(_ d: Float) {
        let s = min(2.2, max(0.5, win.simdScale.x * (1 + d)))
        win.simdScale = SIMD3(repeating: s)
    }

    // MARK: open/close motion (Quest Universal Menu): a quick fade with a tiny settle, no flying across the room
    private var popStart: CFTimeInterval = 0, popDock = false, closeStart: CFTimeInterval = 0, shown = true
    func pop(dock: Bool) { popStart = CACurrentMediaTime(); popDock = dock }
    /// Show/hide the whole shell; hiding fades it out quickly (inverse of opening) before it disappears.
    func setDashVisible(_ on: Bool) {
        if on { shown = true; dash.isHidden = false; dash.opacity = 1 }
        else if shown { shown = false; closeStart = CACurrentMediaTime() }
    }
    private func animate() {
        let t = Float(min(1, (CACurrentMediaTime() - popStart) / 0.16)), e = 1 - pow(1 - t, 3)   // ease-out cubic, 160 ms
        winContent.simdPosition = SIMD3(0, -0.025 * (1 - e), 0)
        winContent.simdScale = SIMD3(repeating: 0.97 + 0.03 * e)
        winContent.opacity = CGFloat(e)
        let de = popDock ? e : 1
        dockPanel.simdPosition = SIMD3(0, -0.015 * (1 - de), 0)
        dockPanel.simdScale = SIMD3(repeating: 0.98 + 0.02 * de)
        dockPanel.opacity = CGFloat(de)
        let ke = 1 - pow(1 - Float(min(1, (CACurrentMediaTime() - kbPop) / 0.16)), 3)
        kbPanel.simdPosition = SIMD3(0, -0.02 * (1 - ke), 0); kbPanel.opacity = CGFloat(ke)
        if !shown && !dash.isHidden {   // close: 120 ms fade
            let c = min(1, (CACurrentMediaTime() - closeStart) / 0.12)
            dash.opacity = CGFloat(1 - c)
            if c >= 1 { dash.isHidden = true; dash.opacity = 1 }
        }
    }

    private func ray(_ aim: VR4Pose) -> (SIMD3<Float>, SIMD3<Float>) {
        (SIMD3(aim.px, aim.py, aim.pz), simd_quatf(ix: aim.qx, iy: aim.qy, iz: aim.qz, r: aim.qw).act(SIMD3<Float>(0, 0, -1)))
    }

    /// Put the dashboard at `radius` in front of the head, facing it, slightly below eye level.
    func place(head: VR4Pose) {
        let q = simd_quatf(ix: head.qx, iy: head.qy, iz: head.qz, r: head.qw)
        let f = q.act(SIMD3<Float>(0, 0, -1))
        let yaw = atan2(-f.x, -f.z)
        dash.simdPosition = SIMD3(head.px - sin(yaw) * radius, head.py - 0.2, head.pz - cos(yaw) * radius)
        dash.simdEulerAngles = SIMD3(0, yaw, 0)
        resetLayout()
    }

    // MARK: desktop screen inside the dashboard
    private var screenRect = CGRect.zero
    /// Live Mac screen laid exactly over `rect` (dashboard canvas px, horizontally centred) so pointer uv maps 1:1.
    private var screenMip: MTLTexture?, lastScreenPB: CVPixelBuffer?
    func setScreen(_ pb: CVPixelBuffer?, rect: CGRect) {
        guard let pb, let tex = mipmapped(pb) else { screen.isHidden = true; return }
        if rect != screenRect || screen.geometry == nil {
            screenRect = rect
            let m = metersPerPx
            screen.geometry = Compositor.bent(w: Float(rect.width) * m, h: Float(rect.height) * m, r: radius)
            screen.position = SCNVector3(0, CGFloat((Float(Dashboard.SPLIT) / 2 - Float(rect.midY)) * m), 0.004)
        }
        if let m = screen.geometry?.firstMaterial {
            m.diffuse.contents = tex; m.diffuse.mipFilter = .linear; m.diffuse.maxAnisotropy = 16
        }
        screen.isHidden = false
    }
    /// Retina desktop shown much smaller than its pixels: without mipmaps text aliases into mush, so each new capture
    /// is copied into a mipmapped texture (same queue as rendering, so it's ready before the next eye render).
    private func mipmapped(_ pb: CVPixelBuffer) -> MTLTexture? {
        guard let src = texture(pb, .bgra8Unorm_srgb) else { return nil }
        if pb !== lastScreenPB {
            lastScreenPB = pb
            if screenMip?.width != src.width || screenMip?.height != src.height {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: src.width, height: src.height, mipmapped: true)
                d.usage = .shaderRead; d.storageMode = .private
                screenMip = device.makeTexture(descriptor: d)
            }
            if let m = screenMip, let cb = cq.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, to: m, destinationSlice: 0, destinationLevel: 0, sliceCount: 1, levelCount: 1)
                blit.generateMipmaps(for: m); blit.endEncoding(); cb.commit()
            }
        }
        return screenMip
    }

    // MARK: theater mode: flatscreen games / the Mac on a big curved screen in a dark room
    private let theater = SCNNode()
    private var theaterAspect: CGFloat = 0
    /// nil hides the theater (and restores the home environment). `head` re-centres the screen in front of you.
    func setTheater(_ pb: CVPixelBuffer?, head: VR4Pose?) {
        if theater.parent == nil { scene.rootNode.addChildNode(theater); theater.isHidden = true }
        guard let pb, let tex = mipmapped(pb) else {
            if !theater.isHidden { theater.isHidden = true; let e = envName; envName = ""; setEnvironment(e) }
            return
        }
        let aspect = CGFloat(CVPixelBufferGetWidth(pb)) / CGFloat(max(1, CVPixelBufferGetHeight(pb)))
        if aspect != theaterAspect || theater.geometry == nil {
            theaterAspect = aspect
            theater.geometry = Compositor.bent(w: 6.4, h: 6.4 / Float(aspect), r: 5, seg: 96)
            theater.geometry?.firstMaterial?.lightingModel = .constant
        }
        if theater.isHidden || head != nil, let head {   // entering: put the screen 5 m ahead at eye height
            let f = simd_quatf(ix: head.qx, iy: head.qy, iz: head.qz, r: head.qw).act(SIMD3<Float>(0, 0, -1)), yaw = atan2(-f.x, -f.z)
            theater.simdPosition = SIMD3(head.px - sin(yaw) * 5, head.py + 0.3, head.pz - cos(yaw) * 5)
            theater.simdEulerAngles = SIMD3(0, yaw, 0)
        }
        if theater.isHidden { theater.isHidden = false; scene.background.contents = NSColor(white: 0.015, alpha: 1); grid.isHidden = true }
        if let m = theater.geometry?.firstMaterial { m.diffuse.contents = tex; m.diffuse.mipFilter = .linear; m.diffuse.maxAnisotropy = 16 }
    }
    /// Pointer on the theater screen -> normalized point on the Mac display (0-1, top-left) + distance.
    func theaterHit(_ aim: VR4Pose) -> (uv: CGPoint, dist: Float)? {
        guard !theater.isHidden, theater.geometry != nil else { return nil }
        let (o, d) = ray(aim)
        let a = theater.simdConvertPosition(o, from: nil), b = theater.simdConvertPosition(o + d * 30, from: nil)
        guard let h = theater.hitTestWithSegment(from: SCNVector3(a), to: SCNVector3(b), options: [SCNHitTestOption.backFaceCulling.rawValue: false]).first
        else { return nil }
        return (h.textureCoordinates(withMappingChannel: 0), simd_distance(o, h.simdWorldCoordinates))
    }

    // MARK: game behind the menu
    private var backdrop: [SCNNode] = []
    private var backdropPB: CVPixelBuffer?   // keeps the pool from recycling the frame while it is on screen
    private var skyContents: Any?
    /// Shows the running game (dimmed) behind the menu: each eye's half of `pb` on a quad placed in that eye's
    /// rendered frustum, so turning the head reveals it world-locked instead of head-locked. nil = back to the home void.
    func setGameBackdrop(_ pb: CVPixelBuffer?, poses: [VR4Pose], fovs: [VR4Fov]) {
        if backdrop.isEmpty {
            for i in 0..<2 {
                let n = SCNNode(geometry: SCNPlane(width: 1, height: 1))
                let m = n.geometry!.firstMaterial!
                m.lightingModel = .constant; m.isDoubleSided = true; m.writesToDepthBuffer = false; m.readsFromDepthBuffer = false
                m.multiply.contents = NSColor(white: 0.55, alpha: 1)   // dim the game under the menu
                n.renderingOrder = -100; n.categoryBitMask = 1 << (i + 2)
                scene.rootNode.addChildNode(n); backdrop.append(n)
                eyes[i].camera!.categoryBitMask = ~(1 << ((1 - i) + 2))   // each eye sees only its own half
            }
            skyContents = scene.background.contents
        }
        guard let pb, poses.count == 2, fovs.count == 2, let tex = texture(pb, .bgra8Unorm_srgb) else {
            backdrop.forEach { $0.isHidden = true; $0.geometry?.firstMaterial?.diffuse.contents = nil }; backdropPB = nil
            if scene.background.contents == nil { scene.background.contents = skyContents; grid.isHidden = !gridOn }
            return
        }
        backdropPB = pb
        scene.background.contents = nil; grid.isHidden = true
        let dist: Float = 20
        for i in 0..<2 {
            let n = backdrop[i], f = fovs[i], p = poses[i]
            let l = tan(f.left) * dist, r = tan(f.right) * dist, u = tan(f.up) * dist, d = tan(f.down) * dist
            let q = simd_quatf(ix: p.qx, iy: p.qy, iz: p.qz, r: p.qw)
            n.simdOrientation = q
            n.simdPosition = SIMD3(p.px, p.py, p.pz) + q.act(SIMD3((l + r) / 2, (u + d) / 2, -dist))
            n.simdScale = SIMD3(r - l, u - d, 1)
            let m = n.geometry!.firstMaterial!
            m.diffuse.contents = tex
            m.diffuse.contentsTransform = SCNMatrix4Translate(SCNMatrix4MakeScale(0.5, 1, 1), CGFloat(i) * 0.5, 0, 0)
            n.isHidden = false
        }
    }

    // MARK: input
    /// Ray from a hand's aim pose against the dashboard panel -> texture uv (origin top-left) + distance.
    /// Nearest hit on the window or dock panel. Their texture coords are already canvas uv (origin top-left).
    func hit(_ aim: VR4Pose, solid: (CGPoint) -> Bool) -> (uv: CGPoint, dist: Float)? {
        guard !dash.isHidden, panel.geometry != nil else { return nil }
        let (o, d) = ray(aim)
        var best: (uv: CGPoint, dist: Float)?
        for n in [panel, dockPanel, kbPanel] where !(n === kbPanel && kbNode.isHidden) {
            let a = n.simdConvertPosition(o, from: nil), b = n.simdConvertPosition(o + d * 10, from: nil)
            for h in n.hitTestWithSegment(from: SCNVector3(a), to: SCNVector3(b), options: [SCNHitTestOption.backFaceCulling.rawValue: false]) {
                let dist = simd_distance(o, h.simdWorldCoordinates), uv = h.textureCoordinates(withMappingChannel: 0)
                if solid(uv), dist < best?.dist ?? .infinity { best = (uv, dist) }   // lasers pass through transparent gaps
            }
        }
        return best
    }

    var lasersAlways = false   // theater: lasers drive the Mac even with the menu closed
    func updateHands(_ t: VR4Tracking, rays: [Float?]) {
        let hs = [t.hand.0, t.hand.1]
        for (i, h) in hs.enumerated() {
            let valid = h.flags & UInt32(VR4_HAND_POSE_VALID) != 0
            let n = hands[i]
            n.grip.isHidden = !valid; n.aim.isHidden = !valid || (dash.isHidden && !lasersAlways)
            n.grip.simdPosition = SIMD3(h.grip.px, h.grip.py, h.grip.pz); n.grip.simdOrientation = simd_quatf(ix: h.grip.qx, iy: h.grip.qy, iz: h.grip.qz, r: h.grip.qw)
            if valid { rigs[i].update(h); handModels[i]?.update(h, targets: rigs[i].targets()) }
            n.aim.simdPosition = SIMD3(h.aim.px, h.aim.py, h.aim.pz); n.aim.simdOrientation = simd_quatf(ix: h.aim.qx, iy: h.aim.qy, iz: h.aim.qz, r: h.aim.qw)
            let len = rays[i] ?? 3
            n.laser.scale = SCNVector3(1, CGFloat(len), 1)
            n.dot.isHidden = n.aim.isHidden || rays[i] == nil
            n.dot.simdPosition = n.aim.simdConvertPosition(SIMD3(0, 0, -len), to: nil)
        }
    }

    // MARK: rendering
    private func texture(_ pb: CVPixelBuffer, _ fmt: MTLPixelFormat) -> MTLTexture? {
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &t)
        return t.flatMap(CVMetalTextureGetTexture)
    }
    func pixelBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if poolSize != (w, h) {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool); poolSize = (w, h)
        }
        var pb: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
        return pb
    }

    static func projection(_ f: VR4Fov, near n: Float = 0.05, far: Float = 300) -> SCNMatrix4 {
        let l = tan(f.left) * n, r = tan(f.right) * n, u = tan(f.up) * n, d = tan(f.down) * n
        var m = SCNMatrix4()   // column-vector GL projection, transposed into SceneKit's row-vector layout
        m.m11 = CGFloat(2 * n / (r - l)); m.m22 = CGFloat(2 * n / (u - d))
        m.m31 = CGFloat((r + l) / (r - l)); m.m32 = CGFloat((u + d) / (u - d))
        m.m33 = CGFloat(-(far + n) / (far - n)); m.m34 = -1
        m.m43 = CGFloat(-2 * far * n / (far - n))
        return m
    }

    func render(_ t: VR4Tracking, eyeW: Int, eyeH: Int) -> CVPixelBuffer? {
        guard let pb = pixelBuffer(eyeW * 2, eyeH), let color = texture(pb, .bgra8Unorm_srgb) else { return nil }
        if depth?.width != eyeW * 2 || depth?.height != eyeH {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: eyeW * 2, height: eyeH, mipmapped: false)
            d.usage = .renderTarget; d.storageMode = .private
            depth = device.makeTexture(descriptor: d)
        }
        guard let cb = cq.makeCommandBuffer() else { return nil }
        animate(); animateSpace(); animateTour()
        for (i, e) in [t.eye.0, t.eye.1].enumerated() {
            eyes[i].simdPosition = SIMD3(e.pose.px, e.pose.py, e.pose.pz)
            eyes[i].simdOrientation = simd_quatf(ix: e.pose.qx, iy: e.pose.qy, iz: e.pose.qz, r: e.pose.qw)
            eyes[i].camera!.projectionTransform = Compositor.projection(e.fov)
            renderer.pointOfView = eyes[i]
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = color
            pd.colorAttachments[0].loadAction = i == 0 ? .clear : .load
            pd.colorAttachments[0].storeAction = .store
            pd.depthAttachment.texture = depth; pd.depthAttachment.loadAction = .clear; pd.depthAttachment.clearDepth = 1; pd.depthAttachment.storeAction = .dontCare
            renderer.render(atTime: CACurrentMediaTime(), viewport: CGRect(x: i * eyeW, y: 0, width: eyeW, height: eyeH), commandBuffer: cb, passDescriptor: pd)
        }
        cb.commit(); cb.waitUntilCompleted()
        return pb
    }

    private var gamePool: CVPixelBufferPool?, gamePoolSize = (0, 0)
    private var scaler: VTPixelTransferSession?
    /// Copy a game frame out of shared memory into an encoder-ready buffer, scaling (GPU) if the game rendered at another size.
    func copyFrame(_ src: UnsafeRawPointer, w: Int, h: Int, outW: Int, outH: Int, rgba: Bool = false) -> CVPixelBuffer? {
        if gamePoolSize != (w, h) {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &gamePool); gamePoolSize = (w, h)
        }
        var pb: CVPixelBuffer?
        guard let gamePool, CVPixelBufferPoolCreatePixelBuffer(nil, gamePool, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let dst = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<h { memcpy(dst + y * stride, src + y * w * 4, w * 4) }
        if rgba {   // RGBA game swapchain -> BGRA, NEON-fast here instead of a per-pixel loop inside the game
            var buf = vImage_Buffer(data: dst, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: stride)
            let map: [UInt8] = [2, 1, 0, 3]
            vImagePermuteChannels_ARGB8888(&buf, &buf, map, vImage_Flags(kvImageNoFlags))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        if (w, h) == (outW, outH) { return pb }
        if scaler == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &scaler) }
        guard let scaler, let out = pixelBuffer(outW, outH), VTPixelTransferSessionTransferImage(scaler, from: pb, to: out) == noErr else { return nil }
        return out
    }
}

/// Mac desktop capture for the dashboard's desktop tab.
final class DesktopCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let lock = NSLock()
    private var _latest: CVPixelBuffer?
    var latest: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return _latest }
    var running: Bool { stream != nil }

    private var starting = false, generation = 0
    func start() {
        guard stream == nil, !starting else { return }
        starting = true; generation += 1
        let gen = generation
        Task {
            defer { DispatchQueue.main.async { self.starting = false } }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first else { return }
            let cfg = SCStreamConfiguration()
            // capture in pixels (Retina), not points, capped at 4K wide: the panel's mipmaps need the real detail
            let backing = Double(NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }?.backingScaleFactor ?? 2)
            let scale = min(backing, 3840 / Double(display.width))
            cfg.width = Int(Double(display.width) * scale) / 2 * 2; cfg.height = Int(Double(display.height) * scale) / 2 * 2
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
            try? s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "vr4.capture"))
            do {
                try await s.startCapture()
                if gen == generation { stream = s } else { try? await s.stopCapture() }   // stopped while starting
            } catch { NSLog("screen capture failed: \(error)") }
        }
    }
    func stop() {
        generation += 1
        stream?.stopCapture { _ in }
        stream = nil
        lock.lock(); _latest = nil; lock.unlock()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = sb.imageBuffer else { return }
        lock.lock(); _latest = pb; lock.unlock()
    }
}
