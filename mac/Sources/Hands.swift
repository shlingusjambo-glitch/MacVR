import Foundation
import SceneKit
import simd

/// Translucent hands holding the controllers (Resources/hands/hand.obj, a static left hand in metres). Rigged here:
/// a palm root, three bones per finger and three for the thumb, each vertex skinned to its two nearest bones, and
/// every joint a hinge with anatomical limits (nothing bends backwards).
/// On attach the fingers close until they touch that controller's handle; then the pose follows the input every
/// frame: the grip squeezes, the index rests on the trigger while touched (and follows it as it's pulled) or points
/// when lifted, and the thumb finds the stick, thumbrest or pressed face button, or lifts off. Fades out at the wrist.
final class HandModel {
    let node = SCNNode()
    private let left: Bool
    private let rest: [SIMD3<Float>], restN: [SIMD3<Float>], colors: Data, element: SCNGeometryElement, material: SCNMaterial
    private let skin: [(Int, Int, Float)]
    private var bones: [Bone]
    private let joints: [[SIMD3<Float>]]
    private var grasp: [[Float]] = Array(repeating: [0.9, 1.1, 0.8], count: 3)   // pinky, ring, middle joint angles wrapped on the handle
    private var poseKey: [Float] = []
    private struct Bone { let parent: Int; let pivot: SIMD3<Float>; let segs: [(SIMD3<Float>, SIMD3<Float>)]; var axis = SIMD3<Float>(0, 0, 1)
        var limit: ClosedRange<Float> = 0...1.7; var free = false; var q = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)) }

    // Rig in the mesh's coordinates (metres, palm centre at the origin; fingers -y, palm facing -x, thumb toward +z).
    private static let wrist = SIMD3<Float>(0.0102, 0.0507, 0.0102), forearm = SIMD3<Float>(0.0130, 0.1015, 0.0072)
    /// pinky, ring, middle, index, thumb: four joints each (MCP/PIP/DIP/tip; thumb CMC/MCP/IP/tip)
    private static let fingers: [[SIMD3<Float>]] = [
        [SIMD3(-0.0043, -0.0203, -0.0478), SIMD3(-0.0051, -0.0435, -0.0587), SIMD3(-0.0058, -0.0565, -0.0653), SIMD3(-0.0058, -0.0670, -0.0679)],
        [SIMD3(-0.0014, -0.0275, -0.0174), SIMD3(-0.0029, -0.0652, -0.0254), SIMD3(-0.0042, -0.0870, -0.0297), SIMD3(-0.0043, -0.1051, -0.0319)],
        [SIMD3(0.0000, -0.0290, 0.0051), SIMD3(-0.0014, -0.0696, 0.0039), SIMD3(-0.0039, -0.0943, 0.0036), SIMD3(-0.0043, -0.1138, 0.0036)],
        [SIMD3(0.0000, -0.0261, 0.0275), SIMD3(-0.0017, -0.0609, 0.0341), SIMD3(-0.0033, -0.0826, 0.0391), SIMD3(-0.0036, -0.1012, 0.0420)],
        [SIMD3(0.0000, 0.0304, 0.0290), SIMD3(-0.0072, 0.0261, 0.0580), SIMD3(-0.0167, 0.0181, 0.0769), SIMD3(-0.0203, 0.0102, 0.0986)],
    ]
    /// Mesh space -> grip space for the left hand per controller mesh (the right hand is mirrored across grip x).
    /// Tuned so the palm sits on the outer side of each handle.
    typealias Placement = (pos: SIMD3<Float>, euler: SIMD3<Float>)
    static var place: [HeadsetModel: Placement] = [   // fitted offline: palm on the handle, fingertips on its surface,
        // index on the trigger, thumb able to reach the thumbrest, stick and both face buttons, least overlap,
        // a straight index along the aim ray
        .quest1: (SIMD3(-0.0292, 0.0212, 0.0406), SIMD3(0.4, 3.2953, 0.375)),
        .quest2: (SIMD3(-0.0256, 0.0213, 0.0398), SIMD3(0.445, 3.3816, 0.39)),
        .quest3: (SIMD3(-0.0259, 0.02, 0.0398), SIMD3(0.3325, 3.3816, 0.3675)),
    ]
    private var mirror: SIMD3<Float> { left ? SIMD3(1, 1, 1) : SIMD3(-1, 1, 1) }

    private static var cached: ([SIMD3<Float>], [[Int]])?
    private static func load() -> ([SIMD3<Float>], [[Int]])? {
        if let c = cached { return c }
        guard let u = Bundle.main.resourceURL?.appendingPathComponent("hands/hand.obj"),
              let text = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        var v: [SIMD3<Float>] = [], f: [[Int]] = []
        for line in text.split(separator: "\n") {
            let p = line.split(separator: " ")
            if p.first == "v", p.count >= 4, let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]) { v.append(SIMD3(x, y, z)) }
            if p.first == "f" { f.append(p.dropFirst().compactMap { Int($0.split(separator: "/")[0]).map { $0 - 1 } }) }
        }
        guard !v.isEmpty, f.allSatisfy({ $0.count >= 3 && $0.allSatisfy(v.indices.contains) }) else { return nil }
        cached = (v, f)
        return cached
    }

    /// `controller`: the controller mesh this hand holds (in grip space), used to close the fingers onto its handle.
    init?(hand: Int, model: HeadsetModel, controller: SCNNode?) {
        guard let (verts, faces) = HandModel.load() else { return nil }
        left = hand == 0
        let m = left ? SIMD3<Float>(1, 1, 1) : SIMD3<Float>(-1, 1, 1)   // right hand: mirror the left mesh
        rest = verts.map { $0 * m }
        var idx: [Int32] = []
        for f in faces { for i in 1..<f.count - 1 { idx += (left ? [f[0], f[i], f[i + 1]] : [f[0], f[i + 1], f[i]]).map(Int32.init) } }
        element = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        var n = [SIMD3<Float>](repeating: .zero, count: rest.count)
        for t in stride(from: 0, to: idx.count, by: 3) {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            let fn = simd_cross(rest[b] - rest[a], rest[c] - rest[a])
            n[a] += fn; n[b] += fn; n[c] += fn
        }
        restN = n.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }

        // bones: 0 palm (root), 1-12 fingers (3 each, pinky..index), 13-15 thumb
        let j = HandModel.fingers.map { $0.map { $0 * m } }, wr = HandModel.wrist * m
        joints = j
        var b = [Bone(parent: -1, pivot: wr, segs: [(wr, HandModel.forearm * m)] + j.map { (wr, $0[0]) })]
        let palm = SIMD3<Float>(left ? -1 : 1, 0, 0)                          // fingers curl toward it
        let pad = simd_normalize(SIMD3<Float>(left ? -0.8 : 0.8, 0, -0.6))   // thumb pad: toward the palm and index
        for (fi, f) in j.enumerated() {
            for k in 0..<3 {
                var bone = Bone(parent: k == 0 ? 0 : b.count - 1, pivot: f[k], segs: [(f[k], f[k + 1])])
                let dir = simd_normalize(f[k + 1] - f[k])
                bone.axis = simd_normalize(simd_cross(dir, fi == 4 ? pad : palm))
                if fi == 4 { bone.limit = k == 0 ? -0.2...0.9 : 0...(k == 1 ? 0.9 : 1.2); bone.free = k == 0 }
                else { bone.limit = 0...[1.6, 1.8, 1.3][k] }
                b.append(bone)
            }
        }
        bones = b
        // skin: the two nearest bones by distance to their segments, inverse-distance weighted (sharp falloff)
        func dist(_ p: SIMD3<Float>, _ s: (SIMD3<Float>, SIMD3<Float>)) -> Float {
            let d = s.1 - s.0, t = simd_clamp(simd_dot(p - s.0, d) / simd_dot(d, d), 0, 1)
            return simd_distance(p, s.0 + d * t)
        }
        skin = rest.map { p in
            let w = b.enumerated().map { (i, bone) in (i, 1 / pow(max(1e-4, bone.segs.map { dist(p, $0) }.min()!), 6)) }.sorted { $0.1 > $1.1 }
            return (w[0].0, w[1].0, w[0].1 / (w[0].1 + w[1].1))
        }
        // fade toward the arm: solid over the fingers and palm, gone a few centimetres past the wrist
        var d = Data(capacity: rest.count * 16)
        for p in rest {
            let t = simd_clamp((p.y - (wr.y - 0.02)) / 0.05, 0, 1), a = 1 - t * t * (3 - 2 * t)
            withUnsafeBytes(of: SIMD4<Float>(1, 1, 1, a)) { d.append(contentsOf: $0) }
        }
        colors = d
        material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        material.blendMode = .alpha
        material.transparencyMode = .singleLayer
        material.shaderModifiers = [.fragment: """
            #pragma transparent
            #pragma body
            float rim = 1.0 - saturate(dot(normalize(_surface.normal), normalize(_surface.view)));
            float a = _surface.diffuse.a * (0.22 + 0.55 * pow(rim, 1.6));
            float3 c = mix(float3(0.62, 0.67, 0.76), float3(0.96, 0.98, 1.0), rim);
            _output.color = float4(c * a, a);
            """]
        let pl = HandModel.place[model.controllerMesh] ?? HandModel.place[.quest2]!
        let e = pl.euler * SIMD3(1, left ? 1 : -1, left ? 1 : -1)   // mirrored across grip x for the right hand
        node.simdOrientation = simd_quatf(angle: e.x, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: e.y, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: e.z, axis: SIMD3(0, 0, 1))
        node.simdPosition = pl.pos * mirror
        node.renderingOrder = 10   // after the opaque controller
        node.castsShadow = false
        if let controller { fitGrasp(controller) }
        apply()
    }

    // MARK: pose
    private func worldMatrices() -> [simd_float4x4] {
        var m = [simd_float4x4](repeating: matrix_identity_float4x4, count: bones.count)
        for (i, b) in bones.enumerated() where b.parent >= 0 {
            var t = matrix_identity_float4x4; t.columns.3 = SIMD4(b.pivot, 1)
            var ti = matrix_identity_float4x4; ti.columns.3 = SIMD4(-b.pivot, 1)
            m[i] = m[b.parent] * t * simd_float4x4(b.q) * ti
        }
        return m
    }
    private func posed(_ m: [simd_float4x4], _ p: SIMD3<Float>, _ bone: Int) -> SIMD3<Float> { let r = m[bone] * SIMD4(p, 1); return SIMD3(r.x, r.y, r.z) }
    private func hinge(_ bi: Int, _ angle: Float) {
        bones[bi].q = simd_quatf(angle: simd_clamp(angle, bones[bi].limit.lowerBound, bones[bi].limit.upperBound), axis: bones[bi].axis)
    }
    /// Curl a finger (0 open .. 1 fist) about its knuckle hinges.
    private func curl(_ finger: Int, _ c: Float) {
        for k in 0..<3 { hinge(1 + finger * 3 + k, c * [1.3, 1.6, 1.1][k]) }
    }
    /// Close pinky/ring/middle around the controller's handle.
    private func fitGrasp(_ controller: SCNNode) {
        var cloud: [SIMD3<Float>] = []
        controller.enumerateHierarchy { n, _ in
            guard let g = n.geometry, let s = g.sources(for: .vertex).first, s.bytesPerComponent == 4 else { return }
            s.data.withUnsafeBytes { raw in
                for i in stride(from: 0, to: s.vectorCount, by: 2) {
                    let o = s.dataOffset + i * s.dataStride
                    cloud.append(n.simdConvertPosition(SIMD3(raw.loadUnaligned(fromByteOffset: o, as: Float.self), raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                                             raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)), to: controller))
                }
            }
        }
        // the handle as an elliptic cylinder along grip z (measured from the mesh); the ring and trigger are in front
        let hs = cloud.filter { $0.z > 0.01 && $0.z < 0.055 }
        guard let x0 = hs.map(\.x).min(), let x1 = hs.map(\.x).max(), let y0 = hs.map(\.y).min(), let y1 = hs.map(\.y).max() else { return }
        let c = SIMD2((x0 + x1) / 2, (y0 + y1) / 2), r = SIMD2((x1 - x0) / 2, (y1 - y0) / 2), zEnd = cloud.map(\.z).max()!
        let toGrip = node.simdTransform
        /// Signed distance (approx.) from the handle surface, positive outside.
        func outside(_ p: SIMD3<Float>) -> Float {
            let g = toGrip * SIMD4(p, 1)
            guard g.z > -0.005 && g.z < zEnd else { return 1 }
            return (simd_length((SIMD2(g.x, g.y) - c) / r) - 1) * min(r.x, r.y)
        }
        for f in 0..<3 {   // knuckle angles that wrap the finger (~8 mm thick) around the handle, pad resting on it
            let bi = 1 + f * 3, j = joints[f]
            var best: (cost: Float, a: [Float]) = (.infinity, [0.8, 1.2, 0.8])
            for a1 in stride(from: Float(0), through: 1.4, by: 0.07) {
                for a2 in stride(from: Float(0.2), through: 1.8, by: 0.07) {
                    let a = [a1, a2, a2 * 0.7]
                    for k in 0..<3 { hinge(bi + k, a[k]) }
                    let m = worldMatrices()
                    var cost: Float = 0
                    for k in 0..<3 {
                        let s = posed(m, j[k], k == 0 ? 0 : bi + k - 1), e = posed(m, j[k + 1], bi + k)
                        for t in stride(from: Float(0.25), through: 1, by: 0.25) { cost += max(0, 0.008 - outside(s + (e - s) * t)) }
                        if k > 0 { cost += 0.15 * abs(outside((s + e) / 2) - 0.008) }   // middle and tip segments rest on it
                    }
                    if cost < best.cost { best = (cost, a) }
                }
            }
            grasp[f] = best.a
            for k in 0..<3 { hinge(bi + k, 0) }
        }
    }
    /// Cyclic coordinate descent: bend `chain` (root first) so its last segment's end reaches `target` (mesh space).
    /// Hinged joints rotate only about their axis within limits; a `free` joint swings toward the target (clamped).
    private func reach(_ chain: [Int], tip: SIMD3<Float>, _ target: SIMD3<Float>) {
        for _ in 0..<20 {
            for bi in chain.reversed() {
                let m = worldMatrices(), pivot = posed(m, bones[bi].pivot, bones[bi].parent), end = posed(m, tip, chain.last!)
                var a = end - pivot, b = target - pivot
                let pr = simd_quatf(m[bones[bi].parent])
                if bones[bi].free {
                    guard simd_length(a) > 1e-5, simd_length(b) > 1e-5 else { continue }
                    let d = simd_quatf(from: simd_normalize(a), to: simd_normalize(b))
                    var q = simd_slerp(simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), pr.inverse * d * pr, 0.5) * bones[bi].q
                    if q.angle > 1.4 { q = simd_quatf(angle: 1.4, axis: q.axis) }   // CMC: limited swing
                    bones[bi].q = q
                } else {
                    let ax = pr.act(bones[bi].axis)
                    a -= ax * simd_dot(a, ax); b -= ax * simd_dot(b, ax)
                    guard simd_length(a) > 1e-5, simd_length(b) > 1e-5 else { continue }
                    let ang = atan2(simd_dot(simd_cross(simd_normalize(a), simd_normalize(b)), ax), simd_dot(simd_normalize(a), simd_normalize(b)))
                    let cur = bones[bi].q.angle * (simd_dot(bones[bi].q.axis, bones[bi].axis) < 0 ? -1 : 1)
                    hinge(bi, cur + ang)
                }
            }
        }
    }

    /// Thumb and index targets in grip space, from the controller mesh (nil: no mesh, use plain curls).
    struct Targets { var stick, rest, trigger: SIMD3<Float>; var buttons: [Int: SIMD3<Float>] }
    /// Pose from the controller state. `targets` come from the animated controller (trigger moves as it's pulled).
    /// `poke`: a hand near the menu straightens its index to touch it. Every joint eases toward its new pose
    /// (~60 ms), so fingers glide onto the trigger and buttons instead of snapping.
    func update(_ h: VR4Hand, targets: Targets?, poke: Bool = false) {
        let b = h.buttons
        func on(_ f: Int) -> Bool { b & UInt32(f) != 0 }
        let key: [Float] = [h.trigger, h.squeeze, h.stick_x, h.stick_y, Float(b & 0x1ff), poke ? 1 : 0] + (targets.map { [$0.trigger.y, $0.trigger.z] } ?? [])
        if key != poseKey {
            poseKey = key
            for i in bones.indices { bones[i].q = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)) }
            for f in 0..<3 { for k in 0..<3 { hinge(1 + f * 3 + k, grasp[f][k] + (0.08 * h.squeeze - 0.03) * Float(k + 1) / 2) } }   // resting on the handle, tighter when squeezed
            let toMesh = simd_inverse(node.simdTransform)
            func mesh(_ p: SIMD3<Float>) -> SIMD3<Float> { let r = toMesh * SIMD4(p, 1); return SIMD3(r.x, r.y, r.z) }
            if !poke, on(VR4_BTN_TRIGGER_TOUCH) || h.trigger > 0.05, let t = targets { reach([10, 11, 12], tip: joints[3][3], mesh(t.trigger)) }
            else { curl(3, 0.04) }   // lifted off the trigger, or poking the menu: point
            if let t = targets {
                let thumb: SIMD3<Float>
                if let pressed = t.buttons.first(where: { on($0.key) }) { thumb = pressed.value - SIMD3(0, 0.004, 0) }   // pressing it down
                else if on(VR4_BTN_STICK_TOUCH) || on(VR4_BTN_STICK_CLICK) { thumb = t.stick + SIMD3(h.stick_x, 0, -h.stick_y) * 0.008 }
                else if on(VR4_BTN_THUMB_TOUCH) || poke { thumb = t.rest }
                else { thumb = t.rest + SIMD3(0, 0.016, 0.004) }   // lifted just above the face
                reach([13, 14, 15], tip: joints[4][3], mesh(thumb))
            }
            target = bones.map(\.q)
        }
        let now = CACurrentMediaTime(), dt = Float(min(0.1, now - lastStep)); lastStep = now
        var moving = shown.count != target.count
        if moving { shown = target }
        let a = 1 - exp(-dt * 16)
        for i in shown.indices {
            let t = simd_dot(shown[i].vector, target[i].vector) < 0 ? simd_quatf(vector: -target[i].vector) : target[i]
            let n = simd_slerp(shown[i], t, a)
            if simd_length(n.vector - shown[i].vector) > 1e-4 { moving = true }
            shown[i] = n
        }
        guard moving else { return }
        for i in bones.indices { bones[i].q = shown[i] }
        apply()
    }
    private var target: [simd_quatf] = [], shown: [simd_quatf] = [], lastStep: CFTimeInterval = 0
    /// Index fingertip pad in grip space (the menu's direct touch tracks it).
    private(set) var indexTip = SIMD3<Float>.zero

    private func apply() {
        let m = worldMatrices()
        let tip = posed(m, joints[3][3] + simd_normalize(joints[3][3] - joints[3][2]) * 0.004, 12), tg = node.simdTransform * SIMD4(tip, 1)
        indexTip = SIMD3(tg.x, tg.y, tg.z)
        var v = [SIMD3<Float>](), n = [SIMD3<Float>]()
        v.reserveCapacity(rest.count); n.reserveCapacity(rest.count)
        for (i, p) in rest.enumerated() {
            let (a, b, w) = skin[i]
            let pa = m[a] * SIMD4(p, 1), pb = m[b] * SIMD4(p, 1), q = pa * w + pb * (1 - w)
            v.append(SIMD3(q.x, q.y, q.z))
            let na = m[a] * SIMD4(restN[i], 0), nb = m[b] * SIMD4(restN[i], 0), r = na * w + nb * (1 - w)
            n.append(simd_normalize(SIMD3(r.x, r.y, r.z)))
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: v.map { SCNVector3($0) }), SCNGeometrySource(normals: n.map { SCNVector3($0) }),
                                      SCNGeometrySource(data: colors, semantic: .color, vectorCount: rest.count, usesFloatComponents: true,
                                                        componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)],
                            elements: [element])
        g.materials = [material]
        node.geometry = g
    }
}

