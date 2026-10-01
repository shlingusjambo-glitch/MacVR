import Foundation

/// SiliconXR (see SiliconXR/): VR for games that run natively on macOS.
/// - OpenXR: registers libsiliconxr_openxr.dylib as the active runtime (~/.config/openxr/1/active_runtime.json),
///   unless another runtime is already registered there.
/// - Vivecraft: LWJGL ships no Apple Silicon OpenVR natives, so we drop siliconxr.jar (the SiliconXR mod) next to every
///   Vivecraft jar; it carries libopenvr_api.dylib + liblwjgl_openvr.dylib.
enum SiliconXR {
    static func install() { installOpenXR(); installVivecraft() }

    static func installOpenXR() {
        guard let lib = Bundle.main.url(forResource: "libsiliconxr_openxr", withExtension: "dylib") else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/openxr/1")
        let file = dir.appendingPathComponent("active_runtime.json")
        if let old = try? String(contentsOf: file, encoding: .utf8), !old.contains("SiliconXR") { return }   // respect another runtime
        let json = #"{"file_format_version":"1.0.0","runtime":{"name":"SiliconXR","library_path":"\#(lib.path)"}}"#
        if (try? String(contentsOf: file, encoding: .utf8)) == json { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try json.write(to: file, atomically: true, encoding: .utf8)
            NSLog("VR4Mac: SiliconXR registered as the OpenXR runtime")
        } catch { NSLog("VR4Mac: SiliconXR OpenXR registration failed: %@", "\(error)") }
    }

    static func installVivecraft() {
        guard let jar = Bundle.main.url(forResource: "siliconxr", withExtension: "jar"), let data = try? Data(contentsOf: jar) else { return }
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")
        var dirs = [support.appendingPathComponent("minecraft/mods")]
        for (root, sub) in [("PrismLauncher/instances", ["minecraft/mods", ".minecraft/mods"]), ("MultiMC/instances", ["minecraft/mods", ".minecraft/mods"]),
                            ("ModrinthApp/profiles", ["mods"])] {
            let r = support.appendingPathComponent(root)
            for inst in (try? fm.contentsOfDirectory(atPath: r.path)) ?? [] { for s in sub { dirs.append(r.appendingPathComponent(inst).appendingPathComponent(s)) } }
        }
        let cf = home.appendingPathComponent("Documents/curseforge/minecraft/Instances")
        for inst in (try? fm.contentsOfDirectory(atPath: cf.path)) ?? [] { dirs.append(cf.appendingPathComponent(inst).appendingPathComponent("mods")) }
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path), files.contains(where: { $0.lowercased().hasPrefix("vivecraft") && $0.hasSuffix(".jar") }) else { continue }
            try? fm.removeItem(at: dir.appendingPathComponent("macvr-openvr.jar"))   // pre-SiliconXR name
            let dst = dir.appendingPathComponent("siliconxr.jar")
            if (try? Data(contentsOf: dst)) == data { continue }
            do { try data.write(to: dst, options: .atomic); NSLog("VR4Mac: installed Vivecraft OpenVR natives into %@", dir.path) }
            catch { NSLog("VR4Mac: Vivecraft natives install failed for %@: %@", dir.path, "\(error)") }
        }
    }
}
