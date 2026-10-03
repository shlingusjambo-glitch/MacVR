import AppKit
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
    /// `info`: one plain sentence under the label in the headset's Settings (also searched).
    struct Item { let key, label: String; let options: [String]; let def: String; var advanced = false; var info = "" }
    static let offOn = ["Off", "On"]
    static let schema: [(String, [Item])] = [
        ("Experimental", [
            Item(key: "hand_tracking", label: "Hand Tracking", options: offOn, def: "On", info: "Use tracked hands for pointing, pinching and game input when controllers are put down."),
            Item(key: "avatar_skin", label: "Skin tone", options: ["Original", "Light", "Medium", "Tan", "Brown", "Deep"], def: "Original", info: "Appearance of your hands, arms and experimental body."),
            Item(key: "show_body", label: "Show body", options: offOn, def: "Off", info: "Extend the arm shoulder mesh into a torso. No head or legs."),
            Item(key: "home_mirror", label: "Home mirror", options: offOn, def: "Off", info: "A mirror in your home showing your avatar."),
            Item(key: "show_arms", label: "Show arms", options: offOn, def: "Off", info: "Show the extended hand mesh with wrist, elbow and shoulder IK. Shoulder and elbow positions are estimated.")]),
        ("Updates", [Item(key: "auto_updates", label: "Automatic Updates", options: offOn, def: "On", info: "Install stable MacVR, WineXR and SiliconXR releases automatically. Checks every 15 minutes while no game is open. Installed updates restart MacVR automatically when idle.")]),
        ("General", [Item(key: "render_scale", label: "Render Resolution", options: ["50%", "75%", "100%", "125%", "150%"], def: "100%",
                          info: "Sharper games at higher values, smoother frame rates at lower ones. Applies when you reconnect."),
                     Item(key: "refresh_rate", label: "Headset Refresh Rate", options: ["72", "80", "90"], def: "72",
                          info: "Frames per second on the headset. Higher feels smoother and needs a faster Mac."),
                     Item(key: "wifi_play", label: "Wi-Fi Play", options: offOn, def: "On",
                          info: "Play without the cable. Connect the headset with USB once to pair it; after that, open MacVR on the Quest on the same network and it finds this Mac by itself. macOS must allow MacVR under Privacy & Security > Local Network.")]),
        ("Play Area", [Item(key: "home_style", label: "3D Home", options: ["Room 1107", "Kleeblatt"], def: "Room 1107",
                            info: "Choose a fully modeled home. Hold a controller stick forward to aim a teleport, then release to move."),
                       Item(key: "floor_grid", label: "Show Floor Grid", options: offOn, def: "On", info: "A subtle grid on the floor of your home."),
                       Item(key: "environment", label: "Home Environment",
                            options: ["Void", "Golden Bay", "Venice Sunset", "Rooftop Night", "Kloofendal Sky", "Lilienstein", "Starry Night",
                                      "Forest", "Snowy Park", "Fireside", "Sky On Fire", "Harbour Sunset", "Moonless Night"], def: "Golden Bay")]),
        ("Dashboard", [
            Item(key: "menu_style", label: "Menu Style", options: ["Quest", "SteamVR"], def: "Quest",
                 info: "Quest: windows with a compact dock. SteamVR: one wide bar with the title on top."),
            Item(key: "direct_touch", label: "Direct Touch", options: offOn, def: "On",
                 info: "Tap the menu with your fingertip. The menu moves within arm's reach."),
            Item(key: "dashboard_position", label: "Dashboard Position", options: ["NEAR", "MIDDLE", "FAR"], def: "NEAR", info: "How far away the menu floats."),
            Item(key: "show_power", label: "Show Power Options", options: offOn, def: "On", info: "A power button on the dock: quit games, refresh the video and more."),
            Item(key: "ui_curved", label: "Curved UI", options: offOn, def: "On", info: "Windows curve gently around you."),
            Item(key: "show_desktop_tabs", label: "Show Desktop Tabs", options: offOn, def: "On", info: "Mac Desktop and Steam on the dock."),
            Item(key: "show_settings_tab", label: "Show Settings Tab", options: offOn, def: "On",
                 info: "A Settings icon on the dock. Settings is always one tap away in Quick Settings."),
            Item(key: "dnd", label: "Do Not Disturb", options: offOn, def: "Off", info: "No pop-up notifications. They still collect in Notifications."),
            Item(key: "system_button", label: "Also Open Menu With B / Y", options: offOn, def: "Off", info: "Handy when the menu button is hard to reach."),
            Item(key: "controller_model", label: "Controller Model", options: ["Auto", "Quest 1", "Quest 2", "Quest 3"], def: "Auto",
                 info: "The controllers you see. Auto matches your headset."),
        ]),
        ("Accessibility", [
            Item(key: "text_size", label: "Text Size", options: ["Default", "Large", "Largest"], def: "Default", info: "Bigger text across the menu."),
            Item(key: "high_contrast", label: "High Contrast", options: offOn, def: "Off", info: "Brighter text, darker panels and stronger outlines."),
            Item(key: "reduce_motion", label: "Reduce Motion", options: offOn, def: "Off", info: "No sliding, coasting or zooming animations."),
            Item(key: "left_handed", label: "Left-Handed Layout", options: offOn, def: "Off",
                 info: "Mirrors the dock and moves Delete and Done to the keyboard's left side."),
        ]),
        ("Video", [Item(key: "bitrate", label: "Stream Bitrate (Mbps)", options: ["Auto", "20", "40", "60", "100", "150"], def: "Auto",
                        info: "Higher looks sharper, lower is steadier. Auto: 100 over USB, 40 over Wi-Fi."),
                   Item(key: "codec", label: "Video Codec", options: ["H.264", "HEVC"], def: "H.264", info: "HEVC looks better at the same bitrate. Applies when you reconnect."),
                   Item(key: "perf_hud", label: "Performance Overlay", options: offOn, def: "Off", info: "Frame rate, latency, bitrate and battery floating in view, in games too."),
                   Item(key: "theater_screen", label: "Theater Screen", options: ["Small", "Medium", "Large", "IMAX"], def: "Large", info: "How big the Theater screen is."),
                   Item(key: "theater_curved", label: "Curved Theater Screen", options: offOn, def: "On", info: "The Theater screen wraps around you."),
                   Item(key: "theater_lights", label: "Theater Lights", options: ["Dark", "Dim", "Home"], def: "Dark",
                        info: "Dark: the picture's light spills into a dark room. Dim: your Space, darkened. Home: your Space as it is.")]),
        ("Developer", [Item(key: "show_fps", label: "Show FPS In Headset", options: offOn, def: "Off", advanced: true, info: "Frames per second next to the clock.")]),
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

    /// Hands/arms colour for a Skin tone preset or a picked "#RRGGBB" (Original: the default grey).
    static func skinColor(_ name: String) -> NSColor {
        let tones: [String: (CGFloat, CGFloat, CGFloat)] = ["Light": (0.96, 0.77, 0.64), "Medium": (0.80, 0.57, 0.40), "Tan": (0.65, 0.40, 0.25), "Brown": (0.43, 0.24, 0.14), "Deep": (0.24, 0.12, 0.08)]
        if name.hasPrefix("#"), let v = UInt32(name.dropFirst(), radix: 16) {   // custom tone from the skin picker
            return NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
        let rgb = tones[name] ?? (0.17, 0.18, 0.2)
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
    func set(_ k: String, _ v: String) {
        let customSkin = k == "avatar_skin" && v.count == 7 && v.hasPrefix("#") && UInt32(v.dropFirst(), radix: 16) != nil   // skin picker: #RRGGBB
        guard customSkin || Settings.items[k]?.options.contains(v) == true else { return }
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
