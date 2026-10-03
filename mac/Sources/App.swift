import SwiftUI
import SceneKit
import AppKit
import UniformTypeIdentifiers

@main
struct VR4MacApp: App {
    @StateObject private var engine = Engine()

    init() {
        if isatty(2) == 0 {   // launched from Finder/open: keep NSLog diagnostics in a file (trimmed when it grows past 5 MB)
            let log = appSupport.appendingPathComponent("macvr.log").path
            if ((try? FileManager.default.attributesOfItem(atPath: log)[.size] as? Int) ?? 0) ?? 0 > 5_000_000 { try? FileManager.default.removeItem(atPath: log) }
            freopen(log, "a", stderr)
        }
        if CommandLine.arguments.contains("--setup") {   // headless first-run setup (engine, bottle, Steam, runtime)
            let g = Games()
            do { try g.setup(); print("setup OK, wine: \(Games.wine ?? "missing")"); exit(0) }
            catch { print("setup FAILED: \(error.localizedDescription)"); exit(1) }
        }
        #if MACVR_DEV   // video/README renders: developer builds only
        if let i = CommandLine.arguments.firstIndex(of: "--orbit") {   // video renders: Quest 2 controller turntable, transparent PNGs
            let out = CommandLine.arguments[i + 1], n = Int(CommandLine.arguments[i + 2])!, hand = Int(CommandLine.arguments[i + 3]) ?? 0
            let headset = hand == 2   // 2 = the headset
            if let r = ProcessInfo.processInfo.environment["VR4_HEADSET_ROT"]?.split(separator: ",").compactMap({ Double($0) }), r.count == 3 {
                HeadsetMesh.rotation = SCNVector3(r[0], r[1], r[2])
            }
            for k in 0..<n {
                if let sh = ProcessInfo.processInfo.environment["VR4_ORBIT_SHARD"]?.split(separator: "/").compactMap({ Int($0) }), sh.count == 2, k % sh[1] != sh[0] { continue }
                if FileManager.default.fileExists(atPath: "\(out)/orbit\(hand)-\(String(format: "%03d", k)).png") { continue }   // resumable
                let a = Float(k) / Float(n) * 2 * .pi
                let img = headset ? ControllerPortrait.renderNode(HeadsetMesh.quest2(), size: 900, dir: SIMD3(sin(a), 0.22, cos(a)), fill: 4.0)
                                  : ControllerPortrait.render(.quest2, size: 900, dir: SIMD3(sin(a), -0.25, -cos(a)), hand: hand)
                guard let img else { continue }
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/orbit\(hand)-\(String(format: "%03d", k)).png"))
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
            Engine().snapshot(to: CommandLine.arguments[i + 1]); exit(0)
        }
        #endif
    }

    var body: some Scene {
        Window("MacVR", id: "status") { StatusView().environmentObject(engine) }
            .windowStyle(.hiddenTitleBar).defaultSize(width: 1120, height: 760)
        Window("MacVR Settings", id: "settings") { SettingsView(e: engine, settings: engine.settings, games: engine.games) }
            .windowStyle(.hiddenTitleBar).windowResizability(.contentSize)
        Window("VR View", id: "vrview") { VRViewWindow(engine: engine).frame(minWidth: 320, minHeight: 320) }
            .defaultSize(width: 640, height: 700)
            .commands { CommandGroup(after: .help) { Button("Export Diagnostics…") { Diagnostics.export() } } }
    }
}

/// Help > Export Diagnostics: the app log, the WineXR/SiliconXR runtime logs, settings and versions in one zip to attach
/// to a GitHub issue. Nothing is uploaded; the user picks where the zip goes.
enum Diagnostics {
    static func export() {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm"
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MacVR Diagnostics \(df.string(from: Date())).zip"; panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let out = panel.url else { return }
        do { try write(to: out); NSWorkspace.shared.activateFileViewerSelecting([out]) }
        catch { let a = NSAlert(); a.messageText = "Couldn't export diagnostics"; a.informativeText = error.localizedDescription; a.runModal() }
    }
    static func write(to out: URL) throws {
        let fm = FileManager.default, dir = fm.temporaryDirectory.appendingPathComponent("MacVR Diagnostics")
        try? fm.removeItem(at: dir); try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let files: [(URL, String)] = [(appSupport.appendingPathComponent("macvr.log"), "macvr.log"), (appSupport.appendingPathComponent("settings.json"), "settings.json")]
            + ["runtime.log", "openvr.log", "siliconxr_openxr.log"].map { (URL(fileURLWithPath: "/tmp/vr4mac/" + $0), $0) }
        for (src, name) in files where fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: dir.appendingPathComponent(name)) }
        let info = Bundle.main.infoDictionary ?? [:]
        let about = ["MacVR \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
                     "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "Mac \(Diagnostics.model()), \(ProcessInfo.processInfo.physicalMemory >> 30) GB",
                     "Wine \(Games.wine ?? "not installed")", "Exported \(Date())"].joined(separator: "\n")
        try about.write(to: dir.appendingPathComponent("about.txt"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: out)
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); zip.arguments = ["-c", "-k", "--keepParent", dir.path, out.path]
        try zip.run(); zip.waitUntilExit(); try? fm.removeItem(at: dir)
        guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    static func model() -> String {
        var n = 0; sysctlbyname("hw.model", nil, &n, nil, 0)
        var b = [CChar](repeating: 0, count: max(n, 1)); sysctlbyname("hw.model", &b, &n, nil, 0); return String(cString: b)
    }
}

