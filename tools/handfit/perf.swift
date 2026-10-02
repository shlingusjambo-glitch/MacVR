import SceneKit
import AppKit
func perf() {
    for level in [0, 1] {
        HandModel.smooth = level
        let scene = SCNScene(), hs = (0..<2).map { i -> (HandModel, ControllerRig) in let c = ControllerModels.build(.quest1, hand: i); return (HandModel(hand: i, model: .quest1, controller: c)!, ControllerRig(c, hand: i)) }
        hs.forEach { scene.rootNode.addChildNode($0.0.node) }
        let cam = SCNNode(); cam.camera = SCNCamera(); cam.position = SCNVector3(0, 0, 0.4); scene.rootNode.addChildNode(cam)
        let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil); r.scene = scene; r.pointOfView = cam
        let t0 = CACurrentMediaTime()
        for f in 0..<144 {
            var h = VR4Hand(); h.trigger = Float(f % 20) / 20; h.buttons = UInt32(VR4_BTN_TRIGGER_TOUCH | (f % 2 == 0 ? VR4_BTN_X : 0))
            for (hm, rig) in hs { rig.update(h); hm.update(h, targets: rig.targets()) }
            _ = r.snapshot(atTime: Double(f) / 72, with: CGSize(width: 256, height: 256), antialiasingMode: .none)
        }
        print("smooth", level, "ms/frame", (CACurrentMediaTime() - t0) / 144 * 1000)
    }
}
