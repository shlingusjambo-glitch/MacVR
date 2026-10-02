import SceneKit
func sdfCheck() {
    for m in [HeadsetModel.quest1, .quest2, .quest3] {
        let s = ControllerSurface(ControllerModels.build(m, hand: 0))
        print(m, "center", s.distance(SIMD3(-0.009, 0, 0.03)), "x+3cm", s.distance(SIMD3(0.025, 0, 0.03)), "x-3cm", s.distance(SIMD3(-0.045, 0, 0.03)), "y-3cm", s.distance(SIMD3(-0.009, -0.035, 0.03)))
    }
}
