import Foundation
import SceneKit
import simd

/// Translucent hands holding the controllers (Resources/hands/freeHand.obj, a static low-poly left hand). Rigged here:
/// a palm root, three bones per finger and three for the thumb, each vertex skinned to its two nearest bones.
/// Pose follows the controller input every frame: fingers wrap the handle and squeeze with the grip, the index rests on
/// the trigger while touched (and follows it as it's pulled) or points when lifted, and the thumb finds the stick,
/// thumbrest or pressed face button, or lifts off. The hand fades out toward the wrist.
final class HandModel {
    let node = SCNNode()
    private let left: Bool
    private let rest: [SIMD3<Float>], restN: [SIMD3<Float>], colors: Data, element: SCNGeometryElement, material: SCNMaterial
    private let skin: [(Int, Int, Float)]
    private var bones: [Bone]
    private var poseKey: [Float] = []
    private struct Bone { let parent: Int; let pivot: SIMD3<Float>; let segs: [(SIMD3<Float>, SIMD3<Float>)]; var axis = SIMD3<Float>(0, 0, 1); var q = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)) }

    // Rig in the OBJ's own coordinates (fingers -y, palm facing -x, thumb toward +z), measured from the mesh.
    private static let center = SIMD3<Float>(0.85, 13.93, 0.13)
    private static let wrist = SIMD3<Float>(0.80, 14.03, 0.08), forearm = SIMD3<Float>(0.80, 14.19, 0.04)
    /// pinky, ring, middle, index, thumb: four joints each (MCP/PIP/DIP/tip; thumb CMC/MCP/IP/tip)
    private static let fingers: [[SIMD3<Float>]] = [
        [SIMD3(0.872, 13.870, 0.032), SIMD3(0.860, 13.804, 0.041), SIMD3(0.852, 13.760, 0.043), SIMD3(0.844, 13.721, 0.046)],
        [SIMD3(0.893, 13.875, 0.092), SIMD3(0.880, 13.800, 0.100), SIMD3(0.857, 13.757, 0.114), SIMD3(0.848, 13.712, 0.117)],
        [SIMD3(0.895, 13.875, 0.152), SIMD3(0.880, 13.800, 0.157), SIMD3(0.873, 13.750, 0.165), SIMD3(0.866, 13.707, 0.179)],
        [SIMD3(0.878, 13.875, 0.207), SIMD3(0.879, 13.813, 0.213), SIMD3(0.866, 13.781, 0.228), SIMD3(0.865, 13.750, 0.238)],
        [SIMD3(0.805, 13.995, 0.170), SIMD3(0.782, 13.948, 0.212), SIMD3(0.784, 13.915, 0.228), SIMD3(0.786, 13.882, 0.241)],
    ]
    /// Mesh space -> grip space for the left hand (the right one is mirrored). Tuned against the Touch meshes.
    static var place = (pos: SIMD3<Float>(-0.0375, 0, 0.03), euler: SIMD3<Float>(0.6, .pi, 0), scale: Float(0.5))
    private var mirror: SIMD3<Float> { left ? SIMD3(1, 1, 1) : SIMD3(-1, 1, 1) }

    private static var cached: ([SIMD3<Float>], [[Int]])?
    private static func load() -> ([SIMD3<Float>], [[Int]])? {
        if let c = cached { return c }
        guard let u = Bundle.main.resourceURL?.appendingPathComponent("hands/freeHand.obj"),
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

    init?(hand: Int) {
        guard let (verts, faces) = HandModel.load() else { return nil }
        left = hand == 0
        let m = left ? SIMD3<Float>(1, 1, 1) : SIMD3<Float>(-1, 1, 1)   // right hand: mirror the left mesh
        func local(_ p: SIMD3<Float>) -> SIMD3<Float> { (p - HandModel.center) * m }
        rest = verts.map(local)
        var idx: [Int32] = []
        for f in faces { for i in 1..<f.count - 1 { idx += left ? [f[0], f[i], f[i + 1]].map(Int32.init) : [f[0], f[i + 1], f[i]].map(Int32.init) } }
        element = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        var n = [SIMD3<Float>](repeating: .zero, count: rest.count)
        for t in stride(from: 0, to: idx.count, by: 3) {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            let fn = simd_cross(rest[b] - rest[a], rest[c] - rest[a])
            n[a] += fn; n[b] += fn; n[c] += fn
        }
        restN = n.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }

        // bones: 0 palm (root), 1-12 fingers (3 each, pinky..index), 13-15 thumb
        let j = HandModel.fingers.map { $0.map(local) }, wr = local(HandModel.wrist)
        var b = [Bone(parent: -1, pivot: wr, segs: [(wr, local(HandModel.forearm))] + j.map { (wr, $0[0]) })]
        let palm = SIMD3<Float>(left ? -1 : 1, 0, 0)   // palm normal: fingers curl toward it
        for (fi, f) in j.enumerated() {
            for k in 0..<3 {
                var bone = Bone(parent: k == 0 ? 0 : b.count - 1, pivot: f[k], segs: [(f[k], f[k + 1])])
                let dir = simd_normalize(f[3] - f[0])
                bone.axis = fi == 4 ? simd_normalize(simd_cross(dir, SIMD3(0, 0, 1))) : simd_normalize(simd_cross(dir, palm))
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
        // fade toward the arm: opaque over the fingers and palm, gone just past the wrist
        var d = Data(capacity: rest.count * 16)
        for p in rest {
            let t = simd_clamp((p.y - (wr.y - 0.09)) / 0.11, 0, 1), a = 1 - t * t * (3 - 2 * t)
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
        let s = HandModel.place.scale
        node.simdScale = SIMD3(repeating: s)
        let e = HandModel.place.euler * SIMD3(1, left ? 1 : -1, left ? 1 : -1)   // mirrored across grip x for the right hand
        node.simdOrientation = simd_quatf(angle: e.x, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: e.y, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: e.z, axis: SIMD3(0, 0, 1))
        node.simdPosition = HandModel.place.pos * mirror
        node.renderingOrder = 10   // after the opaque controller
        node.castsShadow = false
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
    /// Curl a finger (0 open .. 1 fist) about its knuckle hinges.
    private func curl(_ finger: Int, _ c: Float) {
        for k in 0..<3 { bones[1 + finger * 3 + k].q = simd_quatf(angle: c * [1.45, 1.75, 1.2][k], axis: bones[1 + finger * 3 + k].axis) }
    }
    /// Cyclic coordinate descent: bend `chain` (root first) so its last segment's end reaches `target` (mesh space).
    /// `hinge` keeps fingers bending only about their knuckle axis; the thumb swings freely.
    private func reach(_ chain: [Int], tip: SIMD3<Float>, _ target: SIMD3<Float>, hinge: Bool) {
        for _ in 0..<10 {
            for bi in chain.reversed() {
                let m = worldMatrices(), pivot = posed(m, bones[bi].pivot, bones[bi].parent), end = posed(m, tip, chain.last!)
                var a = end - pivot, b = target - pivot
                let pr = simd_quatf(m[bones[bi].parent])
                if hinge {
                    let ax = pr.act(bones[bi].axis)
                    a -= ax * simd_dot(a, ax); b -= ax * simd_dot(b, ax)
                    guard simd_length(a) > 1e-5, simd_length(b) > 1e-5 else { continue }
                    let ang = atan2(simd_dot(simd_cross(simd_normalize(a), simd_normalize(b)), ax), simd_dot(simd_normalize(a), simd_normalize(b)))
                    let cur = bones[bi].q.angle * (simd_dot(bones[bi].q.axis, bones[bi].axis) < 0 ? -1 : 1)
                    bones[bi].q = simd_quatf(angle: simd_clamp(cur + ang, -0.2, 1.9), axis: bones[bi].axis)
                } else {
                    guard simd_length(a) > 1e-5, simd_length(b) > 1e-5 else { continue }
                    let d = simd_quatf(from: simd_normalize(a), to: simd_normalize(b))
                    bones[bi].q = simd_slerp(simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), pr.inverse * d * pr, 0.7) * bones[bi].q
                }
            }
        }
    }

    /// Thumb and index targets in grip space, from the controller mesh (nil: no mesh, use plain curls).
    struct Targets { var stick, rest, trigger: SIMD3<Float>; var buttons: [Int: SIMD3<Float>] }
    /// Pose from the controller state. `targets` come from the animated controller (trigger moves as it's pulled).
    func update(_ h: VR4Hand, targets: Targets?) {
        let b = h.buttons
        func on(_ f: Int) -> Bool { b & UInt32(f) != 0 }
        let thumbOn = on(VR4_BTN_STICK_TOUCH) || on(VR4_BTN_THUMB_TOUCH) || b & UInt32(VR4_BTN_A | VR4_BTN_B | VR4_BTN_X | VR4_BTN_Y | VR4_BTN_STICK_CLICK) != 0
        let key: [Float] = [h.trigger, h.squeeze, h.stick_x, h.stick_y, Float(b & 0x1ff)] + (targets.map { [$0.trigger.y, $0.trigger.z, $0.stick.x, $0.stick.z] } ?? [])
        guard key != poseKey else { return }
        poseKey = key
        for i in bones.indices { bones[i].q = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)) }
        for f in 0..<3 { curl(f, 0.62 + 0.3 * h.squeeze + Float(f) * 0.03) }   // middle..pinky around the handle
        let toMesh = simd_inverse(node.simdTransform)
        func mesh(_ p: SIMD3<Float>) -> SIMD3<Float> { let r = toMesh * SIMD4(p, 1); return SIMD3(r.x, r.y, r.z) }
        let j = HandModel.fingers.map { $0.map { (($0 - HandModel.center) * mirror) } }
        if on(VR4_BTN_TRIGGER_TOUCH) || h.trigger > 0.05, let t = targets { reach([10, 11, 12], tip: j[3][3], mesh(t.trigger), hinge: true) }
        else { curl(3, on(VR4_BTN_TRIGGER_TOUCH) || h.trigger > 0.05 ? 0.4 + 0.4 * h.trigger : 0.08) }   // lifted: point
        var thumb: SIMD3<Float>?
        if let t = targets {
            if let pressed = t.buttons.first(where: { on($0.key) }) { thumb = pressed.value }
            else if on(VR4_BTN_STICK_TOUCH) || on(VR4_BTN_STICK_CLICK) { thumb = t.stick + SIMD3(h.stick_x, 0, -h.stick_y) * 0.008 }
            else if thumbOn { thumb = t.rest }
            else { thumb = t.rest + SIMD3(0, 0.022, 0.004) }   // lifted just above the face
        }
        if let thumb { reach([13, 14, 15], tip: j[4][3], mesh(thumb), hinge: false) }
        apply()
    }

    private func apply() {
        let m = worldMatrices()
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
