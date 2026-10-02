import SceneKit
func verts(_ root: SCNNode) -> [SIMD3<Float>] {
    var out: [SIMD3<Float>] = []
    root.enumerateHierarchy { n, _ in
        guard let g = n.geometry, let s = g.sources(for: .vertex).first else { return }
        s.data.withUnsafeBytes { raw in
            for i in 0..<s.vectorCount {
                let o = s.dataOffset + i * s.dataStride
                let p = SIMD3<Float>(raw.loadUnaligned(fromByteOffset: o, as: Float.self), raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self), raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
                out.append(n.simdConvertPosition(p, to: root))
            }
        }
    }
    return out
}
func probe() {
  for m in [HeadsetModel.quest1, .quest2, .quest3] {
    let ctl = ControllerModels.build(m, hand: 0)
    let v = verts(ctl)
    print(m, v.count, "verts")
    for z in stride(from: Float(-0.06), through: 0.1, by: 0.02) {
        let s = v.filter { abs($0.z - z) < 0.006 }
        guard !s.isEmpty else { continue }
        print(String(format: "  z=%.2f  x[%.3f %.3f] y[%.3f %.3f]", z, s.map(\.x).min()!, s.map(\.x).max()!, s.map(\.y).min()!, s.map(\.y).max()!))
    }
    let t = ControllerRig(ctl, hand: 0).targets()!
    print("  stick", t.stick, "rest", t.rest, "trigger", t.trigger)
  }
}
