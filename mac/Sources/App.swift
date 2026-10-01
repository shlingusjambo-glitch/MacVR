import SwiftUI
import AppKit

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
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
            Engine().snapshot(to: CommandLine.arguments[i + 1]); exit(0)
        }
    }

    var body: some Scene {
        Window("MacVR", id: "status") { StatusView().environmentObject(engine) }
            .windowStyle(.hiddenTitleBar).windowResizability(.contentSize)
        Window("MacVR Settings", id: "settings") { SettingsView(e: engine, settings: engine.settings, games: engine.games) }
            .windowStyle(.hiddenTitleBar).windowResizability(.contentSize)
        Window("VR View", id: "vrview") { VRViewWindow(engine: engine).frame(minWidth: 320, minHeight: 320) }
            .defaultSize(width: 640, height: 700)
    }
}

// MARK: MacVR OS look for the Mac windows (same slate glass + gradient badges as the in-headset shell)
enum OS {
    static let bg = LinearGradient(colors: [Color(red: 0.18, green: 0.21, blue: 0.26), Color(red: 0.11, green: 0.13, blue: 0.16)], startPoint: .top, endPoint: .bottom)
    static let card = Color.white.opacity(0.06), stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.18, green: 0.55, blue: 1)
    static let dim = Color(white: 0.62)
    static func grad(_ a: UInt32, _ b: UInt32) -> LinearGradient {
        func c(_ v: UInt32) -> Color { Color(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255) }
        return LinearGradient(colors: [c(a), c(b)], startPoint: .top, endPoint: .bottom)
    }
}
/// Rounded gradient icon badge (like the dock's app icons / System Settings).
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
            .background(RoundedRectangle(cornerRadius: 14).fill(OS.card)).overlay(RoundedRectangle(cornerRadius: 14).stroke(OS.stroke))
    }
}
struct PillButton: View {
    let title: String, symbol: String; var primary = false; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { Image(systemName: symbol); Text(title).fontWeight(.semibold) }
                .font(.system(size: 13)).foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(Capsule().fill(primary ? AnyShapeStyle(OS.accent) : AnyShapeStyle(Color.white.opacity(0.1))))
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
        StatusBody(e: e, games: e.games, openSettings: { openWindow(id: "settings") }, openVRView: { openWindow(id: "vrview") })
    }
}

