import Foundation
import CoreGraphics
import ImageIO

struct Game: Hashable {
    let appid, name: String; let installed: Bool
    var vr = false
    var progress: Double? = nil   // 0-1 while Steam is downloading it
}
struct News { let appid, title, label: String; let date: Date }

/// Wine bottle with Steam + OpenComposite + the VR4Mac OpenXR runtime; library, art and news.
final class Games: ObservableObject {
    /// Sikarugir wrapper that owns the Windows bottle (Steam + games) and the Wine engine.
    static let wrapper = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Sikarugir/Steam.app")
    let prefix = Games.wrapper.appendingPathComponent("Contents/SharedSupport/prefix")
    var steamapps: URL { prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps") }
    var steamExe: URL { prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe") }
    var vrDir: URL { prefix.appendingPathComponent("drive_c/VR4Mac") }
    @Published var status = ""
    @Published private(set) var library: [Game] = []
    /// The library game a running VR app is, by whole-word name match ("Minecraft" is not "Raft"); nil for non-Steam apps.
    func playing(_ appName: String) -> Game? {
        library.first { appName.range(of: "(^|[^\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: $0.name) + "($|[^\\p{L}\\p{N}])",
                                      options: [.regularExpression, .caseInsensitive]) != nil }
    }
    private(set) var news: [News] = []
    private var art: [String: CGImage] = [:], artLoading = Set<String>()
    var onUpdate: () -> Void = {}
    private let artLock = NSLock()

    /// Sikarugir Wine 11 engine (Gcenx builds). GPTK's Wine 7.7 crashes Steam's webhelper; CrossOver 24 hits
    /// error 0x3008 on macOS 27 and, in Windows 8.1 mode, only gets Steam's legacy client, which can't unpack zstd depots.
    static let frameworks = wrapper.appendingPathComponent("Contents/Frameworks")
    static var wine: String? {
        let p = wrapper.appendingPathComponent("Contents/SharedSupport/wine/bin/wine").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    static let defaultGames = [("546560", "Half-Life: Alyx"), ("620980", "Beat Saber"), ("418650", "Space Pirate Trainer"),
                               ("450390", "The Lab"), ("823500", "BONEWORKS"), ("555160", "Pavlov"), ("629730", "Blade & Sorcery"),
                               ("617830", "SUPERHOT VR"), ("438100", "VRChat")]
    static let notGames: Set<String> = ["228980", "250820", "1070560", "1391110", "1493710", "1628350"]

    private var owned: [SteamLibrary.Owned] = [], ownedStamp: Date?, newsFetched = false, refresher: DispatchSourceTimer?
    private let scanQ = DispatchQueue(label: "vr4.games")

    /// Everything the account owns (Steam's local caches) merged with what is installed or downloading (app manifests).
    /// Re-runs every 4 s so installs show live progress; `onUpdate` fires only when something changed.
    func scan() {
        scanQ.async { [self] in
            if refresher == nil {
                let t = DispatchSource.makeTimerSource(queue: scanQ)
                t.schedule(deadline: .now() + 4, repeating: 4)
                t.setEventHandler { [weak self] in self?.rescan() }
                t.resume(); refresher = t
            }
            rescan()
        }
    }
    private func rescan() {
        let steam = steamapps.deletingLastPathComponent()
        let stamp = (try? steam.appendingPathComponent("appcache/appinfo.vdf").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if stamp != ownedStamp { owned = SteamLibrary.owned(steamDir: steam); ownedStamp = stamp }
        var found: [String: Game] = [:]
        for o in owned where !Games.notGames.contains(o.appid) { found[o.appid] = Game(appid: o.appid, name: o.name, installed: false, vr: o.vr) }
        let files = (try? FileManager.default.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil)) ?? []
        let re = try! NSRegularExpression(pattern: "\"(appid|name|StateFlags|BytesToDownload|BytesDownloaded|installdir)\"\\s+\"([^\"]*)\"")
        for f in files where f.lastPathComponent.hasPrefix("appmanifest_") {
            guard let s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            var m: [String: String] = [:]
            for r in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                m[String(s[Range(r.range(at: 1), in: s)!])] = String(s[Range(r.range(at: 2), in: s)!])
            }
            guard let id = m["appid"], !Games.notGames.contains(id) else { continue }
            let done = (Int(m["StateFlags"] ?? "") ?? 0) & 4 != 0 && m["BytesDownloaded"] == m["BytesToDownload"]
            let total = Double(m["BytesToDownload"] ?? "") ?? 0, got = Double(m["BytesDownloaded"] ?? "") ?? 0
            let vr = (found[id]?.vr ?? false) || (done && hasVRRuntime(id, m["installdir"]))
            found[id] = Game(appid: id, name: found[id]?.name ?? m["name"] ?? id, installed: done, vr: vr,
                             progress: done ? nil : (total > 0 ? got / total : 0))
        }
        // Native scan for standalone VR games directly under drive_c/VR4Mac (e.g. BugGenesis)
        if let subdirs = try? FileManager.default.contentsOfDirectory(at: vrDir, includingPropertiesForKeys: nil) {
            for dir in subdirs where dir.hasDirectoryPath {
                let name = dir.lastPathComponent
                if ["opencomposite", "logs", "config", "wswine.bundle"].contains(name.lowercased()) { continue }
                let id = "standalone_" + name.lowercased()
                if let known = vrScan[id] {   // scanned before (the library refreshes every 4 s)
                    if known { found[id] = Game(appid: id, name: name, installed: true, vr: true, progress: nil) }
                    continue
                }
                vrScan[id] = false
                if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
                    var isVR = false, hasExe = false
                    for case let fileURL as URL in enumerator {
                        let fn = fileURL.lastPathComponent.lowercased()
                        if Games.vrFiles.contains(fn) { isVR = true }
                        if fn.hasSuffix(".exe") && !fn.contains("crash") && !fn.contains("unins") { hasExe = true }
                    }
                    if isVR && hasExe {
                        vrScan[id] = true
                        found[id] = Game(appid: id, name: name, installed: true, vr: true, progress: nil)
                    }
                }
            }
        }
        let lib = found.isEmpty ? Games.defaultGames.map { Game(appid: $0.0, name: $0.1, installed: false, vr: true) }
            : found.values.sorted { ($0.installed ? 0 : 1, $0.name.lowercased()) < ($1.installed ? 0 : 1, $1.name.lowercased()) }
        DispatchQueue.main.async {
            guard lib != self.library else { return }
            self.library = lib; self.onUpdate()
        }
        if !newsFetched { newsFetched = true; fetchNews(lib.prefix(4).map(\.appid)) }
    }

    /// Installed games whose files ship a VR runtime (OpenXR/OpenVR/Oculus/Unity or Unreal XR plugins) are VR games even
    /// when Steam's metadata doesn't say so. Scanned once per game and cached; the walk stops at the first match.
    private var vrScan: [String: Bool] = [:]
    private static let vrFiles: Set<String> = ["openxr_loader.dll", "openvr_api.dll", "unityopenxr.dll", "ovrplugin.dll",
        "oculusxrplugin.dll", "xrsdkopenvr.dll", "openxrhmd.dll", "steamvr.dll", "libovrplatform64_1.dll", "microsoftopenxrplugin.dll"]
    private func hasVRRuntime(_ id: String, _ dir: String?) -> Bool {
        if let v = vrScan[id] { return v }
        guard let dir else { return false }
        let root = steamapps.appendingPathComponent("common").appendingPathComponent(dir)
        var hit = false, seen = 0
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e {
                seen += 1
                if Games.vrFiles.contains(u.lastPathComponent.lowercased()) { hit = true; break }
                if seen > 20000 { break }   // ponytail: bounded walk; huge installs fall back to Steam's openvrsupport flag
            }
        }
        vrScan[id] = hit
        return hit
    }