/// Moves the controller's buttons, trigger, grip and stick like the real one (WebXR Input Profiles: each
/// `<part>_value` node is blended between its `_min` and `_max` siblings), and reads where the fingers go.
final class ControllerRig {
    let root: SCNNode
    private var parts: [(value: SCNNode, min: SCNNode, max: SCNNode)] = []
    private let names: [String]
    init(_ root: SCNNode, hand: Int) {
        self.root = root
        let face = hand == 0 ? ["x_button", "y_button"] : ["a_button", "b_button"]
        names = ["xr_standard_trigger_pressed", "xr_standard_squeeze_pressed", "xr_standard_thumbstick_pressed",
                 "xr_standard_thumbstick_xaxis_pressed", "xr_standard_thumbstick_yaxis_pressed"] + face.map { $0 + "_pressed" }
        for n in names {
            if let v = root.childNode(withName: n + "_value", recursively: true), let lo = root.childNode(withName: n + "_min", recursively: true),
               let hi = root.childNode(withName: n + "_max", recursively: true) { parts.append((v, lo, hi)) }
            else { parts.append((SCNNode(), SCNNode(), SCNNode())) }   // procedural fallback mesh: nothing to move
        }
        buttonBits = hand == 0 ? [VR4_BTN_X, VR4_BTN_Y] : [VR4_BTN_A, VR4_BTN_B]
        faceNames = face
    }
    private let buttonBits: [Int], faceNames: [String]

