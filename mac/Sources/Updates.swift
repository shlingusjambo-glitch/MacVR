import Foundation
import CryptoKit
import AppKit

/// Stable GitHub releases, verified before installation. Downloads never overwrite a running runtime.
final class Updates {
    static let shared = Updates()
    static let changed = Notification.Name("MacVR.updatesChanged")
    private let queue = DispatchQueue(label: "MacVR.updates")
    private let lock = NSLock()
    private var message = "Not checked yet", working = false
    private var timer: DispatchSourceTimer?
    private var settings: Settings?
    private var pendingMacVersion: String?
    private var gameOpen: () -> Bool = { true }
    private var lastAutomaticCheck = Date.distantPast
    private var restartPending = false, manualRestart = false, relaunchHelperStarted = false

    var status: String { lock.lock(); defer { lock.unlock() }; return message }
    private func say(_ text: String) { lock.lock(); message = text; lock.unlock(); NotificationCenter.default.post(name: Self.changed, object: nil) }
    private static var root: URL { appSupport.appendingPathComponent("Updates") }
    private static func bundledVersion(_ component: String) -> String {
        if component == "MacVR" { return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.0" }
        return Bundle.main.infoDictionary?["MacVR" + component + "Version"] as? String ?? (component == "WineXR" ? "1.1.0" : "1.0.0")
    }
    static func resource(_ name: String, extension ext: String, component: String) -> URL? {
        let file = root.appendingPathComponent("Installed/\(component)/\(name).\(ext)")
        let installed = UserDefaults.standard.string(forKey: "updates.version." + component) ?? "0"
        return FileManager.default.fileExists(atPath: file.path) && !newer(bundledVersion(component), than: installed) ? file : Bundle.main.url(forResource: name, withExtension: ext)
    }
    func start(_ settings: Settings, gameOpen: @escaping () -> Bool) {
        self.settings = settings; self.gameOpen = gameOpen
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 60)
        t.setEventHandler { [weak self] in self?.automaticTick() }; t.resume(); timer = t
    }
    private func automaticTick() {
        restartIfIdle()
        guard settings?.bool("auto_updates") == true, !gameOpen(),
              Date().timeIntervalSince(lastAutomaticCheck) >= 15 * 60 else { return }
        lastAutomaticCheck = Date(); check()
    }
    private func restartIfIdle() {
        guard restartPending, settings?.bool("auto_updates") == true || manualRestart, !gameOpen() else { return }
        if !relaunchHelperStarted {
            let helper = Process(); helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 1; done; /usr/bin/open -n \"$2\"", "relaunch", String(getpid()), Bundle.main.bundleURL.path]
            helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
            do { try helper.run(); relaunchHelperStarted = true }
            catch { say("Update installed; relaunch failed: \(error.localizedDescription)"); return }
        }
        DispatchQueue.main.async { [self] in
            guard !gameOpen(), settings?.bool("auto_updates") == true || manualRestart else { return }
            NSApplication.shared.terminate(nil)
        }
    }
    func check(force: Bool = false, apply: Bool = false) {
        guard force || settings?.bool("auto_updates") == true else { return }
        lock.lock(); guard !working else { lock.unlock(); return }; working = true; lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); working = false; lock.unlock() }
            say("Checking GitHub releases…")
            var results: [String] = []
            for component in ["WineXR", "SiliconXR", "MacVR"] {
                do { results.append(try update(component, install: settings?.bool("auto_updates") == true || apply)) }
                catch { results.append("\(component): \(error.localizedDescription)") }
            }
            say(results.joined(separator: " · ")); restartIfIdle()
        }
    }
    private struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
    private struct Release: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool; let assets: [Asset] }
    static func newer(_ candidate: String, than installed: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(installed)
        for i in 0..<max(a.count, b.count) { let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0; if x != y { return x > y } }
        return false
    }
    private func fetch(_ url: URL) throws -> Data {
        var req = URLRequest(url: url); req.timeoutInterval = 90
        req.setValue("MacVR-Updater", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(NSError(domain: "Updates", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download timed out"]))
        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            defer { semaphore.signal() }
            if let error { result = .failure(error); return }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, let data else {
                result = .failure(NSError(domain: "Updates", code: 2, userInfo: [NSLocalizedDescriptionKey: "Release download unavailable"])); return
            }
            result = .success(data)
        }
        task.resume(); if semaphore.wait(timeout: .now() + 100) == .timedOut { task.cancel(); throw failure("Download timed out") }
        return try result.get()
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "Updates", code: 3, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func run(_ executable: String, _ arguments: [String], directory: URL? = nil) throws -> String {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.standardOutput = pipe; p.standardError = pipe; p.currentDirectoryURL = directory
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw failure("Installation failed: \(String(data: data, encoding: .utf8) ?? "")") }
        return String(data: data, encoding: .utf8) ?? ""
    }
    private func download(_ asset: Asset, into directory: URL) throws -> URL {
        guard asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path.hasPrefix("/shlingusjambo-glitch/"),
              let expected = asset.digest, expected.hasPrefix("sha256:") else { throw failure("Release has no verified SHA-256 digest") }
        let data = try fetch(asset.browser_download_url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard "sha256:" + hash == expected else { throw failure("Download checksum mismatch") }
        let file = directory.appendingPathComponent(asset.name)
        guard file.lastPathComponent == asset.name, !asset.name.contains("/") else { throw failure("Invalid asset name") }
        try data.write(to: file, options: .atomic); return file
    }
    private func update(_ component: String, install: Bool) throws -> String {
        let release = try JSONDecoder().decode(Release.self, from: fetch(URL(string: "https://api.github.com/repos/shlingusjambo-glitch/\(component)/releases/latest")!))
        guard !release.draft, !release.prerelease else { return "\(component): no stable update" }
        let baseline = Self.bundledVersion(component)
        let saved = UserDefaults.standard.string(forKey: "updates.version.\(component)") ?? baseline
        let hasInstalled = FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("Installed/" + component).path)
        let version = hasInstalled && Self.newer(saved, than: baseline) ? saved : baseline
        guard Self.newer(release.tag_name, than: version) else { return "\(component) up to date" }
        guard install else { return "\(component) \(release.tag_name) available" }
        guard !gameOpen() else { return "\(component) update waits until the game closes" }
        if component == "MacVR", pendingMacVersion == release.tag_name {
            restartIfIdle(); return "MacVR update ready; restarting when idle"
        }
        manualRestart = manualRestart || settings?.bool("auto_updates") != true
        let fm = FileManager.default, scratch = Self.root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        say("Downloading \(component) \(release.tag_name)…")
        if component == "MacVR" {
            guard let asset = release.assets.first(where: { $0.name.hasSuffix("-mac.zip") }) else { throw failure("Mac archive missing") }
            let zip = try download(asset, into: scratch)
            let entries = try run("/usr/bin/unzip", ["-Z1", zip.path]).split(separator: "\n")
            guard entries.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else { throw failure("Invalid archive paths") }
            let expanded = scratch.appendingPathComponent("expanded")
            _ = try run("/usr/bin/ditto", ["-x", "-k", zip.path, expanded.path])
            let app = expanded.appendingPathComponent("MacVR.app")
            guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  bundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) else { throw failure("Unexpected app bundle") }
            _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            let target = Bundle.main.bundleURL, staged = Self.root.appendingPathComponent("Pending-MacVR.app")
            guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else { throw failure("App folder is not writable") }
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            try fm.moveItem(at: app, to: staged)
            let script = Self.root.appendingPathComponent("install-on-exit.sh")
            try """
            #!/bin/sh
            while kill -0 "$1" 2>/dev/null; do sleep 2; done
            backup="$3.update-backup"
            [ -e "$backup" ] && exit 1
            /bin/mv "$3" "$backup" || exit 1
            if /usr/bin/ditto "$2" "$3"; then
                /bin/rm -rf "$backup" "$2"
                /usr/bin/open -n "$3"
            else
                /bin/rm -rf "$3"
                /bin/mv "$backup" "$3"
                /usr/bin/open -n "$3"
            fi
            """.write(to: script, atomically: true, encoding: .utf8)
            let helper = Process(); helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = [script.path, String(getpid()), staged.path, target.path]
            helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
            try helper.run(); pendingMacVersion = release.tag_name; relaunchHelperStarted = true; restartPending = true
            return "MacVR \(release.tag_name) ready; restarting when idle"
        }
        let names = component == "WineXR" ? ["vr4mac_openxr.dll"] : ["libsiliconxr_openxr.dylib", "libopenvr_api.dylib", "liblwjgl_openvr.dylib"]
        for name in names {
            guard let asset = release.assets.first(where: { $0.name == name }) else { throw failure("Missing \(name)") }
            _ = try download(asset, into: scratch)
        }
        if component == "SiliconXR", let baseJar = Bundle.main.url(forResource: "siliconxr", withExtension: "jar") {
            let jarContents = scratch.appendingPathComponent("jar")
            _ = try run("/usr/bin/unzip", ["-q", baseJar.path, "-d", jarContents.path])
            for name in ["libopenvr_api.dylib", "liblwjgl_openvr.dylib"] {
                let target = jarContents.appendingPathComponent("siliconxr/natives/" + name)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: scratch.appendingPathComponent(name), to: target)
            }
            _ = try run("/usr/bin/zip", ["-qr", scratch.appendingPathComponent("siliconxr.jar").path, "."], directory: jarContents)
            try fm.removeItem(at: jarContents)
        }
        let installed = Self.root.appendingPathComponent("Installed"), target = installed.appendingPathComponent(component), backup = installed.appendingPathComponent(component + ".previous")
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
        if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: backup) }
        do { try fm.moveItem(at: scratch, to: target) }
        catch { if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: target) }; throw error }
        restartPending = true
        UserDefaults.standard.set(release.tag_name, forKey: "updates.version.\(component)")
        return "\(component) \(release.tag_name) installed; used next launch"
    }
}
