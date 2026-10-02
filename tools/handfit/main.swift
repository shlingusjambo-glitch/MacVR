import SceneKit
import AppKit
let args = CommandLine.arguments
let model: HeadsetModel = [ "q1": .quest1, "q3": .quest3][ProcessInfo.processInfo.environment["M"] ?? ""] ?? .quest2
if let e = ProcessInfo.processInfo.environment["P"] { let v = e.split(separator: " ").map { Float($0)! }
    HandModel.place[model] = (SIMD3(v[0], v[1], v[2]), simd_quatf(angle: v[3], axis: SIMD3(1, 0, 0)) * simd_quatf(angle: v[4], axis: SIMD3(0, 1, 0)) * simd_quatf(angle: v[5], axis: SIMD3(0, 0, 1))) }
func scene(_ hand: Int, _ h: VR4Hand) -> SCNNode {
    let ctl = ControllerModels.build(model, hand: hand)
    let rig = ControllerRig(ctl, hand: hand); rig.update(h)
    let hm = HandModel(hand: hand, model: model, controller: ctl)!
    hm.update(h, targets: rig.targets())
    if ProcessInfo.processInfo.environment["OPAQUE"] != nil { let m = SCNMaterial(); m.diffuse.contents = NSColor(red: 0.9, green: 0.6, blue: 0.5, alpha: 1); m.lightingModel = .lambert; m.isDoubleSided = true; hm.node.geometry!.sources(for: .color).isEmpty ? () : (hm.node.geometry = SCNGeometry(sources: hm.node.geometry!.sources.filter { $0.semantic != .color }, elements: hm.node.geometry!.elements)); hm.node.geometry!.materials = [m] }
    let root = SCNNode(); root.addChildNode(ctl); root.addChildNode(hm.node)
    return root
}
if let e = ProcessInfo.processInfo.environment["EYE"] { eyeRender(Int(e)!, "eye\(e).png", buttons: ProcessInfo.processInfo.environment["BTN"].flatMap { UInt32($0) }, trigger: ProcessInfo.processInfo.environment["TRIG"].flatMap { Float($0) }); exit(0) }
if ProcessInfo.processInfo.environment["SCORE"] != nil { scoreOnly = true; for m in [HeadsetModel.quest1, .quest2, .quest3] { fit(m) }; exit(0) }
if let f = ProcessInfo.processInfo.environment["FIT"] { for m in [HeadsetModel.quest1, .quest2, .quest3] where f == "1" || f == "\(m)" { fit(m) }; exit(0) }
if ProcessInfo.processInfo.environment["PERF"] != nil { perf(); exit(0) }
if ProcessInfo.processInfo.environment["SDF"] != nil { sdfCheck(); exit(0) }
if ProcessInfo.processInfo.environment["PROBE"] != nil { probe(); exit(0) }
var idle = VR4Hand(); idle.buttons = UInt32(VR4_BTN_TRIGGER_TOUCH | VR4_BTN_THUMB_TOUCH)
var point = VR4Hand(); point.buttons = 0
var press = VR4Hand(); press.trigger = 1; press.squeeze = 1; press.buttons = UInt32(VR4_BTN_TRIGGER_TOUCH | VR4_BTN_X | VR4_BTN_A)
var stick = VR4Hand(); stick.buttons = UInt32(VR4_BTN_STICK_TOUCH | VR4_BTN_TRIGGER_TOUCH); stick.stick_y = 1
let dirs: [SIMD3<Float>] = [SIMD3(-1, 0.15, 0.05), SIMD3(1, 0.15, 0.05), SIMD3(0, 1, 0.05), SIMD3(-0.3, 0.6, -1), SIMD3(0.2, -1, -0.3)]
for (name, h) in [("idle", idle), ("point", point), ("press", press), ("stick", stick)] where args.count < 2 || args[1] == name {
    sheet(scene(0, h), "\(name)_L.png", dirs: dirs, dist: 0.36, size: 480)
}
sheet(scene(1, idle), "idle_R.png", dirs: dirs, dist: 0.36, size: 480)
