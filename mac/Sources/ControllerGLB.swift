import AppKit
import SceneKit
import simd

/// Loads the bundled, MIT-licensed WebXR Input Profiles controllers in grip space.
enum ControllerGLB {
    private static var cache: [String: SCNNode] = [:]
    static func node(_ model: HeadsetModel, hand: Int) -> SCNNode? {
        // Steam Frame emulates Touch (see HeadsetModel.controllerMesh): map before indexing (rawValue 3 would trap).
        let profile = ["oculus-touch-v2", "oculus-touch-v3", "meta-quest-touch-plus"][model.controllerMesh.rawValue]
        let side = hand == 0 ? "left" : "right"
        let key = profile + "/" + side
        if let cached = cache[key] { return cached.clone() }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("controllers/\(key).glb"),
              let data = try? Data(contentsOf: url), let root = try? Loader(data).load() else { return nil }
        cache[key] = root
        return root.clone()
    }

    static func home(_ name: String) -> SCNNode? {
        let key = "homes/" + name
        if let cached = cache[key] { return cached.clone() }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(key + ".glb"),
              let data = try? Data(contentsOf: url), let root = try? Loader(data).load() else { return nil }
        root.enumerateChildNodes { node, _ in
            node.geometry?.materials.forEach { $0.lightingModel = .constant }
        }
        cache[key] = root; return root.clone()
    }
    private enum Invalid: Error { case asset }
    private final class Loader {
        let json: [String: Any]
        let binary: Data
        init(_ data: Data) throws {
            func word(_ offset: Int) throws -> UInt32 {
                guard offset >= 0, offset + 4 <= data.count else { throw Invalid.asset }
                return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            }
            guard try word(0) == 0x46546c67, try word(4) == 2, Int(try word(8)) == data.count else { throw Invalid.asset }
            var offset = 12, document: [String: Any]?, payload: Data?
            while offset + 8 <= data.count {
                let length = Int(try word(offset)), kind = try word(offset + 4)
                offset += 8
                guard length <= data.count - offset else { throw Invalid.asset }
                let chunk = data.subdata(in: offset..<offset + length)
                if kind == 0x4e4f534a { document = try JSONSerialization.jsonObject(with: chunk) as? [String: Any] }
                if kind == 0x004e4942 { payload = chunk }
                offset += length
            }
            guard let document, let payload, offset == data.count,
                  (document["extensionsRequired"] as? [String] ?? []).isEmpty else { throw Invalid.asset }
            json = document; binary = payload
        }
        func objects(_ key: String) -> [[String: Any]] { json[key] as? [[String: Any]] ?? [] }
        func object(_ key: String, _ index: Int) throws -> [String: Any] {
            let list = objects(key)
            guard list.indices.contains(index) else { throw Invalid.asset }
            return list[index]
        }
        func view(_ index: Int) throws -> (Data, Int) {
            let v = try object("bufferViews", index)
            let start = v["byteOffset"] as? Int ?? 0, length = v["byteLength"] as? Int ?? -1
            guard (v["buffer"] as? Int ?? 0) == 0, start >= 0, length >= 0, start <= binary.count,
                  length <= binary.count - start else { throw Invalid.asset }
            return (binary.subdata(in: start..<start + length), v["byteStride"] as? Int ?? 0)
        }
        func accessor(_ index: Int) throws -> (Data, Int, Int, Int) {
            let a = try object("accessors", index)
            guard let vi = a["bufferView"] as? Int, a["sparse"] == nil,
                  let count = a["count"] as? Int, count >= 0,
                  let component = a["componentType"] as? Int,
                  let type = a["type"] as? String,
                  let components = ["SCALAR":1,"VEC2":2,"VEC3":3,"VEC4":4][type],
                  let bytes = [5121:1,5123:2,5125:4,5126:4][component] else { throw Invalid.asset }
            let (raw, declaredStride) = try view(vi)
            let packed = bytes * components, stride = declaredStride == 0 ? packed : declaredStride
            let start = a["byteOffset"] as? Int ?? 0
            guard stride >= packed, start >= 0, start <= raw.count,
                  count == 0 || (packed <= raw.count - start && count - 1 <= (raw.count - start - packed) / stride) else { throw Invalid.asset }
            var result = Data(); result.reserveCapacity(count * packed)
            for i in 0..<count { result.append(raw.subdata(in: start + i * stride..<start + i * stride + packed)) }
            return (result, count, components, component)
        }
        func source(_ index: Int, semantic: SCNGeometrySource.Semantic) throws -> SCNGeometrySource {
            let (data, count, components, component) = try accessor(index)
            guard component == 5126 else { throw Invalid.asset }
            return SCNGeometrySource(data: data, semantic: semantic, vectorCount: count, usesFloatComponents: true,
                                     componentsPerVector: components, bytesPerComponent: 4, dataOffset: 0, dataStride: components * 4)
        }
        func image(_ texture: Int) throws -> NSImage {
            let t = try object("textures", texture)
            guard let ii = t["source"] as? Int else { throw Invalid.asset }
            let i = try object("images", ii)
            guard let vi = i["bufferView"] as? Int, let image = NSImage(data: try view(vi).0) else { throw Invalid.asset }
            return image
        }
        func material(_ index: Int) throws -> SCNMaterial {
            let m = try object("materials", index), pbr = m["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            let result = SCNMaterial(); result.lightingModel = .physicallyBased
            result.isDoubleSided = m["doubleSided"] as? Bool ?? false
            let factor = pbr["baseColorFactor"] as? [Double] ?? [1,1,1,1]
            guard factor.count == 4 else { throw Invalid.asset }
            if let texture = pbr["baseColorTexture"] as? [String: Any], let i = texture["index"] as? Int {
                result.diffuse.contents = try image(i)
                result.multiply.contents = NSColor(red: factor[0], green: factor[1], blue: factor[2], alpha: factor[3])
            } else { result.diffuse.contents = NSColor(red: factor[0], green: factor[1], blue: factor[2], alpha: factor[3]) }
            result.metalness.contents = pbr["metallicFactor"] as? Double ?? 1
            result.roughness.contents = pbr["roughnessFactor"] as? Double ?? 1
            if let texture = pbr["metallicRoughnessTexture"] as? [String: Any], let i = texture["index"] as? Int {
                let img = try image(i)
                result.metalness.contents = img; result.metalness.textureComponents = .blue
                result.roughness.contents = img; result.roughness.textureComponents = .green
            }
            if m["alphaMode"] as? String == "BLEND" { result.blendMode = .alpha }
            return result
        }
        func mesh(_ index: Int) throws -> SCNNode {
            let m = try object("meshes", index), root = SCNNode()
            for primitive in m["primitives"] as? [[String: Any]] ?? [] {
                guard (primitive["mode"] as? Int ?? 4) == 4,
                      let attrs = primitive["attributes"] as? [String: Int], let position = attrs["POSITION"],
                      let indices = primitive["indices"] as? Int else { throw Invalid.asset }
                var sources = [try source(position, semantic: .vertex)]
                if let normal = attrs["NORMAL"] { sources.append(try source(normal, semantic: .normal)) }
                if let uv = attrs["TEXCOORD_0"] { sources.append(try source(uv, semantic: .texcoord)) }
                let (data, count, components, component) = try accessor(indices)
                guard components == 1, count % 3 == 0, let bytes = [5121:1,5123:2,5125:4][component] else { throw Invalid.asset }
                let element = SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: count / 3, bytesPerIndex: bytes)
                let geometry = SCNGeometry(sources: sources, elements: [element])
                if let mi = primitive["material"] as? Int { geometry.firstMaterial = try material(mi) }
                root.addChildNode(SCNNode(geometry: geometry))
            }
            return root
        }
        func load() throws -> SCNNode {
            let entries = objects("nodes"), nodes = entries.map { _ in SCNNode() }
            for (i, entry) in entries.enumerated() {
                let n = nodes[i]; n.name = entry["name"] as? String
                if let mi = entry["mesh"] as? Int { n.addChildNode(try mesh(mi)) }
                if let matrix = (entry["matrix"] as? [NSNumber])?.map({ $0.floatValue }), matrix.count == 16 {
                    n.simdTransform = simd_float4x4(columns: (SIMD4(matrix[0...3]), SIMD4(matrix[4...7]), SIMD4(matrix[8...11]), SIMD4(matrix[12...15])))
                } else {
                    let t = (entry["translation"] as? [NSNumber])?.map({ $0.floatValue }) ?? [0,0,0]
                    let scale = (entry["scale"] as? [NSNumber])?.map({ $0.floatValue }) ?? [1,1,1]
                    let r = (entry["rotation"] as? [NSNumber])?.map({ $0.floatValue }) ?? [0,0,0,1]
                    guard t.count == 3, scale.count == 3, r.count == 4 else { throw Invalid.asset }
                    var transform = simd_float4x4(simd_quatf(vector: SIMD4(r)))
                    transform.columns.0 *= scale[0]
                    transform.columns.1 *= scale[1]
                    transform.columns.2 *= scale[2]
                    transform.columns.3 = SIMD4(t[0], t[1], t[2], 1)
                    n.simdTransform = transform
                }
            }
            // Reject cycles/shared parents before constructing the SceneKit tree.
            var parents = Set<Int>()
            func attach(_ i: Int, visiting: Set<Int>) throws {
                guard nodes.indices.contains(i), !visiting.contains(i) else { throw Invalid.asset }
                for child in entries[i]["children"] as? [Int] ?? [] {
                    guard nodes.indices.contains(child), parents.insert(child).inserted else { throw Invalid.asset }
                    try attach(child, visiting: visiting.union([i])); nodes[i].addChildNode(nodes[child])
                }
            }
            let scene = try object("scenes", json["scene"] as? Int ?? 0), root = SCNNode()
            for i in scene["nodes"] as? [Int] ?? [] {
                guard nodes.indices.contains(i), parents.insert(i).inserted else { throw Invalid.asset }
                try attach(i, visiting: []); root.addChildNode(nodes[i])
            }
            guard !root.childNodes.isEmpty else { throw Invalid.asset }
            return root
        }
    }
}
