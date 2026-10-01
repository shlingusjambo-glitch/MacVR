import Foundation

/// MACVR_HOME (tests only): run as a brand-new user, with the Wine wrapper and app data under that folder.
let macvrHome = ProcessInfo.processInfo.environment["MACVR_HOME"].map { URL(fileURLWithPath: $0) }
let appSupport: URL = {
    let u = (macvrHome?.appendingPathComponent("Library/Application Support")
             ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]).appendingPathComponent("VR4Mac")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()

/// All settings are strings: "On"/"Off" for toggles, the option text otherwise.
final class Settings: ObservableObject {
    struct Item { let key, label: String; let options: [String]; let def: String; var advanced = false }
    static let offOn = ["Off", "On"]
    static let schema: [(String, [Item])] = [
        ("General", [Item(key: "render_scale", label: "Render Resolution", options: ["50%", "75%", "100%", "125%", "150%"], def: "100%"),
                     Item(key: "refresh_rate", label: "Headset Refresh Rate", options: ["72", "80", "90"], def: "72")]),
        ("Play Area", [Item(key: "floor_grid", label: "Show Floor Grid", options: offOn, def: "On"),
                       Item(key: "environment", label: "Home Environment",
                            options: ["Void", "Golden Bay", "Venice Sunset", "Rooftop Night", "Kloofendal Sky", "Lilienstein", "Starry Night",
                                      "Forest", "Snowy Park", "Fireside", "Sky On Fire", "Harbour Sunset", "Moonless Night"], def: "Golden Bay")]),
        ("Dashboard", [
            Item(key: "dashboard_position", label: "Dashboard Position", options: ["NEAR", "MIDDLE", "FAR"], def: "NEAR"),
            Item(key: "show_power", label: "Show Power Options", options: offOn, def: "On"),
            Item(key: "ui_curved", label: "Curved UI", options: offOn, def: "On"),
            Item(key: "show_desktop_tabs", label: "Show Desktop Tabs", options: offOn, def: "On"),
            Item(key: "show_settings_tab", label: "Show Settings Tab", options: offOn, def: "On"),
            Item(key: "system_button", label: "Also Open Menu With B / Y", options: offOn, def: "Off"),
            Item(key: "controller_model", label: "Controller Model", options: ["Auto", "Quest 1", "Quest 2", "Quest 3"], def: "Auto"),
        ]),
        ("Video", [Item(key: "bitrate", label: "Stream Bitrate (Mbps)", options: ["Auto", "20", "40", "60", "100", "150"], def: "Auto"),
                   Item(key: "codec", label: "Video Codec", options: ["H.264", "HEVC"], def: "H.264")]),
        ("Developer", [Item(key: "show_fps", label: "Show FPS In Headset", options: offOn, def: "Off", advanced: true)]),
    ]
    static let items = Dictionary(uniqueKeysWithValues: schema.flatMap { $0.1 }.map { ($0.key, $0) })

    private let url = appSupport.appendingPathComponent("settings.json")
    private let lock = NSLock()
    @Published private(set) var values: [String: String]
    var onChange: () -> Void = {}

    init() {
        var v = Settings.items.mapValues { $0.def }
        if let d = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: String].self, from: d) {
            for (k, x) in saved where Settings.items[k]?.options.contains(x) == true { v[k] = x }
        }
        values = v
    }

    subscript(_ k: String) -> String { lock.lock(); defer { lock.unlock() }; return values[k] ?? "" }
    func bool(_ k: String) -> Bool { self[k] == "On" }
    func int(_ k: String) -> Int { Int(self[k].trimmingCharacters(in: CharacterSet(charactersIn: "%"))) ?? 0 }

    func set(_ k: String, _ v: String) {
        guard Settings.items[k]?.options.contains(v) == true else { return }
        let apply = { [self] in
            lock.lock(); values[k] = v; let snap = values; lock.unlock()
            try? JSONEncoder().encode(snap).write(to: url)
            onChange()
        }
        Thread.isMainThread ? apply() : DispatchQueue.main.async(execute: apply)
    }
    func cycle(_ k: String) {
        guard let o = Settings.items[k]?.options, let i = o.firstIndex(of: self[k]) else { return }
        set(k, o[(i + 1) % o.count])
    }
}
