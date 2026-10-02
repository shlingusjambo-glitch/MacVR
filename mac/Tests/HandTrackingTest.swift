import Foundation
import SceneKit
import simd
@main enum HandTrackingTest {
    static func main() {
        for left in [true, false] {
            guard let hm = HandModel(hand: left ? 0 : 1, model: .quest2, controller: nil) else { print("no mesh"); exit(1) }
            let rest = HandModel.restJoints(left: left)
            let q = simd_quatf(angle: 0.9, axis: simd_normalize(SIMD3(0.3, 1, -0.2))), t = SIMD3<Float>(0.2, 1.3, -0.4), s: Float = 1.1
            let world = rest.map { q.act($0 * s) + t }
            hm.track(world)
            // expected: node transform == T * R * S
            let n = hm.node.simdTransform
            var err: Float = 0
            for p in rest { let r = n * SIMD4(p, 1); err = max(err, simd_distance(SIMD3(r.x, r.y, r.z), q.act(p * s) + t)) }
            let tipErr = simd_distance(hm.indexTip, world[10])
            print(left ? "left" : "right", "placement err", err, "index tip vs tracked tip", tipErr)
            assert(err < 1e-4 && tipErr < 0.01)
            // curl the index fully: tip must move toward the palm
            var bent = world; for k in 8...10 { bent[k] = world[7] + q.act(SIMD3(left ? -1 : 1, 0, 0)) * 0.02 * Float(k - 7) }
            hm.track(bent); print(" bent tip moved", simd_distance(hm.indexTip, world[10]))
            assert(simd_distance(hm.indexTip, world[10]) > 0.03)
        }
        // gesture: pinch hysteresis, menu
        var j = [VR4Pose](repeating: VR4Pose(px: 0, py: 1.2, pz: -0.3, qx: 0, qy: 0, qz: 0, qw: 1), count: 26)
        let head = VR4Pose(px: 0, py: 1.6, pz: 0, qx: 0, qy: 0, qz: 0, qw: 1)
        j[10].px = 0.05; var h = HandGesture.hand(j, head: head, left: false, was: VR4Hand()); print("open: trig", h.trigger, "ready", h.flags & 8 != 0); assert(h.trigger < 0.55 && h.flags & 8 != 0)
        j[10].px = 0.015; h = HandGesture.hand(j, head: head, left: false, was: h); assert(h.trigger == 1)
        j[10].px = 0.03; h = HandGesture.hand(j, head: head, left: false, was: h); assert(h.trigger == 1, "hysteresis")
        j[10].px = 0.1; h = HandGesture.hand(j, head: head, left: false, was: h); assert(h.trigger < 0.55 && h.flags & 8 == 0)
        print("ALL TRACKING CHECKS PASSED")
    }
}