struct StatusBody: View {
    @ObservedObject var e: Engine
    @ObservedObject var games: Games
    var openSettings: () -> Void, openVRView: () -> Void
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    private var playing: Game? { e.nowPlaying.isEmpty ? nil : games.library.first { e.nowPlaying.localizedCaseInsensitiveContains($0.name) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Badge(symbol: "visionpro", top: 0x3aa0ff, bottom: 0x7040e0, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MacVR OS").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                    Text("Version \(version)").font(.system(size: 11)).foregroundColor(OS.dim)
                }
                Spacer()
                Button(action: openVRView) { Image(systemName: "eye") }.buttonStyle(.plain).help("Display VR View")
                Button(action: openSettings) { Image(systemName: "gearshape.fill") }.buttonStyle(.plain).help("Settings")
            }.font(.system(size: 15)).foregroundColor(OS.dim).padding(.top, 6)

            Card {
                HStack(spacing: 14) {
                    HeadsetShape().fill(e.connected ? AnyShapeStyle(OS.grad(0x3aa0ff, 0x1467e0)) : AnyShapeStyle(Color.white.opacity(0.15)))
                        .frame(width: 52, height: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.connected ? e.device : "No headset").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                        HStack(spacing: 6) {
                            Circle().fill(e.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
                            Text(e.connected ? e.streamInfo : "Open MacVR on your Quest (USB or same Wi-Fi)").font(.system(size: 11)).foregroundColor(OS.dim)
                        }
                    }
                    Spacer()
                }
                if e.connected {
                    HStack(spacing: 10) {
                        controller("Left", e.hands.0); controller("Right", e.hands.1)
                    }.padding(.top, 12)
                }
            }

            Card {
                Text("NOW PLAYING").font(.system(size: 10, weight: .bold)).foregroundColor(OS.dim).tracking(1)
                HStack(spacing: 12) {
                    if let g = playing, let art = games.image(g.appid, "header") {
                        Image(decorative: art, scale: 1).resizable().aspectRatio(contentMode: .fill).frame(width: 92, height: 43).clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Badge(symbol: e.nowPlaying.isEmpty ? "house.fill" : "gamecontroller.fill", top: 0x4fd18b, bottom: 0x1f9d5c, size: 43)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.nowPlaying.isEmpty ? "MacVR Home" : (playing?.name ?? e.nowPlaying)).font(.system(size: 15, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                        Text(e.nowPlaying.isEmpty ? e.settings["environment"] : "Running in VR").font(.system(size: 11)).foregroundColor(OS.dim)
                    }
                }.padding(.top, 8)
            }

            if !games.status.isEmpty { Text(games.status).font(.system(size: 11)).foregroundColor(OS.dim) }
            PillButton(title: "Open Steam", symbol: "arrow.up.forward.app", primary: true) { e.games.openSteam() }
            Text("\(games.library.count) games owned · \(games.library.filter(\.installed).count) installed · \(games.library.filter(\.vr).count) VR")
                .font(.system(size: 11)).foregroundColor(OS.dim).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 10)
        .frame(width: 360)
        .background(OS.bg)
    }
    private func controller(_ side: String, _ on: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "gamecontroller.fill").foregroundColor(on ? OS.accent : Color.white.opacity(0.25))
            Text(side).font(.system(size: 11)).foregroundColor(on ? .white : OS.dim)
            Spacer()
            Text(on ? "Tracking" : "Off").font(.system(size: 10)).foregroundColor(OS.dim)
        }.padding(.horizontal, 10).padding(.vertical, 7).background(Capsule().fill(Color.white.opacity(0.06)))
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
        ("games", "Games", "square.stack.3d.up.fill", 0x2f5b9e, 0x16274a), ("about", "About", "info.circle.fill", 0x6b7685, 0x4a5462),
    ]
    static let keys: [String: [String]] = [
        "general": ["render_scale", "refresh_rate"], "video": ["bitrate", "codec", "show_fps"],
        "controllers": ["controller_model", "system_button"], "environment": ["floor_grid"],
        "menu": ["dashboard_position", "ui_curved", "show_desktop_tabs", "show_settings_tab", "show_power"],
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
                    .background(RoundedRectangle(cornerRadius: 8).fill(ui.section == s.id ? Color.white.opacity(0.12) : .clear))
                    .contentShape(Rectangle()).onTapGesture { ui.section = s.id }
                }
                Spacer()
            }
            .padding(.horizontal, 10).frame(width: 220).background(Color.black.opacity(0.22))

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
        if let it = Settings.items[key] {
            HStack {
                Text(it.label).font(.system(size: 13)).foregroundColor(.white)
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
}
struct AudioCard: View {
    @ObservedObject var prefs: AudioPrefs
    var body: some View {
        Card {
            slider("Headset Audio", "speaker.wave.2.fill", Binding(get: { prefs.stream }, set: { prefs.stream = $0 }), 0...100, "%")
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
        Text("Applied the next time the game starts.").font(.system(size: 11)).foregroundColor(OS.dim)
    }
    private func pick(_ g: Game, _ key: String, _ label: String, _ opts: [Int]) -> some View {
        Picker(label, selection: Binding(get: { Dashboard.override(g.appid, key) }, set: { Dashboard.setOverride(g.appid, key, $0); tick.bump() })) {
            ForEach(opts, id: \.self) { Text($0 == 0 ? "Default" : "\($0)%").tag($0) }
        }.frame(width: 150)
    }
}
final class Ticker: ObservableObject { func bump() { objectWillChange.send() } }
