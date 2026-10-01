import Foundation
import SceneKit
import ModelIO
import SceneKit.ModelIO
import AppKit
import Metal
import ImageIO

/// Which Quest generation is connected. Real 3D differences per model:
/// Quest 1/2 Touch = tracking ring on top; Quest 3 Touch Plus = ringless.
enum HeadsetModel: Int {
    case quest1, quest2, quest3, steamFrame

    /// HELLO "device" is free-form (Build.MODEL on the Quest). Match robustly.
    static func detect(device: String) -> HeadsetModel {
        let d = device.lowercased()
        if d.contains("frame") || d.contains("valve") { return .steamFrame }   // Valve Steam Frame (runs the same APK)
        if d.contains("quest 3") || d.contains("eureka") || d.contains("stardust") { return .quest3 }
        if d.contains("monterey") || d.contains("quest 1") || d == "quest" { return .quest1 }
        return .quest2   // Quest 2 ("hollywood") is the common case; also the safe default
    }

    var label: String { ["Quest 1", "Quest 2", "Quest 3", "Steam Frame"][rawValue] }
    /// Mesh to draw: the Frame's controllers emulate Touch; the ringless Touch Plus shape is the closest bundled model.
    var controllerMesh: HeadsetModel { self == .steamFrame ? .quest3 : self }
}