// MARK: MacVR OS look for the Mac windows: flat, solid colours (same palette as the in-headset shell)
enum OS {
    static let bg = Color(red: 0.12, green: 0.145, blue: 0.176)
    static let card = Color(red: 0.165, green: 0.192, blue: 0.227), stroke = Color(red: 0.24, green: 0.27, blue: 0.32)   // dividers
    static let control = Color(red: 0.21, green: 0.24, blue: 0.29), sidebar = Color(red: 0.094, green: 0.11, blue: 0.137)
    static let accent = Color(red: 0.18, green: 0.55, blue: 1)
    static let dim = Color(white: 0.62)
    /// Flat badge colour: the brighter of the two palette entries.
    static func grad(_ a: UInt32, _ b: UInt32) -> Color {
        Color(red: Double(a >> 16 & 255) / 255, green: Double(a >> 8 & 255) / 255, blue: Double(a & 255) / 255)
    }
}
/// Rounded flat icon badge (like the dock's app icons).
struct Badge: View {
    let symbol: String, top: UInt32, bottom: UInt32; var size: CGFloat = 28
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27).fill(OS.grad(top, bottom)).frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundColor(.white))
    }
}
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(OS.card))
    }
}
struct PillButton: View {
    let title: String, symbol: String; var primary = false; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { Image(systemName: symbol); Text(title).fontWeight(.semibold) }
                .font(.system(size: 13)).foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(Capsule().fill(primary ? OS.accent : OS.control))
        }.buttonStyle(.plain)
    }
}

struct HeadsetShape: Shape {
    func path(in r: CGRect) -> Path {
        let sx = r.width / 46, sy = r.height / 30
        var p = Path()
        p.move(to: CGPoint(x: 2 * sx, y: 11 * sy))
        p.addQuadCurve(to: CGPoint(x: 11 * sx, y: 3 * sy), control: CGPoint(x: 2 * sx, y: 3 * sy))
        p.addLine(to: CGPoint(x: 35 * sx, y: 3 * sy))
        p.addQuadCurve(to: CGPoint(x: 44 * sx, y: 11 * sy), control: CGPoint(x: 44 * sx, y: 3 * sy))
        p.addLine(to: CGPoint(x: 44 * sx, y: 19 * sy))
        p.addQuadCurve(to: CGPoint(x: 35 * sx, y: 27 * sy), control: CGPoint(x: 44 * sx, y: 27 * sy))
        p.addLine(to: CGPoint(x: 29 * sx, y: 27 * sy)); p.addLine(to: CGPoint(x: 26 * sx, y: 21 * sy))
        p.addLine(to: CGPoint(x: 20 * sx, y: 21 * sy)); p.addLine(to: CGPoint(x: 17 * sx, y: 27 * sy))
        p.addLine(to: CGPoint(x: 11 * sx, y: 27 * sy))
        p.addQuadCurve(to: CGPoint(x: 2 * sx, y: 19 * sy), control: CGPoint(x: 2 * sx, y: 27 * sy))
        p.closeSubpath()
        return p
    }
}

