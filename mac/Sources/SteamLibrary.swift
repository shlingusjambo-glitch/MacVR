import Foundation

/// Games the signed-in Steam account owns, read from the Steam client's local caches (no web login or API key):
/// appcache/packageinfo.vdf lists every licensed package and its appids; appcache/appinfo.vdf gives each app's
/// name, type and VR support. Both are Steam's binary KeyValues files.
enum SteamLibrary {
    struct Owned { let appid: String; let name: String; let vr: Bool }

    static func owned(steamDir: URL) -> [Owned] {
        guard let pk = try? Data(contentsOf: steamDir.appendingPathComponent("appcache/packageinfo.vdf")),
              let ai = try? Data(contentsOf: steamDir.appendingPathComponent("appcache/appinfo.vdf")) else { return [] }
        let apps = licensedApps(pk)
        guard !apps.isEmpty else { return [] }
        return games(ai, only: apps)
    }

    // MARK: binary KeyValues
    private enum V { case s(String), i(Int64), map([String: V]) }
    private struct Reader {
        let d: Data; var i: Int
        mutating func u8() throws -> UInt8 { guard i >= 0, i < d.count else { throw E.eof }; defer { i += 1 }; return d[d.startIndex + i] }
        mutating func u32() throws -> UInt32 {
            guard i >= 0, i + 4 <= d.count else { throw E.eof }
            defer { i += 4 }
            return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: UInt32.self) }
        }
        mutating func u64() throws -> UInt64 { let lo = try u32(), hi = try u32(); return UInt64(hi) << 32 | UInt64(lo) }
        mutating func cstr() throws -> String {
            guard i >= 0, i < d.count, let end = d[(d.startIndex + i)...].firstIndex(of: 0) else { throw E.eof }
            defer { i = end - d.startIndex + 1 }
            return String(decoding: d[(d.startIndex + i)..<end], as: UTF8.self)
        }
        mutating func kv(_ keys: [String]?) throws -> [String: V] {
            var m: [String: V] = [:]
            while true {
                let t = try u8()
                if t == 8 { return m }
                let k: String
                if let keys { let n = Int(try u32()); guard n < keys.count else { throw E.bad }; k = keys[n] } else { k = try cstr() }
                switch t {
                case 0: m[k] = .map(try kv(keys))
                case 1: m[k] = .s(try cstr())
                case 2: m[k] = .i(Int64(Int32(bitPattern: try u32())))
                case 7: m[k] = .i(Int64(bitPattern: try u64()))
                default: throw E.bad
                }
            }
        }
    }
    private enum E: Error { case eof, bad }

    /// packageinfo.vdf: [u32 magic][u32 universe] then per package: u32 id (0xFFFFFFFF ends), sha1[20], u32 change,
    /// u64 token (magic >= 0x06565528), KeyValues { "<id>" { "appids" { "0" <appid> ... } } }.
    private static func licensedApps(_ d: Data) -> Set<Int64> {
        var r = Reader(d: d, i: 0), apps = Set<Int64>()
        do {
            let magic = try r.u32(); _ = try r.u32()
            while true {
                let id = try r.u32()
                if id == 0xFFFF_FFFF { break }
                r.i += 20 + 4 + (magic >= 0x0656_5528 ? 8 : 0)
                for case .map(let pkg) in try r.kv(nil).values {
                    if case .map(let ids)? = pkg["appids"] { for case .i(let a) in ids.values { apps.insert(a) } }
                }
            }
        } catch {}
        return apps
    }

    /// appinfo.vdf v28/v29: [u32 magic][u32 universe]([i64 string table offset] in v29) then per app: u32 appid (0 ends),
    /// u32 size, u32 state, u32 updated, u64 token, sha1[20], u32 change, sha1[20], KeyValues (v29 keys index the table).
    private static func games(_ d: Data, only: Set<Int64>) -> [Owned] {
        var r = Reader(d: d, i: 0), out: [Owned] = []
        do {
            let magic = try r.u32(); _ = try r.u32()
            var keys: [String]?
            if magic == 0x0756_4429 {
                let off = Int(Int64(bitPattern: try r.u64()))
                var t = Reader(d: d, i: off)
                let n = Int(try t.u32())
                keys = try (0..<n).map { _ in try t.cstr() }
            } else if magic != 0x0756_4428 { return [] }
            while true {
                let id = try r.u32()
                if id == 0 { break }
                let size = Int(try r.u32()), next = r.i + size
                if only.contains(Int64(id)) {
                    var b = Reader(d: d, i: r.i + 4 + 4 + 8 + 20 + 4 + 20)
                    var root = try b.kv(keys)
                    if case .map(let inner)? = root["appinfo"] { root = inner }
                    if case .map(let c)? = root["common"], case .s(let type)? = c["type"], type.lowercased() == "game",
                       case .s(let name)? = c["name"] {
                        var vr = false
                        if case .i(let v)? = c["openvrsupport"] { vr = v != 0 }
                        if case .s(let v)? = c["openvrsupport"] { vr = v != "0" }
                        out.append(Owned(appid: String(id), name: name, vr: vr))
                    }
                }
                r.i = next
            }
        } catch {}
        return out
    }
}
