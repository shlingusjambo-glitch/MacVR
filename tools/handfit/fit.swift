var constructive = ProcessInfo.processInfo.environment["CONSTRUCT"] != nil
var scoreOnly = false
import SceneKit
/// Offline fit of HandModel.place per controller: coordinate descent on position + orientation.
func posedVerts(_ hm: HandModel) -> [SIMD3<Float>] {
    guard let s = hm.node.geometry?.sources(for: .vertex).first else { return [] }
    let m = hm.node.simdTransform
    return s.data.withUnsafeBytes { raw in (0..<s.vectorCount).map { i in
        let o = s.dataOffset + i * s.dataStride
        let p = SIMD4<Float>(raw.loadUnaligned(fromByteOffset: o, as: Float.self), raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self), raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self), 1)
        let g = m * p; return SIMD3(g.x, g.y, g.z) } }
}
func fit(_ model: HeadsetModel) {
    let ctl = ControllerModels.build(model, hand: 0), cloud = verts(ctl)
    // handle as an elliptic cylinder along z, measured from the mesh
    let hs = cloud.filter { $0.z > 0.01 && $0.z < 0.055 }
    let cx = (hs.map(\.x).min()! + hs.map(\.x).max()!) / 2, cy = (hs.map(\.y).min()! + hs.map(\.y).max()!) / 2
    let rx = (hs.map(\.x).max()! - hs.map(\.x).min()!) / 2, ry = (hs.map(\.y).max()! - hs.map(\.y).min()!) / 2
    let zmax = cloud.map(\.z).max()!
    print(model, "handle c", cx, cy, "r", rx, ry, "zmax", zmax)
    func ell(_ p: SIMD3<Float>) -> Float { sqrt(pow((p.x - cx) / rx, 2) + pow((p.y - cy) / ry, 2)) }
    let rest = HandModelMesh.verts
    func nearest(_ q: SIMD3<Float>) -> Int { rest.indices.min { simd_distance(rest[$0], q) < simd_distance(rest[$1], q) }! }
    let tips = HandModelMesh.tips.map(nearest)   // pinky ring middle index thumb
    let pad = rest.indices.filter { rest[$0].x < -0.0114 && abs(rest[$0].y + 0.005) < 0.022 && abs(rest[$0].z) < 0.03 }   // palm pad
    let palm = rest.indices.filter { rest[$0].x < -0.008 && abs(rest[$0].y) < 0.022 && abs(rest[$0].z) < 0.035 }
    var h = VR4Hand(); h.buttons = UInt32(VR4_BTN_TRIGGER_TOUCH | VR4_BTN_THUMB_TOUCH); h.squeeze = 0.3; h.trigger = 0.2
    let rig = ControllerRig(ctl, hand: 0), tg = rig.targets()!
    func scoreT(_ pl: HandModel.Placement, _ verbose: Bool = false) -> Float {
        HandModel.place[model] = pl
        return scoreCur(verbose)
    }
    func score(_ p: [Float], _ verbose: Bool = false) -> Float {
        HandModel.place[model] = (SIMD3(p[0], p[1], p[2]), simd_quatf(angle: p[3], axis: SIMD3(1, 0, 0)) * simd_quatf(angle: p[4], axis: SIMD3(0, 1, 0)) * simd_quatf(angle: p[5], axis: SIMD3(0, 0, 1)))
        return scoreCur(verbose)
    }
    func scoreCur(_ verbose: Bool) -> Float {
        let hm = HandModel(hand: 0, model: model, controller: ctl)!; hm.update(h, targets: tg)
        let v = posedVerts(hm)
        var pen: Float = 0
        var reachErr: Float = 0   // the thumb must also reach the stick and each face button
        for b in [UInt32(0), UInt32(VR4_BTN_STICK_TOUCH), UInt32(VR4_BTN_X), UInt32(VR4_BTN_Y)] {   // 0 = idle: flat thumb over the face
            var h2 = h; h2.buttons = UInt32(VR4_BTN_TRIGGER_TOUCH) | b
            let hm2 = HandModel(hand: 0, model: model, controller: nil)!
            hm2.node.simdTransform = hm.node.simdTransform; hm2.update(h2, targets: tg)
            let t = b == 0 ? tg.rest + SIMD3(0, 0.014, 0.004) : b == UInt32(VR4_BTN_STICK_TOUCH) ? tg.stick : tg.buttons[Int(b)]!
            let v2 = posedVerts(hm2)
            reachErr += simd_distance(v2[tips[4]], t) * (b == 0 ? 2 : b == UInt32(VR4_BTN_Y) ? 4 : 1)
            if verbose { print("    thumb target", b, "tip", v2[tips[4]], "target", t, "d", simd_distance(v2[tips[4]], t)) }
            for q in v2 where q.z > -0.01 && q.z < zmax - 0.01 { let e = ell(q); if e < 1 { pen += (1 - e) * min(rx, ry) * 0.25 } }
        }
        for q in v where q.z > -0.01 && q.z < zmax - 0.01 { let e = ell(q); if e < 1 { pen += (1 - e) * min(rx, ry) } }
        let surf = { (q: SIMD3<Float>) -> Float in abs(ell(q) - 1) * min(rx, ry) }
        let fingers = tips[0..<3].map { surf(v[$0]) }.reduce(0, +)
        let palmSide: Float = 0
        let idx = simd_distance(v[tips[3]], tg.trigger), th = simd_distance(v[tips[4]], tg.rest)
        let palmGap = palm.map { surf(v[$0]) }.min()!
        // pointing: the straight index should run along the aim ray (grip (0, -0.866, -0.5))
        let q = hm.node.simdOrientation, dir = q.act(simd_normalize(HandModelMesh.tips[3] - HandModelMesh.indexMCP))
        let aim = 1 - simd_dot(dir, SIMD3(0, -0.866, -0.5))
        let wrap = hm.graspAngles.map { max(0, 1.9 - $0[0] - $0[1]) }.reduce(0, +)   // lower fingers must actually wrap
        let seat = pad.map { abs((ell(v[$0]) - 1) * min(rx, ry) - 0.002) }.reduce(0, +) / Float(pad.count)   // handle sits in the palm
        let s = seat * 30 + wrap * 0.3 + pen * 0.4 + fingers * 3 + idx * 25 + th * 6 + reachErr * 9 + palmGap * 8 + palmSide * 10 + aim * 0.05
        if verbose { print(String(format: "  pen %.4f fingers %.4f idx %.4f thumb %.4f reach %.4f palm %.4f aim %.3f side %.4f wrap %.3f seat %.4f -> %.4f", pen, fingers, idx, th, reachErr, palmGap, aim, palmSide, wrap, seat, s)) }
        return s
    }
    // anatomical start: the handle lies in the palm just past the knuckles, across the fingers
    func start(_ e: SIMD3<Float>) -> [Float] {
        let q = simd_quatf(angle: e.x, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: e.y, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: e.z, axis: SIMD3(0, 0, 1))
        let k = SIMD3<Float>(0, -0.029, 0.005), contact = k + SIMD3(-1, 0, 0) * (0.012 + min(rx, ry)) + SIMD3(0, -1, 0) * 0.012
        let pos = SIMD3(cx, cy, 0.035) - q.act(contact)
        return [pos.x, pos.y, pos.z, e.x, e.y, e.z]
    }
    if scoreOnly { _ = scoreT(HandModel.place[model]!, true); return }
    if constructive { construct(model, ctl: ctl, cloud: cloud, scoreT: { scoreT($0, $1) }); return }
    let p0 = start(SIMD3(0.52, .pi, 0))
    var p = p0
    let lim: [Float] = [0.02, 0.025, 0.035, 0.35, 0.15, 0.15]
    print("  start", score(p0, true), p0)
    var best = score(p), step: [Float] = [0.006, 0.006, 0.006, 0.12, 0.12, 0.12]
    for _ in 0..<6 {
        var improved = true
        while improved {
            improved = false
            for i in 0..<6 { for sgn: Float in [-1, 1] {
                var q = p; q[i] += sgn * step[i]
                guard abs(q[i] - p0[i]) <= lim[i] else { continue }
                let s = score(q); if s < best { best = s; p = q; improved = true }
            } }
        }
        step = step.map { $0 / 2 }
    }
    _ = score(p, true)
    print("  .\(model): (SIMD3(\(p[0]), \(p[1]), \(p[2])), SIMD3(\(p[3]), \(p[4]), \(p[5]))),")
}

