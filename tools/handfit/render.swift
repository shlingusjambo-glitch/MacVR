import SceneKit
import AppKit
/// Renders `node` from several directions into one contact sheet (black background).
func sheet(_ node: SCNNode, _ out: String, dirs: [SIMD3<Float>], center: SIMD3<Float> = .zero, dist: Float = 0.45, size: Int = 420) {
    let scene = SCNScene(); scene.rootNode.addChildNode(node)
    scene.background.contents = NSColor(white: 0.08, alpha: 1)
    scene.lightingEnvironment.contents = Compositor_studio(); scene.lightingEnvironment.intensity = 1.6
    let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 900
    key.eulerAngles = SCNVector3(-0.9, 0.4, 0); scene.rootNode.addChildNode(key)
    let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 650; scene.rootNode.addChildNode(amb)
    let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil); r.scene = scene
    let W = size * dirs.count
    let ctx = CGContext(data: nil, width: W, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for (i, d) in dirs.enumerated() {
        let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera!.fieldOfView = 40; cam.camera!.zNear = 0.01
        cam.simdPosition = center + simd_normalize(d) * dist
        cam.simdLook(at: center, up: abs(simd_normalize(d).y) > 0.95 ? SIMD3(0, 0, -1) : SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(cam); r.pointOfView = cam
        let img = r.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
        ctx.draw(img.cgImage(forProposedRect: nil, context: nil, hints: nil)!, in: CGRect(x: i * size, y: 0, width: size, height: size))
        cam.removeFromParentNode()
    }
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}
func Compositor_studio() -> CGImage {
    let c = CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0.12, alpha: 1), CGColor(gray: 0.55, alpha: 1), CGColor(gray: 0.95, alpha: 1)] as CFArray, locations: [0, 0.5, 1])!, start: .zero, end: CGPoint(x: 0, y: 128), options: [])
    return c.makeImage()!
}
func axis(_ d: SIMD3<Float>, _ c: NSColor) -> SCNNode {
    let n = SCNNode(geometry: SCNCylinder(radius: 0.0012, height: 0.12)); n.geometry!.firstMaterial!.diffuse.contents = c; n.geometry!.firstMaterial!.lightingModel = .constant
    n.simdPosition = d * 0.06; if d.x != 0 { n.eulerAngles.z = .pi/2 } else if d.z != 0 { n.eulerAngles.x = .pi/2 }; return n
}