    /// The real Steam logo, read from the user's own Steam install (not redistributed with MacVR).
    lazy var steamIcon: CGImage? = {
        let ico = steamapps.deletingLastPathComponent().appendingPathComponent("public/steam_tray.ico")
        guard let src = CGImageSourceCreateWithURL(ico as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let best = (0..<CGImageSourceGetCount(src)).max { a, b in
            ((CGImageSourceCopyPropertiesAtIndex(src, a, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int ?? 0) <
            ((CGImageSourceCopyPropertiesAtIndex(src, b, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int ?? 0)
        } ?? 0
        return CGImageSourceCreateImageAtIndex(src, best, nil)
    }()

    /// Steam's small square app icon from the user's Steam library cache (librarycache/<appid>/<sha1>.jpg, 32 px).
    // ponytail: 32 px source, drawn upscaled on the dock; fetch the 256 px client .ico via appinfo.vdf if it looks soft
    func icon(_ appid: String) -> CGImage? {
        artLock.lock(); defer { artLock.unlock() }
        if let i = art[appid + "/icon"] { return i }
        let dir = steamapps.deletingLastPathComponent().appendingPathComponent("appcache/librarycache/\(appid)")
        guard let f = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.first(where: { $0.count == 44 && $0.hasSuffix(".jpg") }),
              let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(f) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        art[appid + "/icon"] = img
        return img
    }

    /// Ask Steam to uninstall a game (Steam asks to confirm on the Mac desktop).
    func uninstall(_ g: Game) { steamCommand("steam://uninstall/\(g.appid)", "Opening Steam uninstall for \(g.name)…", g) }
    /// Ask Steam to download a game (Steam shows its install confirmation on the Mac desktop).
    func install(_ g: Game) { steamCommand("steam://install/\(g.appid)", "Opening Steam install for \(g.name)…", g) }

    // MARK: art + news from Steam

    /// kind: header | library_600x900 | library_hero. Returns nil until downloaded.
    func image(_ appid: String, _ kind: String) -> CGImage? {
        let k = appid + "/" + kind
        artLock.lock(); defer { artLock.unlock() }
        if let i = art[k] { return i }
        if artLoading.insert(k).inserted { loadArt(appid, kind, k, hosts: ["https://cdn.cloudflare.steamstatic.com/steam/apps",
                                                                           "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps"]) }
        return nil
    }
    private func loadArt(_ appid: String, _ kind: String, _ k: String, hosts: [String]) {
        guard let h = hosts.first, let u = URL(string: "\(h)/\(appid)/\(kind).jpg") else { return }
        URLSession.shared.dataTask(with: u) { d, r, _ in
            if let d, (r as? HTTPURLResponse)?.statusCode == 200, let src = CGImageSourceCreateWithData(d as CFData, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                self.artLock.lock(); self.art[k] = img; self.artLock.unlock()
                self.onUpdate()
            } else { self.loadArt(appid, kind, k, hosts: Array(hosts.dropFirst())) }
        }.resume()
    }
    private func fetchNews(_ ids: [String]) {
        let group = DispatchGroup()
        var out: [News] = []
        let lock = NSLock()
        for id in ids {
            guard let u = URL(string: "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=\(id)&count=1&maxlength=1") else { continue }
            group.enter()
            URLSession.shared.dataTask(with: u) { d, _, _ in
                defer { group.leave() }
                guard let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let it = ((j["appnews"] as? [String: Any])?["newsitems"] as? [[String: Any]])?.first else { return }
                lock.lock()
                out.append(News(appid: id, title: it["title"] as? String ?? "", label: it["feedlabel"] as? String ?? "",
                                date: Date(timeIntervalSince1970: it["date"] as? Double ?? 0)))
                lock.unlock()
            }.resume()
        }
        group.notify(queue: .main) { self.news = ids.compactMap { id in out.first { $0.appid == id } }; self.onUpdate() }
    }

    // MARK: Wine bottle setup

    /// Every Wine call goes through the Sikarugir launcher: this engine only works with the environment it sets
    /// (msync, loader paths); a bare `wine` can't even spawn wineboot.
    @discardableResult
    private func launcher(_ args: [String], wait: Bool = true) throws -> Process {
        let p = Process()
        p.executableURL = Games.wrapper.appendingPathComponent("Contents/MacOS/launcher")
        p.arguments = args
        let log = appSupport.appendingPathComponent("wine.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); p.standardOutput = h; p.standardError = h }
        try p.run()
        if wait { p.waitUntilExit() }
        return p
    }

    private func say(_ s: String) { DispatchQueue.main.async { self.status = s; self.onUpdate() } }

    private func download(_ url: String, _ name: String) throws -> URL {
        let f = appSupport.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: f.path) { try Data(contentsOf: URL(string: url)!).write(to: f) }
        return f
    }
    private func run(_ exe: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "VR4Mac", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(exe) failed"]) }
    }

    /// First run: build ~/Applications/Sikarugir/Steam.app from the Sikarugir Template + Wine 11 engine.
    private func ensureEngine() throws {
        guard Games.wine == nil else { return }
        let fm = FileManager.default
        say("Downloading Wine engine (≈250 MB, first run only)…")
        let rel = "https://github.com/Sikarugir-App"
        let tmpl = try download("\(rel)/Template/releases/download/v1.0/Template-1.0.20.tar.xz", "Template.tar.xz")
        let eng = try download("\(rel)/Engines/releases/download/v1.0/WS12WineSikarugir11.0.tar.xz", "Engine.tar.xz")
        let tmp = appSupport.appendingPathComponent("engine-tmp")
        try? fm.removeItem(at: tmp); try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        say("Unpacking Wine engine…")
        try run("/usr/bin/tar", ["-xJf", tmpl.path, "-C", tmp.path])
        try run("/usr/bin/tar", ["-xJf", eng.path, "-C", tmp.path])
        guard let app = try fm.contentsOfDirectory(atPath: tmp.path).first(where: { $0.hasSuffix(".app") }) else {
            throw NSError(domain: "VR4Mac", code: 4, userInfo: [NSLocalizedDescriptionKey: "Wine template missing"])
        }
        let w = Games.wrapper, c = w.appendingPathComponent("Contents")
        try fm.createDirectory(at: w.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: w)
        try fm.moveItem(at: tmp.appendingPathComponent(app), to: w)
        try fm.moveItem(at: tmp.appendingPathComponent("wswine.bundle"), to: Games.frameworks.appendingPathComponent("wswine.bundle"))
        try? fm.removeItem(at: c.appendingPathComponent("drive_c"))   // the wrapper's bottle lives in SharedSupport/prefix
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: c.appendingPathComponent("SharedSupport/wine").path, withDestinationPath: "../Frameworks/wswine.bundle")
        let plist = c.appendingPathComponent("Info.plist").path
        try run("/usr/bin/plutil", ["-replace", "Program Name and Path", "-string", "/Program Files (x86)/Steam/steam.exe", plist])
        try run("/usr/bin/plutil", ["-replace", "CFBundleName", "-string", "Steam", plist])
        for k in ["Skip Mono", "Skip Gecko"] { try run("/usr/bin/plutil", ["-replace", k, "-integer", "1", plist]) }   // their install prompts hang a headless first run
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", w.path])
        try? fm.removeItem(at: tmp); try? fm.removeItem(at: tmpl); try? fm.removeItem(at: eng)
    }

    /// Idempotent: engine, bottle, Steam, OpenComposite (OpenVR -> OpenXR) and our OpenXR runtime.
    func setup() throws {
        let fm = FileManager.default
        try ensureEngine()
        if !fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) {
            say("Creating the Windows bottle…")
            try launcher(["WSS-wineprefixcreate"])
        }
        if !fm.fileExists(atPath: steamExe.path) {
            say("Installing Steam into the Wine bottle…")
            let setup = appSupport.appendingPathComponent("SteamSetup.exe")
            if !fm.fileExists(atPath: setup.path) {
                try Data(contentsOf: URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!).write(to: setup)
            }
            try launcher(["WSS-installer", setup.path, "/S"])
        }
        try fm.createDirectory(at: vrDir, withIntermediateDirectories: true)

        // our runtime, shipped inside the .app
        if let dll = Bundle.main.url(forResource: "vr4mac_openxr", withExtension: "dll") {
            let dst = vrDir.appendingPathComponent("vr4mac_openxr.dll")
            try? fm.removeItem(at: dst); try fm.copyItem(at: dll, to: dst)
        }
        try #"{"file_format_version":"1.0.0","runtime":{"name":"VR4Mac","library_path":"C:\\VR4Mac\\vr4mac_openxr.dll"}}"#
            .write(to: vrDir.appendingPathComponent("vr4mac_openxr.json"), atomically: true, encoding: .utf8)
        try registerRuntime()

        // OpenComposite: lets OpenVR (SteamVR) games talk to our OpenXR runtime. 64-bit only, like our runtime.
        let oc = vrDir.appendingPathComponent("OpenComposite/bin/win64/vrclient_x64.dll")
        if !fm.fileExists(atPath: oc.path) {
            say("Downloading OpenComposite…")
            let d = try Data(contentsOf: URL(string: "https://znix.xyz/OpenComposite/download.php?arch=x64&branch=openxr")!)
            guard d.starts(with: [0x4d, 0x5a]) else { throw NSError(domain: "VR4Mac", code: 2, userInfo: [NSLocalizedDescriptionKey: "OpenComposite download is not a DLL"]) }
            try fm.createDirectory(at: oc.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: oc)
        }
        // OpenVR loader versions use either bin/win64, bin, or the runtime root.
        // Install every lookup location, including when repairing an existing bottle.
        let client = try Data(contentsOf: oc)
        for relativePath in ["OpenComposite/bin/vrclient_x64.dll", "OpenComposite/vrclient_x64.dll"] {
            let destination = vrDir.appendingPathComponent(relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try client.write(to: destination, options: .atomic)
        }
        for user in (try? fm.contentsOfDirectory(atPath: prefix.appendingPathComponent("drive_c/users").path)) ?? [] where user != "Public" {
            let d = prefix.appendingPathComponent("drive_c/users/\(user)/AppData/Local/openvr")
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try #"{"config":["C:\\VR4Mac\\config"],"external_drivers":null,"jsonid":"vrpathreg","log":["C:\\VR4Mac\\logs"],"runtime":["C:\\VR4Mac\\OpenComposite"],"version":1}"#
                .write(to: d.appendingPathComponent("openvrpaths.vrpath"), atomically: true, encoding: .utf8)
        }
        seedSaveFiles()   // per-game Wine workarounds, applied whether games start here or from Steam
        applyPerformancePresets()
        say("")
    }

    func launch(_ g: Game) {
        DispatchQueue.global().async { [self] in
            do {
                try setup()
                if g.appid.allSatisfy(\.isNumber) {
                    try steamRun("-applaunch \(g.appid)", g)
                } else {
                    try launchStandalone(g)
                }
                say("Starting \(g.name)…")
            } catch { say("Launch failed: \(error.localizedDescription)") }
        }
    }

    private func launchStandalone(_ g: Game) throws {
        let dir = vrDir.appendingPathComponent(g.name)
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            throw NSError(domain: "VR4Mac", code: 5, userInfo: [NSLocalizedDescriptionKey: "Standalone game folder not found: \(g.name)"])
        }
        var target: URL?
        for case let fileURL as URL in enumerator {
            let fn = fileURL.lastPathComponent.lowercased()
            if fn.hasSuffix(".exe") && !fn.contains("crash") && !fn.contains("unins") && !fn.contains("redist") {
                target = fileURL; break
            }
        }
        guard let exe = target else {
            throw NSError(domain: "VR4Mac", code: 5, userInfo: [NSLocalizedDescriptionKey: "Standalone game executable not found in \(g.name)"])
        }
        let rel = exe.path.replacingOccurrences(of: prefix.appendingPathComponent("drive_c").path, with: "C:")
            .replacingOccurrences(of: "/", with: "\\")
        let bat = vrDir.appendingPathComponent("launch_\(g.appid).bat")
        try "@echo off\r\nstart \"\" \"\(rel)\"\r\n".write(to: bat, atomically: true, encoding: .utf8)
        try launcher([bat.path], wait: false)
    }
    private func steamCommand(_ arg: String, _ msg: String, _ g: Game) {
        DispatchQueue.global().async { [self] in
            do { try setup(); try steamRun(arg, g); say(msg) } catch { say("Steam failed: \(error.localizedDescription)") }
        }
    }
    /// The wrapper launcher drops extra args, so a .bat carries them; steam.exe forwards them to the running Steam.
    private func steamRun(_ arg: String, _ g: Game) throws {
        guard g.appid.allSatisfy(\.isNumber) else { throw NSError(domain: "VR4Mac", code: 4, userInfo: [NSLocalizedDescriptionKey: "bad appid"]) }
        let bat = vrDir.appendingPathComponent("steamcmd.bat")
        try "@echo off\r\nstart \"\" \"C:\\Program Files (x86)\\Steam\\steam.exe\" \(arg)\r\n".write(to: bat, atomically: true, encoding: .utf8)
        try launcher([bat.path], wait: false)
    }

    /// Beat Saber under Wine: Mono's File.Exists reports its missing first-run save files as present, the read then
    /// throws, and startup dies before the first scene (black screen). Seed them with empty JSON; the game fills them in.
    /// ponytail: per-game list; generalise if other Unity games hit the same Mono/Wine file-exists bug.
    private func seedSaveFiles() {
        let dir = prefix.appendingPathComponent("drive_c/users/Sikarugir/AppData/LocalLow/Hyperbolic Magnetism/Beat Saber")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in ["settings.ini", "LocalLeaderboards.dat", "LocalDailyLeaderboards.dat", "PlayerData.dat", "AvatarData.dat",
                  "ControllerProfiles.dat", "ScoresToUpload.dat", "MainSettings.json", "GraphicsSettings.json"] {
            let u = dir.appendingPathComponent(f)
            if !FileManager.default.fileExists(atPath: u.path) { try? Data("{}".utf8).write(to: u) }
        }
    }

    /// One-time "Mac performance" presets for GPU-heavy games (the M-series GPU runs D3D11 through D3DMetal). Applied once
    /// per game (marker in Application Support), so later in-game changes are the player's. BONELAB: 30 -> ~50 fps.
    private func applyPerformancePresets() {
        let bonelab = prefix.appendingPathComponent("drive_c/users/Sikarugir/AppData/LocalLow/Stress Level Zero/BONELAB/settings.json")
        let mark = appSupport.appendingPathComponent("preset-bonelab")
        guard !FileManager.default.fileExists(atPath: mark.path), !isGameRunning("BONELAB"),   // the game rewrites it on exit
              let d = try? Data(contentsOf: bonelab), var j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              var g = j["graphics_settings"] as? [String: Any] else { return }
        g.merge(["graphics_quality": "Low", "msaa": 0, "bloom": "Low", "volumetrics": "Low", "hbao": "Low", "ssr": "Low",
                 "shadows": "Low", "render_scale": 80]) { _, new in new }   // values must be the game's own enum names
        j["graphics_settings"] = g
        guard let out = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) else { return }
        try? out.write(to: bonelab); FileManager.default.createFile(atPath: mark.path, contents: nil)
    }
    private func isGameRunning(_ name: String) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", "steamapps.common." + name]
        p.standardOutput = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Quit the running game only (every game runs from steamapps\common); Steam keeps running.
    func quitGame() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); p.arguments = ["-f", #"steamapps\\common\\"#]
        try? p.run()
    }

    /// Power button: kill everything running in the bottle.
    func stop() { _ = try? launcher(["WSS-wineserverkill"], wait: false) }

    /// OpenXR loader finds our runtime via HKLM\SOFTWARE\Khronos\OpenXR\1\ActiveRuntime. Written straight into the
    /// bottle's registry file (Wine's text format); ponytail: only safe while the bottle isn't running, so skip if it is.
    private func registerRuntime() throws {
        let reg = prefix.appendingPathComponent("system.reg")
        var text = try String(contentsOf: reg, encoding: .utf8)
        guard !text.contains(#"[Software\\Khronos\\OpenXR\\1]"#) else { return }
        guard !isBottleRunning() else { return }   // next setup() will add it
        text += "\n" + #"[Software\\Khronos\\OpenXR\\1] 1790000000"# + "\n" + #""ActiveRuntime"="C:\\VR4Mac\\vr4mac_openxr.json""# + "\n"
        try text.write(to: reg, atomically: true, encoding: .utf8)
    }
    private func isBottleRunning() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", "winetemp-|wineserver"]
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit(); return p.terminationStatus == 0
    }

    func openSteam() {
        DispatchQueue.global().async { [self] in
            do { try setup(); try launcher([], wait: false); say("") }
            catch { say("Steam failed: \(error.localizedDescription)") }
        }
    }
}
