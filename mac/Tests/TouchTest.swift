import Foundation
import simd

/// Direct-touch geometry: a fingertip in front of / on / through the window centre reports the right depth and uv.
@main enum TouchTest {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let comp = Compositor()
        comp.setHomeStyle("Pavilion")
        let architecture = comp.scene.rootNode.childNode(withName: "MacVR Home Architecture", recursively: false)!
        let count = architecture.childNodes.count
        assert(count > 15 && count < 50, "bounded 3D home geometry")
        comp.setHomeStyle("Pavilion")
        assert(architecture.childNodes.count == count, "same style does not duplicate nodes")
        comp.setHomeStyle("Observatory")
        assert(architecture.childNodes.count > 10 && architecture.childNodes.count < 40, "observatory geometry")
        comp.setHomeStyle("Open vista")
        assert(architecture.parent == nil && architecture.childNodes.isEmpty, "open vista removes architecture")
        comp.setHomeStyle("Pavilion")
        assert(architecture.parent != nil && architecture.childNodes.count == count, "style can be restored")
        comp.setLayout(quest: true, compact: true); comp.setRadius(0.7)
        comp.place(head: VR4Pose(px: 0, py: 1.6, pz: 0, qx: 0, qy: 0, qz: 0, qw: 1))
        comp.setDashVisible(true)
        // window centre in world, from the panel uv we expect back
        var probe = VR4Pose(px: 0, py: 0, pz: 0, qx: 0, qy: 0, qz: 0, qw: 1)
        func at(_ depth: Float) -> Compositor.Touch? {
            // find the window surface point straight ahead by scanning z
            for x in [Float(0)] { for y in stride(from: Float(1.5), through: 1.8, by: 0.02) { for z in stride(from: Float(-0.3), through: -1.5, by: -0.001) {
                probe.px = x; probe.py = y; probe.pz = z
                if let t = comp.touch(1, grip: probe), t.depth <= 0, t.uv.y < 0.5 {
                    probe.pz = z + depth
                    return comp.touch(1, grip: probe)
                }
            } } }
            return nil
        }
        guard let front = at(0.02), let through = at(-0.03) else { fatalError("no touch on the window") }
        assert(front.depth > 0.01 && front.depth < 0.03, "front depth \(front.depth)")
        assert(through.depth < -0.02 && through.depth > -0.04, "through depth \(through.depth)")
        assert(abs(front.uv.x - through.uv.x) < 0.01 && abs(front.uv.x - 0.5) < 0.15, "uv x \(front.uv.x)")
        assert(front.normal.z > 0.9, "normal \(front.normal)")
        print("PASS: direct touch depth/uv/normal")
    }
}