// MARK: status window
struct StatusView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        CompanionView(e: e, games: e.games, settings: e.settings, openSettings: { openWindow(id: "settings") }, openVRView: { openWindow(id: "vrview") })
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Mic.offerInstall() } }   // first launch: headset mic driver
    }
}

/// Mirrors what the headset is being sent (left eye), like SteamVR's "Display VR View".
struct VRViewWindow: NSViewRepresentable {
    let engine: Engine
    final class MirrorView: NSView {
        var engine: Engine?
        private var timer: Timer?
        private let label = NSTextField(labelWithString: "No headset connected")
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.contentsGravity = .resizeAspect
            layer?.contentsRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)   // left eye of the side-by-side frame
            label.textColor = .gray; label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            label.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
            label.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            timer?.invalidate()
            guard window != nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                let pb = self.engine?.connected == true ? self.engine?.viewFrame : nil
                self.layer?.contents = pb.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
                self.label.isHidden = pb != nil
            }
        }
    }
    func makeNSView(context: Context) -> MirrorView { let v = MirrorView(); v.engine = engine; return v }
    func updateNSView(_ v: MirrorView, context: Context) {}
}


// MARK: settings window (same sections as the in-headset Settings)
struct SettingsView: View {
    @ObservedObject var e: Engine
    @ObservedObject var settings: Settings
    @ObservedObject var games: Games
    @Environment(\.openWindow) private var openWindow
    @StateObject private var ui = SettingsUI()