    func update(_ h: VR4Hand) {
        func on(_ f: Int) -> Bool { h.buttons & UInt32(f) != 0 }
        // WebXR y axis is down-positive; OpenXR stick_y is up-positive
        let values: [Float] = [h.trigger, h.squeeze, on(VR4_BTN_STICK_CLICK) ? 1 : 0, (h.stick_x + 1) / 2, (1 - h.stick_y) / 2]
            + buttonBits.map { on($0) ? 1 : 0 }
        for (p, v) in zip(parts, values) {
            let a = simd_clamp(v, 0, 1)
            p.value.simdPosition = simd_mix(p.min.simdPosition, p.max.simdPosition, SIMD3(repeating: a))
            p.value.simdOrientation = simd_slerp(p.min.simdOrientation, p.max.simdOrientation, a)
        }
    }

    /// Fingertip targets in grip space: top of the stick / thumbrest / face buttons, front of the trigger.
    func targets() -> HandModel.Targets? {
        func top(_ name: String, up: Float = 0.009) -> SIMD3<Float>? {
            guard let n = root.childNode(withName: name, recursively: true) else { return nil }
            let (lo, hi) = n.boundingBox
            return n.simdConvertPosition(SIMD3(Float(lo.x + hi.x) / 2, Float(hi.y), Float(lo.z + hi.z) / 2), to: root) + SIMD3(0, up, 0)
        }
        guard let stick = top("thumbstick", up: 0.007), let trig = root.childNode(withName: "trigger", recursively: true) else { return nil }
        let (lo, hi) = trig.boundingBox
        let trigger = trig.simdConvertPosition(SIMD3(Float(lo.x + hi.x) / 2, Float(lo.y + hi.y) / 2, Float(lo.z)), to: root) + SIMD3(0, 0, -0.006)
        var buttons: [Int: SIMD3<Float>] = [:]
        for (bit, name) in zip(buttonBits, faceNames) { buttons[bit] = top(name) }
        return .init(stick: stick, rest: top("thumbrest_pressed_value") ?? stick, trigger: trigger, buttons: buttons)
    }
}
