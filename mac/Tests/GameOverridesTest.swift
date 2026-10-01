import Foundation

@main struct GameOverridesTest {
    static func main() {
        let suite = "MacVR.overrides.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var writes: [(Float, Float)] = []
        let session = GameOverrides(defaults: defaults) { writes.append(($0, $1)) }
        defaults.set(75, forKey: "app.game.render")
        defaults.set(125, forKey: "app.game.world")
        session.start("game")
        precondition(writes.last!.0 == 0.75 && writes.last!.1 == 1.25)
        defaults.set(200, forKey: "app.game.world")
        session.changed("game", key: "world")
        precondition(writes.last!.1 == 2)
        let count = writes.count
        session.changed("other", key: "world")
        defaults.set(150, forKey: "app.game.render")
        session.changed("game", key: "render")
        precondition(writes.count == count, "Other games and resolution changes cannot affect the running session")
        defaults.set(0, forKey: "app.game.world")
        session.changed("game", key: "world")
        precondition(writes.last!.0 == 0.75 && writes.last!.1 == 0, "Default world scale must retain launch resolution")
        session.stop()
        precondition(writes.last!.0 == 0 && writes.last!.1 == 0)
        let stopped = writes.count
        session.changed("game", key: "world")
        precondition(writes.count == stopped)
        session.start("game")
        precondition(writes.last!.0 == 1.5, "Resolution takes effect on the next launch")
        print("PASS: launch overrides, live world scale, game isolation, resolution restart, defaults and stop")
    }
}