/// Controller geometry per headset generation: the real bundled meshes, or procedural stand-ins if they fail to load.
/// Sizes in meters; +Y up, -Z forward, origin at the grip center.
enum ControllerModels {
    private static func mat(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> SCNMaterial {
        let m = SCNMaterial(); m.diffuse.contents = NSColor(red: r, green: g, blue: b, alpha: 1); m.lightingModel = .constant
        return m
    }
    private static let body = mat(0.13, 0.13, 0.14)
    private static let dark = mat(0.07, 0.07, 0.08)
    private static let accent = mat(0.16, 0.75, 0.85)
    private static let button = mat(0.75, 0.77, 0.80)

    private static func node(_ g: SCNGeometry, _ m: SCNMaterial, _ x: Float = 0, _ y: Float = 0, _ z: Float = 0) -> SCNNode {
        g.firstMaterial = m
        let n = SCNNode(geometry: g); n.position = SCNVector3(x, y, z)
        return n
    }

    /// Full controller for `hand` (0 = left, 1 = right). Buttons labeled per Oculus layout.
    /// Built from the render queue (controllers) and the dashboard queue (tour portrait); the GLB cache isn't thread-safe.
    private static let lock = NSLock()
    static func build(_ model: HeadsetModel, hand: Int) -> SCNNode {
        lock.lock(); defer { lock.unlock() }
        let model = model.controllerMesh
        if let real = ControllerGLB.node(model, hand: hand) { return real }   // bundled Meta Touch meshes (webxr-input-profiles)
        let root = SCNNode()
        let mirror: Float = hand == 0 ? 1 : -1
        // handle: capsule tilted forward like a held Touch controller
        let handle = node(SCNCapsule(capRadius: 0.016, height: 0.10), body, 0, -0.055, 0.012)
        handle.eulerAngles.x = -.pi / 9
        root.addChildNode(handle)
        // head: flattened box carrying stick + face buttons
        let head = node(SCNBox(width: 0.052, height: 0.030, length: 0.062, chamferRadius: 0.012), body, 0, 0.012, -0.008)
        root.addChildNode(head)
        // thumbstick left of the face buttons (mirrored per hand)
        let stick = SCNNode()
        stick.addChildNode(node(SCNCylinder(radius: 0.004, height: 0.014), dark, 0, 0.007, 0))
        stick.addChildNode(node(SCNSphere(radius: 0.009), dark, 0, 0.016, 0))
        stick.position = SCNVector3(-0.014 * mirror, 0.027, -0.012)
        root.addChildNode(stick)
        // A/B (right) or X/Y (left), real Oculus labels via tiny canvas textures
        for (i, t) in (hand == 0 ? ["X", "Y"] : ["A", "B"]).enumerated() {
            let b = node(SCNCylinder(radius: 0.006, height: 0.005), button, 0.013 * mirror, 0.028, -0.004 - Float(i) * 0.016)
            root.addChildNode(b)
            let tag = node(SCNPlane(width: 0.011, height: 0.011), labelMaterial(t), 0.013 * mirror, 0.0315, -0.004 - Float(i) * 0.016)
            tag.eulerAngles.x = -.pi / 2
            root.addChildNode(tag)
        }
        // index trigger + grip trigger
        root.addChildNode(node(SCNBox(width: 0.012, height: 0.026, length: 0.010, chamferRadius: 0.003), dark, 0, -0.005, -0.043))
        root.addChildNode(node(SCNBox(width: 0.014, height: 0.040, length: 0.008, chamferRadius: 0.003), dark, 0, -0.055, 0.030))
        switch model {
        case .quest1:
            // Touch v1: large thin ring arcing over the top, front IR window
            let ring = node(SCNTorus(ringRadius: 0.052, pipeRadius: 0.005), dark, 0, 0.045, -0.030)
            ring.eulerAngles.x = .pi / 2 - 0.35
            root.addChildNode(ring)
            root.addChildNode(node(SCNBox(width: 0.030, height: 0.012, length: 0.004, chamferRadius: 0.002), accent, 0, 0.020, -0.040))
        case .quest2:
            // Touch v2: tighter ring, closer to the head, teal accent ring
            let ring = node(SCNTorus(ringRadius: 0.045, pipeRadius: 0.006), accent, 0, 0.038, -0.026)
            ring.eulerAngles.x = .pi / 2 - 0.25
            root.addChildNode(ring)
            root.addChildNode(node(SCNBox(width: 0.026, height: 0.010, length: 0.004, chamferRadius: 0.002), dark, 0, 0.018, -0.038))
        case .quest3, .steamFrame:
            // Touch Plus: no ring at all; sensor window band wraps the head sides
            let band = node(SCNTorus(ringRadius: 0.030, pipeRadius: 0.004), dark, 0, 0.012, -0.008)
            band.eulerAngles.x = .pi / 2
            band.scale = SCNVector3(0.95, 1.15, 1)
            root.addChildNode(band)
            for s in [-1, 1] as [Float] {
                root.addChildNode(node(SCNSphere(radius: 0.0035), accent, s * 0.027, 0.014, -0.008))
            }
        }
        return root
    }

    private static var labelCache: [String: SCNMaterial] = [:]
    private static func labelMaterial(_ t: String) -> SCNMaterial {
        if let m = labelCache[t] { return m }
        let s = 64
        let c = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray: 0, alpha: 0)); c.fill(CGRect(x: 0, y: 0, width: s, height: s))
        let str = NSAttributedString(string: t, attributes: [.font: NSFont.boldSystemFont(ofSize: 40), .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(str)
        c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        c.textPosition = CGPoint(x: 20, y: 50)
        CTLineDraw(line, c)
        let m = SCNMaterial(); m.diffuse.contents = c.makeImage(); m.lightingModel = .constant; m.isDoubleSided = true
        labelCache[t] = m
        return m
    }
}

/// Pictures of the detected controller for the welcome tour: the real mesh, with the input being taught tinted blue.
/// Pre-rendered at build time into controllers/<profile>/tour-<part>.png (rendering inside the running app raced the
/// live scene's shared meshes); `render` is the build-time path and the fallback.
enum ControllerPortrait {
    /// Tour parts -> mesh node names in the WebXR controller assets.
    static let parts: [String: [String]] = ["none": [], "trigger": ["trigger"], "grip": ["squeeze"], "stick": ["thumbstick"],
                                            "buttons": ["x_button", "y_button"]]
    private static var cache: [String: CGImage] = [:]
    static func image(_ model: HeadsetModel, part: String) -> CGImage? {
        let key = "\(model.controllerMesh.rawValue)-\(part)"
        if let c = cache[key] { return c }
        let profile = ["oculus-touch-v2", "oculus-touch-v3", "meta-quest-touch-plus"][model.controllerMesh.rawValue]
        guard let u = Bundle.main.resourceURL?.appendingPathComponent("controllers/\(profile)/tour-\(part).png"),
              let src = CGImageSourceCreateWithURL(u as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        cache[key] = img
        return img
    }

    /// Left controller (it carries the menu button), 3/4 view showing face, trigger and grip; `part` lit in blue.
    static func render(_ model: HeadsetModel, part: String = "none", size: Int = 640, dir: SIMD3<Float> = SIMD3(0.7, -0.3, -0.6), hand: Int = 0) -> CGImage? {
        let ctl = ControllerModels.build(model, hand: hand)
        ctl.enumerateHierarchy { n, _ in   // own copies of meshes/materials (tinting must not touch the shared ones)
            if let g = n.geometry?.copy() as? SCNGeometry { g.materials = g.materials.map { $0.copy() as! SCNMaterial }; n.geometry = g }
        }
        for name in parts[part] ?? [] {
            ctl.childNode(withName: name, recursively: true)?.enumerateHierarchy { n, _ in
                n.geometry?.materials.forEach { m in
                    m.diffuse.contents = NSColor(red: 0.18, green: 0.55, blue: 1, alpha: 1); m.emission.contents = NSColor(red: 0.1, green: 0.35, blue: 0.9, alpha: 1)
                }
            }
        }
        return renderNode(ctl, size: size, dir: dir)
    }

    /// Studio render of any node (transparent background): bright soft light from above, key + rim lights.
    static func renderNode(_ ctl: SCNNode, size: Int = 640, dir: SIMD3<Float> = SIMD3(0.7, -0.3, -0.6), fill: CGFloat = 2.3) -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let scene = SCNScene()
        scene.rootNode.addChildNode(ctl)
        let env = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!   // studio light: bright above, dim below
        env.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0.15, alpha: 1), CGColor(gray: 0.95, alpha: 1)] as CFArray, locations: [0, 1])!,
                               start: .zero, end: CGPoint(x: 0, y: 32), options: [])
        scene.lightingEnvironment.contents = env.makeImage(); scene.lightingEnvironment.intensity = 1.3
        let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 750
        key.eulerAngles = SCNVector3(-0.8, 0.6, 0); scene.rootNode.addChildNode(key)
        let rim = SCNNode(); rim.light = SCNLight(); rim.light!.type = .directional; rim.light!.intensity = 450
        rim.eulerAngles = SCNVector3(0.3, .pi - 0.5, 0); scene.rootNode.addChildNode(rim)
        let (lo, hi) = ctl.boundingBox
        let center = SIMD3<Float>(Float(lo.x + hi.x) / 2, Float(lo.y + hi.y) / 2, Float(lo.z + hi.z) / 2)
        let radius = simd_length(SIMD3<Float>(Float(hi.x - lo.x), Float(hi.y - lo.y), Float(hi.z - lo.z))) / 2
        let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera!.fieldOfView = 30; cam.camera!.zNear = 0.01
        cam.simdPosition = center + simd_normalize(dir) * radius * Float(fill)
        cam.simdLook(at: center)
        scene.rootNode.addChildNode(cam)
        let r = SCNRenderer(device: device, options: nil); r.scene = scene; r.pointOfView = cam
        scene.background.contents = NSColor.clear
        _ = r.prepare(scene, shouldAbortBlock: nil)
        _ = r.snapshot(atTime: 0, with: CGSize(width: 64, height: 64), antialiasingMode: .none)
        let img = r.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// The Quest 2 headset for video renders: a CC-BY 3D scan ("Cleaned Up Oculus/Meta Quest 2 3D Scan/Model" by Krazy_Kid59,