/// Palm grip line (mesh space): just below the index knuckle down to the heel of the hand on the pinky side, on the
/// palm surface (palm outward normal is -x). Align it with the handle axis, palm resting on the handle, and search the
/// roll about the handle, the slide along it and a small tilt for the best contacts.
func construct(_ model: HeadsetModel, ctl: SCNNode, cloud: [SIMD3<Float>], scoreT: (HandModel.Placement, Bool) -> Float) {
    let hs = cloud.filter { $0.z > 0.005 && $0.z < 0.06 }
    func center(_ z0: Float, _ z1: Float) -> SIMD3<Float> { let p = hs.filter { $0.z >= z0 && $0.z < z1 }; let x = p.map(\.x), y = p.map(\.y); return SIMD3((x.min()! + x.max()!) / 2, (y.min()! + y.max()!) / 2, (z0 + z1) / 2) }
    let top = center(0.005, 0.02), bot = center(0.045, 0.06)
    let U = simd_normalize(bot - top)
    let rr: Float = { let c = (top + bot) / 2; let d = hs.map { simd_length(SIMD2($0.x - c.x, $0.y - c.y)) }; return d.sorted()[d.count / 2] }()
    let A = SIMD3<Float>(-0.014, -0.018, 0.022), B = SIMD3<Float>(-0.014, 0.035, -0.03), P = (A + B) / 2
    let u = simd_normalize(B - A), n0 = SIMD3<Float>(-1, 0, 0), n = simd_normalize(n0 - u * simd_dot(n0, u)), w = simd_cross(u, n)
    let e1 = simd_normalize(simd_cross(U, SIMD3(0, 0, 1)) == .zero ? SIMD3(1, 0, 0) : simd_cross(U, SIMD3(0, 0, 1))), e2 = simd_cross(U, e1)
    var best: (Float, HandModel.Placement) = (.infinity, HandModel.place[model]!)
    for th in stride(from: Float(0), to: 2 * .pi, by: .pi / 18) {
        for tilt in stride(from: Float(-0.35), through: 0.35, by: 0.175) {
            for slide in stride(from: Float(-0.02), through: 0.02, by: 0.005) {
                let Ut = simd_quatf(angle: tilt, axis: simd_normalize(cos(th) * e1 + sin(th) * e2)).act(U)
                let N = simd_normalize(simd_cross(e2, Ut) * 0 + (cos(th) * e1 + sin(th) * e2) - Ut * simd_dot(cos(th) * e1 + sin(th) * e2, Ut))
                guard N.x > 0.55 else { continue }   // left palm faces +x (OpenXR grip): hand on the outer side, back of hand outward
                let W = simd_cross(Ut, N)
                let R = simd_float3x3(columns: (Ut, N, W)) * simd_float3x3(columns: (u, n, w)).transpose
                let axisPt = (top + bot) / 2 + U * slide
                let pos = axisPt - N * (rr + 0.004) - R * P
                let pl: HandModel.Placement = (pos, simd_quatf(R))
                let thumbUp = R * SIMD3<Float>(0, 0, 1)   // thumb side of the hand points up toward the face buttons
                guard thumbUp.y > 0.2 else { continue }
                // same holding style as the Quest 1 fit (checked by eye): fingers and palm facing the same way
                let ref = simd_float3x3(simd_quatf(vector: SIMD4(0.3609, 0.8524, 0.3353, 0.1752)))
                guard simd_dot(R * SIMD3(0, -1, 0), ref * SIMD3(0, -1, 0)) > 0.85, simd_dot(R * SIMD3(-1, 0, 0), ref * SIMD3(-1, 0, 0)) > 0.85 else { continue }
                let s = scoreT(pl, false)
                if s < best.0 { best = (s, pl) }
            }
        }
    }
    _ = scoreT(best.1, true)
    let q = best.1.rot.vector, p = best.1.pos
    print(String(format: "  .\(model): (SIMD3(%.4f, %.4f, %.4f), simd_quatf(vector: SIMD4(%.4f, %.4f, %.4f, %.4f))),", p.x, p.y, p.z, q.x, q.y, q.z, q.w))
}