    static let sections: [(id: String, label: String, symbol: String, top: UInt32, bottom: UInt32)] = [
        ("general", "General", "gearshape.fill", 0x8e8e93, 0x636366), ("video", "Display & Video", "display", 0x3aa0ff, 0x1467e0),
        ("controllers", "Controllers", "gamecontroller.fill", 0xb07cff, 0x7040e0), ("audio", "Audio", "speaker.wave.2.fill", 0xff6b8b, 0xe0386a),
        ("environment", "Environment", "mountain.2.fill", 0x4fd18b, 0x1f9d5c), ("menu", "Universal Menu", "square.grid.3x3.fill", 0xffb23d, 0xf07b12),
        ("accessibility", "Accessibility", "accessibility", 0x2a73f5, 0x1a4fb8),
        ("games", "Games", "square.stack.3d.up.fill", 0x2f5b9e, 0x16274a), ("about", "About", "info.circle.fill", 0x6b7685, 0x4a5462),
    ]
    static let keys: [String: [String]] = [
        "general": ["render_scale", "refresh_rate"], "video": ["bitrate", "codec", "show_fps", "perf_hud", "theater_screen", "theater_curved", "theater_lights"],
        "controllers": ["controller_model", "system_button"], "environment": ["home_style", "floor_grid"],
        "menu": ["menu_style", "direct_touch", "dashboard_position", "ui_curved", "dnd", "show_desktop_tabs", "show_settings_tab", "show_power"],
        "accessibility": ["text_size", "high_contrast", "reduce_motion", "left_handed"],
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(.system(size: 20, weight: .bold)).foregroundColor(.white).padding(.horizontal, 12).padding(.top, 34).padding(.bottom, 12)
                ForEach(Self.sections, id: \.id) { s in
                    HStack(spacing: 10) {
                        Badge(symbol: s.symbol, top: s.top, bottom: s.bottom, size: 24)
                        Text(s.label).font(.system(size: 13, weight: ui.section == s.id ? .semibold : .regular)).foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(ui.section == s.id ? OS.control : .clear))
                    .contentShape(Rectangle()).onTapGesture { ui.section = s.id }
                }
                Spacer()
            }
            .padding(.horizontal, 10).frame(width: 220).background(OS.sidebar)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(Self.sections.first { $0.id == ui.section }?.label ?? "").font(.system(size: 22, weight: .bold)).foregroundColor(.white)
                    let keys = Self.keys[ui.section] ?? []
                    if !keys.isEmpty {
                        Card { ForEach(Array(keys.enumerated()), id: \.1) { i, k in if i > 0 { Divider().overlay(OS.stroke).padding(.vertical, 8) }; row(k) } }
                    }
                    switch ui.section {
                    case "general":
                        Card {
                            HStack { Text("VR View").foregroundColor(.white); Spacer()
                                Button("Display VR View") { openWindow(id: "vrview") }.buttonStyle(.borderedProminent) }
                        }
                    case "audio": AudioCard(prefs: ui.audio)
                    case "environment": EnvironmentGrid(settings: settings)
                    case "games": GamesCard(games: games)
                    case "about": about
                    default: EmptyView()
                    }
                    if !keys.isEmpty {
                        Button("Reset to Defaults") { keys.forEach { k in if let it = Settings.items[k] { settings.set(k, it.def) } } }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(OS.accent)
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 820, height: 580)
        .background(OS.bg)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func row(_ key: String) -> some View {
        if Settings.avatarKeys.contains(key) && settings.values["show_arms"] != "On" {
            EmptyView()   // avatar options only with Show arms
        } else if key == "avatar_skin" {
            HStack {
                Text("Skin colour").font(.system(size: 13)).foregroundColor(.white)
                Spacer()
                if settings.values["avatar_skin"]?.hasPrefix("#") == true {
                    ColorPicker("", selection: Binding(get: { Color(nsColor: Settings.skinColor(settings.values["avatar_skin"] ?? "")) }, set: { c in
                        guard let s = NSColor(c).usingColorSpace(.sRGB) else { return }
                        let h = String(format: "#%02X%02X%02X", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
                        settings.set("avatar_skin", h); UserDefaults.standard.set(h, forKey: "skin.color")
                    }), supportsOpacity: false).labelsHidden()
                }
                Toggle("", isOn: Binding(get: { settings.values["avatar_skin"]?.hasPrefix("#") == true },
                                         set: { settings.set("avatar_skin", $0 ? UserDefaults.standard.string(forKey: "skin.color") ?? "#C68863" : "Original") }))
                    .toggleStyle(.switch).labelsHidden()
            }
        } else if let it = Settings.items[key] {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.label).font(.system(size: 13)).foregroundColor(.white)
                    if !it.info.isEmpty { Text(it.info).font(.system(size: 11)).foregroundColor(OS.dim).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
                if it.options == Settings.offOn {
                    Toggle("", isOn: Binding(get: { settings.values[key] == "On" }, set: { settings.set(key, $0 ? "On" : "Off") })).toggleStyle(.switch).labelsHidden()
                } else {
                    Picker("", selection: Binding(get: { settings.values[key] ?? it.def }, set: { settings.set(key, $0) })) {
                        ForEach(it.options, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 180)
                }
            }
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                ForEach([("Version", "MacVR OS " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")),
                         ("Headset", e.connected ? e.device : "Not connected"), ("Stream", e.connected ? e.streamInfo : "-"),
                         ("Library", "\(games.library.count) owned · \(games.library.filter(\.installed).count) installed")], id: \.0) { k, v in
                    HStack { Text(k).foregroundColor(OS.dim); Spacer(); Text(v).foregroundColor(.white) }.font(.system(size: 13)).padding(.vertical, 4)
                }
            }
            HStack(spacing: 10) {
                PillButton(title: "Replay Welcome Tour", symbol: "sparkles", primary: true) { e.replayTour() }
                PillButton(title: "Open Logs", symbol: "doc.text.magnifyingglass") { NSWorkspace.shared.open(appSupport) }
            }
            Text("Environments: Poly Haven (CC0) · Sounds: AOSP (Apache-2.0) · Icons: Lucide (ISC) · Controller models: WebXR Input Profiles (MIT)")
                .font(.system(size: 11)).foregroundColor(OS.dim)
        }
    }
}

/// Plain ObservableObject because the command line tools lack the SwiftUI @State macro plugin.
final class SettingsUI: ObservableObject { @Published var section = "general"; let audio = AudioPrefs() }

/// UISounds stores its levels in UserDefaults; this publishes them for SwiftUI.
final class AudioPrefs: ObservableObject {
    private let s = UISounds.shared
    var stream: Double { get { Double(s.streamVolume) } set { objectWillChange.send(); s.streamVolume = Int(newValue) } }
    var ui: Double { get { Double(s.volume) } set { objectWillChange.send(); s.volume = Int(newValue) } }
    var balance: Double { get { Double(s.balance) } set { objectWillChange.send(); s.balance = abs(Int(newValue)) < 4 ? 0 : Int(newValue) } }
    var mono: Bool { get { s.mono } set { objectWillChange.send(); s.mono = newValue } }
    var brightness: Double { get { Double(s.brightness) } set { objectWillChange.send(); s.brightness = Int(newValue) } }
    var mic: String { get { Mic.shared.choice } set { objectWillChange.send(); Mic.shared.choice = newValue } }
}
struct AudioCard: View {
    @ObservedObject var prefs: AudioPrefs
    var body: some View {
        Card {
            slider("Headset Audio", "speaker.wave.2.fill", Binding(get: { prefs.stream }, set: { prefs.stream = $0 }), 0...100, "%")
            Divider().overlay(OS.stroke).padding(.vertical, 8)
            HStack(spacing: 10) {
                Image(systemName: "mic.fill").foregroundColor(OS.dim).frame(width: 18)
                Text("Microphone").foregroundColor(.white).frame(width: 120, alignment: .leading)
                Picker("", selection: Binding(get: { prefs.mic }, set: { prefs.mic = $0 })) {
                    ForEach(Mic.shared.options(), id: \.0) { Text($0.1).tag($0.0) }
                }.labelsHidden()
            }.font(.system(size: 13))
            Divider().overlay(OS.stroke).padding(.vertical, 8)
            slider("Menu Sounds", "music.note", Binding(get: { prefs.ui }, set: { prefs.ui = $0 }), 0...100, "%")
            Divider().overlay(OS.stroke).padding(.vertical, 8)
            slider("Balance", "arrow.left.and.right", Binding(get: { prefs.balance }, set: { prefs.balance = $0 }), -50...50, "")
            Divider().overlay(OS.stroke).padding(.vertical, 8)
            HStack { Text("Mono Audio").foregroundColor(.white); Spacer()
                Toggle("", isOn: Binding(get: { prefs.mono }, set: { prefs.mono = $0 })).toggleStyle(.switch).labelsHidden() }.font(.system(size: 13))
            Divider().overlay(OS.stroke).padding(.vertical, 8)
            slider("Menu Brightness", "sun.max.fill", Binding(get: { prefs.brightness }, set: { prefs.brightness = $0 }), 20...100, "%")
        }
    }
    private func slider(_ label: String, _ symbol: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ unit: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundColor(OS.dim).frame(width: 18)
            Text(label).foregroundColor(.white).frame(width: 120, alignment: .leading)
            Slider(value: v, in: r).tint(OS.accent)
            Text(unit.isEmpty ? (v.wrappedValue == 0 ? "Centre" : String(Int(v.wrappedValue))) : "\(Int(v.wrappedValue))\(unit)").foregroundColor(OS.dim).frame(width: 52, alignment: .trailing)
        }.font(.system(size: 13))
    }
}
struct EnvironmentGrid: View {
    @ObservedObject var settings: Settings
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
            ForEach(Settings.items["environment"]!.options, id: \.self) { name in
                let sel = settings.values["environment"] == name
                VStack(spacing: 6) {
                    Group {
                        if let t = Dashboard.envThumb(name) { Image(decorative: t, scale: 1).resizable().aspectRatio(2, contentMode: .fill) }
                        else { OS.grad(0x3a2a6c, 0x140c30).aspectRatio(2, contentMode: .fill) }
                    }
                    .frame(height: 84).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(sel ? OS.accent : OS.stroke, lineWidth: sel ? 3 : 1))
                    Text(name).font(.system(size: 12, weight: sel ? .semibold : .regular)).foregroundColor(sel ? .white : OS.dim)
                }
                .contentShape(Rectangle()).onTapGesture { settings.set("environment", name) }
            }
        }
    }
}
/// Per-game overrides (resolution / world scale / theater) for installed games, same values as in-headset Game Settings.
struct GamesCard: View {
    @ObservedObject var games: Games
    @StateObject private var tick = Ticker()
    var body: some View {
        let installed = games.library.filter(\.installed)
        Card {
            if installed.isEmpty { Text("No installed games yet.").foregroundColor(OS.dim) }
            ForEach(Array(installed.enumerated()), id: \.1.appid) { i, g in
                if i > 0 { Divider().overlay(OS.stroke).padding(.vertical, 8) }
                HStack(spacing: 10) {
                    if let art = games.image(g.appid, "header") {
                        Image(decorative: art, scale: 1).resizable().aspectRatio(contentMode: .fill).frame(width: 64, height: 30).clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    Text(g.name).foregroundColor(.white).lineLimit(1)
                    Spacer()
                    pick(g, "render", "Resolution", [0, 50, 75, 100, 125, 150])
                    pick(g, "world", "World", [0, 50, 75, 100, 125, 150, 200])
                    Toggle("Theater", isOn: Binding(get: { Dashboard.override(g.appid, "theater") == 1 },
                                                    set: { Dashboard.setOverride(g.appid, "theater", $0 ? 1 : 0); tick.bump() })).toggleStyle(.checkbox)
                }.font(.system(size: 12))
            }
        }
        Text("World scale updates live for the running game. Restart the game to apply resolution or Theater defaults.").font(.system(size: 11)).foregroundColor(OS.dim)
    }
    private func pick(_ g: Game, _ key: String, _ label: String, _ opts: [Int]) -> some View {
        Picker(label, selection: Binding(get: { Dashboard.override(g.appid, key) }, set: { Dashboard.setOverride(g.appid, key, $0); tick.bump() })) {
            ForEach(opts, id: \.self) { Text($0 == 0 ? "Default" : "\($0)%").tag($0) }
        }.frame(width: 150)
    }
}
final class Ticker: ObservableObject { func bump() { objectWillChange.send() } }


final class CompanionUI: ObservableObject { @Published var page = "Home"; @Published var query = ""; @Published var installedOnly = false }

/// The desktop companion mirrors the destinations available inside the headset.
struct CompanionView: View {
    @ObservedObject var e: Engine
    @ObservedObject var games: Games
    @ObservedObject var settings: Settings
    var openSettings: () -> Void
    var openVRView: () -> Void
    @StateObject private var ui = CompanionUI()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label("MacVR", systemImage: "visionpro").font(.system(size: 24, weight: .bold)).padding(.bottom, 24)
                ForEach([("Home", "house"), ("Library", "square.grid.2x2"), ("Spaces", "mountain.2")], id: \.0) { name, icon in
                    Button { ui.page = name } label: {
                        Label(name, systemImage: icon).font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(ui.page == name ? OS.accent.opacity(0.25) : .clear))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Label(e.connected ? e.device : "Headset offline", systemImage: e.connected ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundColor(e.connected ? .green : OS.dim).font(.system(size: 12))
                Button("Settings", systemImage: "gearshape", action: openSettings).buttonStyle(.plain)
            }.padding(24).frame(width: 190).background(OS.sidebar)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(ui.page == "Home" ? "Your next adventure starts here." : ui.page).font(.system(size: 30, weight: .bold))
                            Text(ui.page == "Home" ? "Your Mac. A whole new dimension." : ui.page == "Library" ? "Your games, ready when you are." : "A place to make your own.").foregroundColor(OS.dim)
                        }
                        Spacer()
                        Button("VR View", systemImage: "eye", action: openVRView).buttonStyle(.bordered)
                    }
                    if ui.page == "Home" { home }
                    if ui.page == "Library" { library }
                    if ui.page == "Spaces" {
                        Card {
                            Text("Architecture").font(.headline).padding(.bottom, 12)
                            Picker("Home style", selection: Binding(get: { settings["home_style"] }, set: { settings.set("home_style", $0) })) {
                                ForEach(Settings.items["home_style"]!.options, id: \.self) { Text($0) }
                            }.pickerStyle(.segmented)
                            Text("Pavilion and Observatory add real 3D architecture around your chosen panorama.").font(.caption).foregroundColor(OS.dim).padding(.top, 10)
                        }
                        EnvironmentGrid(settings: settings)
                    }
                    if !games.status.isEmpty { Label(games.status, systemImage: "info.circle").foregroundColor(OS.dim).font(.callout).textSelection(.enabled) }
                }.padding(32)
            }
        }.frame(minWidth: 960, minHeight: 680).background(OS.bg).foregroundColor(.white).preferredColorScheme(.dark)
    }
    private var home: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(e.connected ? "CONNECTED · \(e.device)" : "LET’S GET YOU INTO VR").font(.caption.bold()).tracking(1)
                    Spacer()
                    HStack(spacing: 18) {
                        deviceIcon("l.joystick", label: "Left controller", active: e.connected && e.controllers.0)
                        deviceIcon("visionpro", label: "Headset", active: e.connected)
                        deviceIcon("r.joystick", label: "Right controller", active: e.connected && e.controllers.1)
                    }
                }
                Text(e.nowPlaying.isEmpty ? "Welcome home." : e.nowPlaying).font(.system(size: 36, weight: .bold))
                Text(e.connected ? e.streamInfo : "Connect your Quest by USB, then open MacVR in the headset.").foregroundColor(.white.opacity(0.8))
                HStack {
                    Button(e.connected ? "Mirror headset" : "Retry USB", action: { if e.connected { openVRView() } else { e.link.retryUSB() } }).buttonStyle(.borderedProminent)
                    Button("Explore library") { ui.page = "Library" }.buttonStyle(.bordered)
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [Color(red: 0.16, green: 0.29, blue: 0.46), OS.card], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
            if !e.connectionIssue.isEmpty { Label(e.connectionIssue, systemImage: "exclamationmark.triangle").foregroundColor(.orange) }
            if !e.connected {
                Card {
                    Text("Connect in three steps").font(.headline).padding(.bottom, 12)
                    Text("1. Connect your Quest to your Mac with a USB data cable.\n2. Unlock your headset and allow USB debugging.\n3. Open MacVR in the headset. Wireless is unavailable in this build.").lineSpacing(8).foregroundColor(OS.dim)
                }
            }
            HStack(spacing: 16) {
                action("Open Steam", "gamecontroller", "Install and manage games") { games.openSteam() }
                action("Make it yours", "mountain.2", settings["environment"]) { ui.page = "Spaces" }
                action("Learn the controls", "sparkles", "Replay the in-headset tour") { e.replayTour() }
            }
        }
    }
    private func deviceIcon(_ symbol: String, label: String, active: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: 27, weight: .medium))
            .foregroundStyle(active
                ? LinearGradient(colors: [Color(red: 0.65, green: 0.3, blue: 1), Color(red: 0.15, green: 0.5, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                : LinearGradient(colors: [OS.dim.opacity(0.45), OS.dim.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 38, height: 38)
            .accessibilityLabel("\(label): \(active ? "active" : "inactive")")
            .help("\(label): \(active ? "active" : "inactive")")
    }
    private func action(_ title: String, _ symbol: String, _ subtitle: String, _ fn: @escaping () -> Void) -> some View {
        Button(action: fn) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundColor(OS.accent)
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundColor(OS.dim)
            }.frame(maxWidth: .infinity, minHeight: 110, alignment: .leading).padding(18).background(OS.card, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
    private var library: some View {
        VStack(spacing: 18) {
            HStack {
                TextField("Search games", text: $ui.query).textFieldStyle(.roundedBorder)
                Toggle("Installed", isOn: $ui.installedOnly).toggleStyle(.checkbox)
                Button("Open Steam") { games.openSteam() }
            }
            let filtered = games.library.filter { (!ui.installedOnly || $0.installed) && (ui.query.isEmpty || $0.name.localizedCaseInsensitiveContains(ui.query)) }
            if filtered.isEmpty { Text("No games here yet. Try another search or open Steam to install a game.").foregroundColor(OS.dim).padding(30) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 20) {
                ForEach(filtered, id: \.appid) { game in
                    VStack(alignment: .leading, spacing: 10) {
                        Group {
                            if let image = games.image(game.appid, "header") { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                            else { Rectangle().fill(OS.control).overlay(Image(systemName: "gamecontroller").font(.largeTitle)) }
                        }.frame(height: 110).clipped().cornerRadius(10)
                        Text(game.name).font(.headline).lineLimit(1)
                        if let progress = game.progress { ProgressView(value: progress); Text("Downloading · \(Int(progress * 100))%").font(.caption) }
                        Button(game.installed ? "Play" : "Install in Steam") { if game.installed { games.launch(game) } else { games.install(game) } }
                            .buttonStyle(.borderedProminent).disabled(game.progress != nil)
                    }.padding(12).background(OS.card, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }
}