/// thingiverse.com/thing:5971204), loaded from the STL at $VR4_HEADSET_STL, smoothed and shaded like the controllers.
enum HeadsetMesh {
    static var rotation = SCNVector3(0, 0, 0)   // orients the scan so its front faces +z
    static func quest2() -> SCNNode {
        let root = SCNNode()
        guard let path = ProcessInfo.processInfo.environment["VR4_HEADSET_STL"] else { return root }
        let asset = MDLAsset(url: URL(fileURLWithPath: path))
        let m = SCNMaterial(); m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(white: 0.86, alpha: 1); m.roughness.contents = 0.38; m.metalness.contents = 0.0
        for o in asset.childObjects(of: MDLMesh.self) {
            guard let mesh = o as? MDLMesh else { continue }
            mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.6)
            let g = SCNGeometry(mdlMesh: mesh); g.materials = [m]
            root.addChildNode(SCNNode(geometry: g))
        }
        let (lo, hi) = root.boundingBox   // centre it and size it like a real headset (~0.19 m wide)
        let size = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        let pivot = SCNNode(); pivot.addChildNode(root)
        root.position = SCNVector3(-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -(lo.z + hi.z) / 2)
        pivot.scale = SCNVector3(0.25 / size, 0.25 / size, 0.25 / size)
        let outer = SCNNode(); outer.addChildNode(pivot); pivot.eulerAngles = rotation
        return outer
    }
}
