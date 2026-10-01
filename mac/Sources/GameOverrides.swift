import Foundation

/// Render-queue owned. Resolution is latched at launch; world scale can change live.
final class GameOverrides {
    private let defaults: UserDefaults
    private let write: (Float, Float) -> Void
    private var appid: String?
    private var render: Float = 0

    init(defaults: UserDefaults = .standard, write: @escaping (Float, Float) -> Void) {
        self.defaults = defaults; self.write = write
    }
    private func value(_ id: String, _ key: String) -> Float {
        Float(defaults.integer(forKey: "app.\(id).\(key)")) / 100
    }
    func start(_ id: String) {
        appid = id; render = value(id, "render")
        write(render, value(id, "world"))
    }
    func changed(_ id: String, key: String) {
        guard id == appid, key == "world" else { return }
        write(render, value(id, "world"))
    }
    func stop() { appid = nil; render = 0; write(0, 0) }
}
