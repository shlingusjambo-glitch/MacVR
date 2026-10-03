import Foundation
import CoreGraphics
import AppKit
import ImageIO

// Focused interaction test for the remastered in-headset menu.
// Uses the Dashboard's own test hooks (testUV/testHasRegion/testQuery) so no
// coordinates are hardcoded: every control is clicked through its region and
// asserted through its real effect. Run via Tests/run.sh.
let testSettings = Settings()
let dash = Dashboard(settings: testSettings, games: Games())
let shellKeys = ["shell.workspace", "shell.quiet"]
let originalShellValues = shellKeys.map { UserDefaults.standard.object(forKey: $0) }
for key in shellKeys { UserDefaults.standard.removeObject(forKey: key) }
let snd = UISounds.shared
let volSaved = snd.streamVolume, balSaved = snd.balance, monoSaved = snd.mono
let brightSaved = snd.brightness
let ctlKey = "controller_model", ctlOpts = Settings.items[ctlKey]!.options
let ctlSaved = Settings()[ctlKey]
func uv(_ id: String, _ fx: CGFloat = 0.5) -> CGPoint {
    guard let p = dash.testUV(id, fx: fx) else { fatalError("no region \(id) in \(dash.view)") }
    return p
}
func show(_ v: String) { dash.view = v; dash.draw() }

// every view draws without crashing and registers interactive regions
for v in ["home", "spaces", "library", "quick", "keyboard", "settings", "desktop"] {
    show(v)
    assert(dash.testRegionCount() > 10, v + " has no regions")
}
// Settings opens as a category grid, and window chrome has no global navigation/status shortcuts.
show("library")
assert(!dash.testHasRegion("win:home") && !dash.testHasRegion("win:spaces"), "window footer has no global destinations")
dash.nav("settings"); dash.draw()
assert(dash.testHasRegion("sec:updates") && !dash.testHasRegion("set:render_scale"), "Settings category landing")
dash.click(uv("sec:updates")); dash.draw()
assert(dash.testHasRegion("set:auto_updates") && dash.testHasRegion("updates:check"), "Updates category controls")
dash.click(uv("set:categories")); dash.draw()
assert(dash.testHasRegion("sec:general"), "Return to Settings categories")
assert(Settings.items["auto_updates"]?.def == "On", "updates enabled by default")
assert(Updates.newer("v1.10.0", than: "1.9.9"), "numeric release ordering")
assert(!Updates.newer("v1.2.0", than: "1.2.0") && !Updates.newer("v1.1.9", than: "1.2.0"), "no downgrade or reinstall")
assert(dash.testHasRegion("qvol") == false) // sanity: regions reset per draw

// grab bar captures the trigger press for menu dragging
show("library"); dash.draw()
assert(dash.press(uv("grab")) == .grabWindow, "window grab bar")
assert(dash.press(uv("grabdock")) == .grabDock, "dock grab bar")

// menu open routing follows game state
dash.gameActive = true; dash.opened(); assert(dash.view == "playing", "opened->playing")
dash.gameActive = false; dash.opened(); assert(dash.view == "library", "opened->library")

// headset-audio slider: press/drag/release through the drag phases
show("quick"); dash.draw()
snd.streamVolume = 10
assert(dash.press(uv("q:vol", 0.1)) == .handled, "slider captures")
dash.drag(uv("q:vol", 1)); dash.release(uv("q:vol", 1))
assert(snd.streamVolume == 100, "vol drag, got \(snd.streamVolume)")

// nil release (menu close / tracking loss mid-drag, #748): value holds,
// end sound plays, no crash — and the point sent is off-panel so desktop
// emits mouse-up without a cursor move
show("quick"); dash.draw()
snd.streamVolume = 10
assert(dash.press(uv("q:vol", 0.1)) == .handled, "slider captures 2")
dash.drag(uv("q:vol", 1))
_ = snd.takePending()
dash.release(nil)
assert(snd.streamVolume == 100, "nil release holds, got \(snd.streamVolume)")
assert(!snd.takePending().isEmpty, "nil release end sound")

// balance snaps to centre near middle (Settings > Audio)
show("settings"); dash.click(uv("sec:audio")); dash.draw()
snd.balance = 50
dash.click(uv("s:bal"))
assert(snd.balance == 0, "balance snap, got \(snd.balance)")

// brightness slider is deterministic
show("quick"); dash.draw()
dash.click(uv("q:bright", 0))
assert(snd.brightness == 20, "brightness, got \(snd.brightness)")

// mono toggle flips persisted state both ways
show("settings"); dash.click(uv("sec:audio")); dash.draw()
let m0 = snd.mono
dash.click(uv("s:mono")); assert(snd.mono != m0, "mono on")
dash.draw(); dash.click(uv("s:mono")); assert(snd.mono == m0, "mono off")

// controller row (Settings > Controllers) cycles the real setting
show("settings"); dash.click(uv("sec:controllers")); dash.draw()
let ctl0 = Settings()["controller_model"]
dash.click(uv("set:controller_model"))
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
assert(Settings()["controller_model"] != ctl0 && ctlOpts.contains(Settings()["controller_model"]), "controller cycle")

// keyboard types into search (shift is one-shot)
show("keyboard"); dash.draw()
dash.click(uv("kb:a")); dash.draw(); dash.click(uv("kbshift")); dash.draw(); dash.click(uv("kb:b"))
assert(dash.testQuery == "aB", "keyboard, got \(dash.testQuery)")

// desktop trust button fires the request callback
show("desktop"); dash.draw()
var trustFired = false
dash.requestTrust = { trustFired = true }
dash.click(uv("trust"))
assert(trustFired, "trust request")

// desktop tool key routes the keycode
var lastKey: UInt16 = 0
dash.keyCode = { lastKey = $0 }
dash.click(uv("dt:kb")); dash.draw()   // Esc now lives on the desktop keyboard's function row
dash.click(uv("dt:esc"))
assert(lastKey == 53, "esc keycode")

// menu solidity mask matches window/grab/dock geometry
assert(dash.solid(CGPoint(x: 1024.0 / 2048, y: 400.0 / CGFloat(Dashboard.H))), "solid window")
assert(dash.solid(CGPoint(x: 1024.0 / 2048, y: 952.0 / CGFloat(Dashboard.H))), "solid grab")
assert(!dash.solid(CGPoint(x: 60.0 / 2048, y: 1100.0 / CGFloat(Dashboard.H))), "transparent gap")

// sound engine renders real PCM for every bank entry
for name in ["tap", "hover", "on", "off", "back", "open", "key", "error", "launch", "slider"] {
    snd.play(name)
}
assert(!snd.takePending().isEmpty, "sound pcm")

// controller models build + device detection
assert(HeadsetModel.detect(device: "Quest 3") == .quest3)
assert(HeadsetModel.detect(device: "Oculus Quest") == .quest1)
assert(HeadsetModel.detect(device: "monterey") == .quest1)
assert(HeadsetModel.detect(device: "Quest 2") == .quest2)
assert(HeadsetModel.detect(device: "Hollywood") == .quest2)
for m in [HeadsetModel.quest1, .quest2, .quest3] {
    let n = ControllerModels.build(m, hand: 0)
    var geometryCount = 0
    n.enumerateChildNodes { node, _ in if node.geometry != nil { geometryCount += 1 } }
    assert(geometryCount > 0, "controller \(m) has renderable geometry")
}

// Home navigation, reopening, Spaces paging and architecture persistence.
let originalEnvironment = testSettings["environment"], originalStyle = testSettings["home_style"]
let originalMenu = testSettings["menu_style"], originalDesktop = testSettings["show_desktop_tabs"]
testSettings.set("menu_style", "Quest")
show("home")
dash.click(uv("home:primary")); assert(dash.view == "library")
show("home"); dash.windowOpen = false; dash.nav("home")
assert(dash.windowOpen, "same destination reopens closed window")
show("spaces")
dash.click(uv("space:style:1")); assert(testSettings["home_style"] == "Kleeblatt")
dash.draw(); dash.click(uv("spaces:next")); dash.draw()
assert(dash.testHasRegion("space:Starry Night"), "second page of spaces")
dash.click(uv("space:Starry Night")); assert(testSettings["environment"] == "Starry Night")
dash.draw(); dash.click(uv("spaces:next")); dash.draw()
assert(!dash.testHasRegion("spaces:next"), "last space page has no next action")
dash.click(uv("spaces:home")); assert(dash.view == "home")
testSettings.set("show_desktop_tabs", "On")
dash.nav("overview"); dash.draw(); dash.click(uv("overview:Focus"))
assert(dash.view == "desktop" && dash.sideViews == ["home", "quick"], "Focus layout")
dash.nav("overview"); dash.draw(); dash.click(uv("overview:Play"))
assert(dash.sideViews == [nil, nil], "Play clears side windows")
// a fixed library for everything below (the test home has no Steam)
let fake = (0..<30).map { Game(appid: "\(9000 + $0)", name: "Game \($0)", installed: $0 % 3 != 0, vr: $0 % 2 == 0) }
    + [Game(appid: "620980", name: "Beat Saber", installed: true, vr: true)]
dash.testLibrary = fake
/// Draws for `s` seconds of wall time (lets animations and scroll physics run).
func settle(_ s: Double) { let end = Date().addingTimeInterval(s); repeat { dash.draw(); usleep(16_000) } while Date() < end }
let pinnedSaved = UserDefaults.standard.stringArray(forKey: "dock.pinned"), recentSaved = UserDefaults.standard.stringArray(forKey: "dock.recent")
let sortSaved = UserDefaults.standard.integer(forKey: "lib.sort")
UserDefaults.standard.set([String](), forKey: "dock.pinned"); UserDefaults.standard.set([String](), forKey: "dock.recent")   // start clean
for k in ["9001", "9010"] { for s in ["last", "played", "render"] { UserDefaults.standard.removeObject(forKey: "app.\(k).\(s)") } }
show("library"); dash.click(uv("clearq")); dash.draw(); dash.click(uv("filter:2")); dash.draw()
assert(!dash.testHasRegion("sys:desktop"), "Pinned filter shows games only")
dash.click(uv("filter:0")); dash.draw()
assert(dash.testHasRegion("tile:9001"), "game tiles")
assert(dash.testHasRegion("lib:next"), "touch-accessible library paging")
dash.click(uv("lib:next")); dash.draw()
assert(dash.testHasRegion("lib:previous"), "previous page available")
dash.click(uv("lib:previous")); dash.draw()
// Universal Menu upgrade: exercise real callbacks and persistent restoration.
var recenterCount = 0
dash.recenter = { recenterCount += 1 }
show("home"); dash.nav("overview"); dash.draw()
assert(dash.view == "overview" && dash.testHasRegion("overview:save"))
dash.click(uv("overview:Focus")); assert(dash.view == "desktop")
dash.nav("overview"); dash.draw(); dash.click(uv("overview:save")); dash.draw()
assert(dash.testHasRegion("overview:restore"))
dash.click(uv("overview:Play")); assert(dash.sideViews == [nil, nil])
dash.nav("overview"); dash.draw(); dash.click(uv("overview:restore"))
assert(dash.view == "desktop" && dash.sideViews == ["home", "quick"], "restore saved slots")
assert(recenterCount == 0, "workspace switches and restoration preserve the menu anchor")
dash.nav("overview"); dash.draw(); dash.click(uv("overview:close:0")); dash.draw()
assert(dash.sideViews[0] == nil && !dash.testHasRegion("overview:close:0"))
dash.click(uv("overview:add:0")); dash.draw(); assert(dash.sideViews[0] == "library")
dash.click(uv("overview:open:2")); assert(dash.view == "quick" && dash.sideViews[1] == "desktop", "promote side window")
// A saved layout does not resurrect a hidden desktop or stale running-game screen.
testSettings.set("show_desktop_tabs", "Off")
dash.nav("overview"); dash.draw(); dash.click(uv("overview:restore"))
assert(dash.view == "home", "restore respects desktop preference")
testSettings.set("show_desktop_tabs", "On")
dash.nav("overview"); dash.draw(); dash.click(uv("overview:Play"))
// Search uses the existing VR keyboard; actions have real engine effects.
dash.nav("commands"); dash.draw(); dash.click(uv("command:search")); dash.draw()
assert(dash.keyboardOpen)
for ch in "center" { dash.click(uv("kb:" + String(ch))); dash.draw() }
assert(dash.testHasRegion("command:recenter") && !dash.testHasRegion("command:desktop"))
let beforeCenter = recenterCount
dash.click(uv("command:recenter")); assert(recenterCount == beforeCenter + 1)
dash.click(uv("kbdone")); dash.draw(); assert(!dash.keyboardOpen && dash.view == "commands")
dash.click(uv("command:clear")); dash.draw(); dash.click(uv("command:desktop"))
assert(dash.view == "desktop" && dash.testQuery.isEmpty, "command search does not filter the library")
dash.nav("commands"); dash.draw(); dash.click(uv("command:next")); dash.draw()
assert(dash.testHasRegion("command:previous"))
dash.click(uv("command:previous")); dash.draw()
dash.click(uv("command:search")); dash.draw(); dash.click(uv("kb:z")); dash.draw()
assert(!dash.testHasRegion("command:desktop") && !dash.testHasRegion("command:next"), "empty search")
dash.click(uv("x:grabkb")); dash.draw(); assert(!dash.keyboardOpen, "search keyboard dismiss")
// Dock hit areas stay inside the painted surface, without collisions in either style.
for style in ["Quest", "SteamVR"] {
    testSettings.set("menu_style", style)
    for active in [false, true] {
        dash.gameActive = active; dash.fps = 120
        show("home"); assert(dash.testDockGeometry(), "dock geometry \(style), active=\(active)")
    }
    show("overview"); assert(dash.testHasRegion("overview:save"))
    show("commands"); assert(dash.testHasRegion("command:search"))
}
dash.gameActive = false; testSettings.set("menu_style", "Quest")

// Window title strip: close and minimise, no Back button
show("quick"); assert(dash.testHasRegion("win:close") && dash.testHasRegion("win:min") && !dash.testHasRegion("win:back"), "close + minimise only")
dash.nav("overview"); dash.draw(); dash.click(uv("overview:Play"))

show("library"); dash.draw()
dash.click(uv("lib:next")); settle(0.3)
assert(dash.testHasRegion("lib:previous") && dash.testScroll("library")!.pos > 100, "page glides down")
dash.click(uv("lib:previous")); settle(1.2)
assert(dash.testScroll("library")!.pos < 5, "page glides back, got \(dash.testScroll("library")!.pos)")
// sort cycles and persists
let sort0 = UserDefaults.standard.integer(forKey: "lib.sort")
dash.click(uv("sort")); assert(UserDefaults.standard.integer(forKey: "lib.sort") == (sort0 + 1) % 3, "sort cycles")
dash.draw(); dash.click(uv("sort")); dash.draw(); dash.click(uv("sort")); assert(UserDefaults.standard.integer(forKey: "lib.sort") == sort0)

// swipe with momentum: a quick upward flick coasts on after the finger lifts, and stays inside the list
show("library"); dash.click(uv("filter:0")); dash.draw()
var p0 = uv("tile:620980")
dash.touchDown(p0)
for i in 1...12 { usleep(12_000); dash.drag(CGPoint(x: p0.x, y: p0.y - CGFloat(i) * 45 / CGFloat(Dashboard.H))) }
let atLift = dash.testScroll("library")!.pos
dash.touchUp(CGPoint(x: p0.x, y: p0.y - 540 / CGFloat(Dashboard.H)))
settle(2.5)
let coasted = dash.testScroll("library")!
assert(atLift > 300 && coasted.pos > atLift + 100, "flick coasts: lifted at \(atLift), rests at \(coasted.pos)")
assert(coasted.settled && coasted.pos <= coasted.limit, "flick comes to rest inside the list: \(coasted)")
// rubber band: pulling down at the top stretches past the start, then springs back to 0
dash.click(uv("filter:0")); dash.draw()
p0 = uv("tile:620980")
dash.touchDown(p0)
for i in 1...6 { usleep(12_000); dash.drag(CGPoint(x: p0.x, y: p0.y + CGFloat(i) * 60 / CGFloat(Dashboard.H))) }
let stretched = dash.testScroll("library")!.pos
assert(stretched < 0 && stretched > -300, "rubber band stretches less than the finger moved, got \(stretched)")
dash.touchUp(nil); settle(1.0)
assert(dash.testScroll("library")!.pos == 0, "springs back to the top")
// a tap is not a scroll: touching a tile and lifting fires it (launch callback for installed games)
var launched: String?
dash.launch = { launched = $0.appid }
show("library"); dash.click(uv("filter:0")); dash.draw()
dash.touchDown(uv("tile:9001")); dash.touchUp(uv("tile:9001"))
assert(launched == "9001", "touch tap launches")
// long press on a tile opens its menu; Details opens the game page; pin from there
dash.draw(); dash.touchDown(uv("tile:9010")); settle(0.75); dash.touchUp(nil); dash.draw()
assert(dash.testHasRegion("ctx:play") && dash.testHasRegion("ctx:details"), "long press opens the tile menu")
dash.click(uv("ctx:details")); dash.draw()
assert(dash.view == "appsettings" && dash.testHasRegion("as:play") && dash.testHasRegion("as:render:2"), "details page")
dash.click(uv("as:pin")); assert(UserDefaults.standard.stringArray(forKey: "dock.pinned")?.contains("9010") == true, "pin from details")
dash.draw(); dash.click(uv("as:render:2")); assert(Dashboard.override("9010", "render") == 75, "per-game resolution")
dash.draw(); dash.click(uv("as:render:0")); assert(Dashboard.override("9010", "render") == 0)
show("home"); assert(dash.testHasRegion("dock:game:9010"), "pinned game on the dock")
dash.click(uv("dock:game:9010")); dash.draw()

// universal search: a setting found from the App Library jumps to it in Settings
show("keyboard"); dash.draw()
for ch in "contrast" { dash.click(uv("kb:" + String(ch))); dash.draw() }
assert(dash.testQuery == "contrast", "keyboard types into search")
show("keyboard"); dash.click(uv("clearq")); dash.draw()
// word suggestions complete the current word
for ch in "sab" { dash.click(uv("kb:" + String(ch))); dash.draw() }
assert(dash.testHasRegion("kbsugg:0"), "suggestion offered")
dash.click(uv("kbsugg:0")); assert(dash.testQuery == "saber", "suggestion completes the word, got \(dash.testQuery)")
dash.draw(); dash.click(uv("clearq")); dash.draw()
// caps lock (double tap shift), symbols layer
dash.click(uv("kbshift")); dash.draw(); dash.click(uv("kbshift")); dash.draw()
dash.click(uv("kb:a")); dash.draw(); dash.click(uv("kb:b")); dash.draw()
assert(dash.testQuery == "AB", "caps lock stays on, got \(dash.testQuery)")
dash.click(uv("kbshift")); dash.draw(); dash.click(uv("kb:c")); dash.draw()
dash.click(uv("kblayer")); dash.draw(); dash.click(uv("kb:1")); dash.draw(); dash.click(uv("kblayer")); dash.draw()
assert(dash.testQuery == "ABc1", "caps off + symbols, got \(dash.testQuery)")
dash.click(uv("clearq")); dash.draw()

// Settings search on the pop-up keyboard; a result row works in place
show("settings"); dash.click(uv("set:search")); dash.draw()
assert(dash.keyboardOpen, "settings search opens the keyboard")
for ch in "touch" { dash.click(uv("kb:" + String(ch))); dash.draw() }
assert(dash.testSettingsQuery == "touch" && dash.testHasRegion("set:direct_touch"), "settings search results")
let touch0 = testSettings["direct_touch"]
dash.click(uv("set:direct_touch")); assert(testSettings["direct_touch"] != touch0, "result row toggles")
testSettings.set("direct_touch", touch0)
dash.draw(); dash.click(uv("kbdone")); dash.draw(); assert(!dash.keyboardOpen, "Done closes the keyboard")
dash.click(uv("set:clear")); dash.draw(); assert(dash.testSettingsQuery.isEmpty)
// segmented choices pick a value directly
dash.click(uv("sec:video")); dash.draw(); let br0 = testSettings["bitrate"]
dash.click(uv("set:bitrate:3")); assert(testSettings["bitrate"] == "60", "segmented setting"); testSettings.set("bitrate", br0)
let hand0 = Dashboard.pointingHand
dash.draw(); dash.click(uv("sec:controllers")); dash.draw(); dash.click(uv("set:hand:0")); assert(Dashboard.pointingHand == 0, "pointing hand")
Dashboard.pointingHand = hand0

// accessibility: left-handed mirrors the dock and swaps Delete/Shift; every option draws
let a11y = ["text_size", "high_contrast", "reduce_motion", "left_handed"].map { ($0, testSettings[$0]) }
testSettings.set("left_handed", "On"); show("keyboard")
assert(dash.testRegion("dock:quick")!.minX > dash.testRegion("dock:library")!.minX, "mirrored dock")
assert(dash.testRegion("kbdel")!.minX < dash.testRegion("kbshift")!.minX, "left-handed keyboard")
testSettings.set("text_size", "Largest"); testSettings.set("high_contrast", "On"); testSettings.set("reduce_motion", "On")
for v in ["home", "library", "quick", "settings", "notifications"] { show(v); assert(dash.testRegionCount() > 10, v + " with accessibility options") }
for (k, v) in a11y { testSettings.set(k, v) }

// power menu: from the dock (Show Power Options), refresh video, recenter, resume, tap outside to close
let powerSaved = testSettings["show_power"]; testSettings.set("show_power", "On")
var refreshed = false, recentered = false, closed = false
dash.refreshStream = { refreshed = true }; dash.recenter = { recentered = true }; dash.close = { closed = true }
show("home"); dash.click(uv("dock:power")); dash.draw(); assert(dash.testPowerOpen, "power menu opens")
dash.click(uv("power:refresh")); assert(refreshed, "refresh video")
dash.draw(); dash.click(uv("power:recenter")); assert(recentered && !dash.testPowerOpen, "recenter closes the menu")
show("quick"); dash.click(uv("q:power")); dash.draw(); dash.click(uv("power:resume")); assert(closed && !dash.testPowerOpen, "resume closes the menu")
dash.click(uv("dock:power")); dash.draw(); dash.click(uv("power:dismiss", 0.02)); assert(!dash.testPowerOpen, "tap outside closes")
dash.click(uv("dock:power")); dash.draw(); dash.click(uv("power:exit")); dash.draw()
assert(dash.testPowerOpen && dash.testHasRegion("power:exit"), "Quit MacVR asks again before quitting")
dash.click(uv("power:cancel")); testSettings.set("show_power", powerSaved)

// notifications: grouping, repeats count up, actions, dismiss, Do Not Disturb, the toast is solid above the dock
dash.clearNotices()
assert(Dashboard.noticeKind("Launching Beat Saber…") == "Games" && Dashboard.noticeKind("View recentered") == "System"
       && Dashboard.noticeKind("Opening Steam install for X…") == "Downloads" && Dashboard.noticeKind("Headset connected over USB") == "Connection")
show("home")
dash.note("Downloading Game 3: 10%"); dash.note("View recentered"); dash.note("View recentered")
assert(dash.notices.count == 2 && dash.notices[0].count == 2 && dash.unread == 3, "repeats count up")
dash.draw()
let toast = dash.testRegion("toast")!
assert(toast.minY > CGFloat(Dashboard.SPLIT) && dash.solid(CGPoint(x: toast.midX / 2048, y: toast.midY / CGFloat(Dashboard.H))), "toast above the dock, solid")
var acted = false
dash.note("Mac Desktop is turned off", kind: "System", action: ("Turn On", { acted = true }))
show("notifications"); assert(dash.unread == 0, "opening Notifications marks them read")
let actID = dash.notices[0].id
dash.click(uv("n:act:\(actID)")); assert(acted && !dash.notices.contains { $0.id == actID }, "action runs and clears it")
dash.draw(); dash.click(uv("n:x:\(dash.notices[0].id)")); assert(dash.notices.count == 1, "dismiss one")
dash.draw(); dash.click(uv("n:clear:Downloads")); assert(dash.notices.isEmpty, "clear a group")
let dndSaved = testSettings["dnd"]; testSettings.set("dnd", "On")
show("home"); dash.note("Quiet please"); dash.draw()
assert(!dash.testHasRegion("toast") && dash.notices.count == 1, "Do Not Disturb collects without a toast")
testSettings.set("dnd", dndSaved); dash.clearNotices()
assert(Dashboard.ago(Date().addingTimeInterval(-30)) == "Just now" && Dashboard.ago(Date().addingTimeInterval(-300)) == "5 min ago"
       && Dashboard.ago(Date().addingTimeInterval(-7200)) == "2 h ago" && Dashboard.ago(Date().addingTimeInterval(-30 * 3600)) == "Yesterday")
assert(Dashboard.duration(30) == "Under a minute" && Dashboard.duration(2520) == "42 min" && Dashboard.duration(10800) == "3 h" && Dashboard.duration(11520) == "3 h 12 min")

// welcome tour: every step draws; the comfort step sets the text size
for n in 0..<12 { dash.testTourStep(n); dash.draw(); assert(n == 11 || dash.testHasRegion("tour:next"), "tour step \(n)") }
dash.testTourStep(5); dash.draw(); dash.click(uv("tour:text1")); assert(testSettings["text_size"] == "Large", "tour text size")
testSettings.set("text_size", a11y[0].1)
dash.view = "home"

// pure logic: library order, word suggestions, settings search, scroll physics
let lib5 = [Game(appid: "a", name: "Beat Saber", installed: true, vr: true), Game(appid: "b", name: "Lightsaber Duel", installed: false, vr: true),
            Game(appid: "c", name: "Saber Tooth", installed: true, vr: false), Game(appid: "d", name: "Café Racer", installed: true, vr: false),
            Game(appid: "e", name: "Alyx", installed: true, vr: true)]
func ids(_ g: [Game]) -> String { g.map(\.appid).joined() }
let last: [String: Double] = ["c": 100, "a": 50], played: [String: Double] = ["d": 500]
func arrange(_ q: String, _ f: Int, _ s: Int, pinned: Set<String> = []) -> String {
    ids(Dashboard.arrange(lib5, query: q, filter: f, sort: s, pinned: pinned, last: { last[$0] ?? 0 }, played: { played[$0] ?? 0 }))
}
assert(arrange("saber", 0, 1) == "acb", "search ranks word starts first, got \(arrange("saber", 0, 1))")
assert(arrange("cafe", 0, 0) == "d", "accent-insensitive search")
assert(arrange("", 3, 1) == "dc" && arrange("", 1, 1) == "eadc" && arrange("", 4, 1, pinned: ["e"]) == "e" && arrange("", 2, 1) == "eab", "filters")
assert(arrange("", 0, 0) == "caedb", "recent: last played, then installed A-Z, got \(arrange("", 0, 0))")
assert(arrange("", 0, 2) == "deacb", "most played, got \(arrange("", 0, 2))")
assert(Dashboard.suggest("I want to pla", ["place", "play", "plan", "planet", "pull"]) == ["place", "play", "plan"])
assert(Dashboard.suggest("He", ["hello", "help", "he"]) == ["Hello", "Help"] && Dashboard.suggest("done ", ["done"]).isEmpty)
assert(Dashboard.settingsMatching("touch") == ["direct_touch"] && Dashboard.settingsMatching("contrast") == ["high_contrast"])
assert(Dashboard.settingsMatching("accessibility").count == 4 && Dashboard.settingsMatching("zzz").isEmpty)
var f = Flick(); f.limit = 1000
f.grab(at: 0); f.drag(to: -400, at: 0.016)
assert(f.pos < 0 && f.pos > -Flick.band, "rubber band, got \(f.pos)")
f.release(at: 0.02); for _ in 0..<120 { f.step(1.0 / 60) }
assert(f.pos == 0 && f.settled, "springs back, got \(f.pos)")
f.grab(at: 1); for i in 1...6 { f.drag(to: CGFloat(i) * 50, at: 1 + Double(i) * 0.016) }
f.release(at: 1.1); assert(f.vel > 2000, "release velocity, got \(f.vel)")
var maxPos: CGFloat = 0
for _ in 0..<240 { f.step(1.0 / 60); maxPos = max(maxPos, f.pos) }
assert(f.settled && f.pos > 600 && f.pos <= 1000, "coasts and stops, got \(f.pos)")
f = Flick(); f.limit = 300; f.vel = 4000; maxPos = 0
for _ in 0..<240 { f.step(1.0 / 60); maxPos = max(maxPos, f.pos) }
assert(f.pos == 300 && maxPos > 300 && maxPos < 300 + Flick.band, "bounces off the end, peak \(maxPos)")
f = Flick(); f.limit = 2000; f.glide(400)
for _ in 0..<300 { f.step(1.0 / 60) }
assert(abs(f.pos - 400) < 6, "page glide lands, got \(f.pos)")

if let folder = ProcessInfo.processInfo.environment["MACVR_UI_CAPTURES"] {   // visual review: PNGs of views and states
    try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    func cap(_ name: String, _ wait: Double = 0.45) {
        settle(wait)
        let data = NSBitmapImageRep(cgImage: dash.context.makeImage()!).representation(using: .png, properties: [:])!
        try! data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }
    snd.brightness = 100
    dash.note("Your workspace is ready"); dash.note("Welcome to your new Universal Menu")
    Thread.sleep(forTimeInterval: 5.1) // let transient notices expire before visual captures
    show("spaces"); dash.click(uv("spaces:previous")); dash.draw(); dash.click(uv("spaces:previous"))
    testSettings.set("environment", "Golden Bay")
    for v in ["home", "spaces", "quick", "library", "overview", "commands", "settings", "notifications"] { show(v); cap(v) }
    dash.clearNotices()
    dash.note("Opening Steam install for Half-Life: Alyx…", kind: "Downloads"); dash.note("Launching Beat Saber…", 4)
    dash.note("Headset connected over USB"); dash.note("View recentered"); dash.note("View recentered")
    dash.note("Mac Desktop is turned off", 6, kind: "System", action: ("Turn On", {}))
    show("home"); cap("toast", 0.5)
    dash.windowOpen = false; cap("toast-closed", 0.1); dash.windowOpen = true
    show("notifications"); cap("notifications-full")
    testSettings.set("show_power", "On"); show("home"); dash.click(uv("dock:power")); cap("power")
    dash.click(uv("power:cancel"))
    show("library"); dash.draw(); dash.touchDown(uv("tile:620980")); settle(0.75); dash.touchUp(nil); cap("context")
    dash.click(uv("ctx:details")); cap("details")
    show("keyboard"); dash.draw(); for ch in "sab" { dash.click(uv("kb:" + String(ch))); dash.draw() }
    dash.pointer(uv("kb:g")); cap("keyboard")
    dash.click(uv("clearq"))
    show("settings"); dash.click(uv("set:search")); dash.draw(); for ch in "mo" { dash.click(uv("kb:" + String(ch))); dash.draw() }; cap("settings-search")
    dash.click(uv("set:clear")); dash.click(uv("kbdone")); dash.draw()
    for s in ["menu", "accessibility", "audio"] { dash.click(uv("sec:" + s)); cap("settings-" + s) }
    show("library"); dash.pointer(uv("tile:9001")); cap("hover")
    testSettings.set("text_size", "Largest"); testSettings.set("high_contrast", "On"); show("home"); cap("a11y-home"); show("quick"); cap("a11y-quick")
    testSettings.set("text_size", "Default"); testSettings.set("high_contrast", "Off")
    testSettings.set("left_handed", "On"); show("keyboard"); cap("lefthanded"); testSettings.set("left_handed", "Off")
    testSettings.set("menu_style", "SteamVR"); for v in ["home", "quick", "library"] { show(v); cap("steamvr-" + v) }; testSettings.set("menu_style", "Quest")
    for n in [5, 10] { dash.testTourStep(n); cap("tour\(n)") }
    dash.view = "home"; testSettings.set("show_power", "Off")
}
testSettings.set("environment", originalEnvironment); testSettings.set("home_style", originalStyle)
testSettings.set("menu_style", originalMenu); testSettings.set("show_desktop_tabs", originalDesktop)
UserDefaults.standard.set(pinnedSaved, forKey: "dock.pinned"); UserDefaults.standard.set(recentSaved, forKey: "dock.recent")
UserDefaults.standard.set(sortSaved, forKey: "lib.sort")
for k in ["9001", "9010"] { for s in ["last", "played", "render"] { UserDefaults.standard.removeObject(forKey: "app.\(k).\(s)") } }

for (key, value) in zip(shellKeys, originalShellValues) {
    if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
}

// update channels: public beats its betas, betas order by number
assert(Updates.newer("1.4.0", than: "1.4.0-beta.3") && Updates.newer("1.4.0-beta.2", than: "1.4.0-beta.1") && Updates.newer("v1.4.0-beta.1", than: "1.3.9"))
assert(!Updates.newer("1.4.0-beta.9", than: "1.4.0") && !Updates.newer("1.3.0", than: "1.3.0") && Updates.newer("1.10.0", than: "1.9.9"))
// skin colour: only with Show arms; a toggle inside the picker, then any colour from the field
let skinSaved = testSettings["avatar_skin"], armsSaved = testSettings["show_arms"]
testSettings.set("show_arms", "Off"); testSettings.set("avatar_skin", "Original")
show("settings"); dash.click(uv("sec:experimental")); dash.draw()
assert(!dash.testHasRegion("set:avatar_skin") && !dash.testHasRegion("set:show_body") && !dash.testHasRegion("set:home_mirror"), "avatar options hidden without arms")
testSettings.set("show_arms", "On"); dash.draw()
for _ in 0..<12 where !dash.testHasRegion("set:avatar_skin") { _ = dash.scroll(-1, at: CGPoint(x: 0.6, y: 0.4)); dash.draw() }
assert(dash.testHasRegion("set:show_body") && dash.testHasRegion("set:avatar_skin") && !dash.testHasRegion("skin:field"), "toggle shown, field hidden while off")
dash.click(uv("set:avatar_skin")); dash.draw()
assert(testSettings["avatar_skin"].hasPrefix("#"), "toggle on picks a colour")
for _ in 0..<12 where !dash.testHasRegion("skin:field") { _ = dash.scroll(-1, at: CGPoint(x: 0.6, y: 0.4)); dash.draw() }
assert(dash.press(uv("skin:field", 0.1)) == .handled, "colour field captures")
dash.drag(uv("skin:field", 0.6)); dash.release(uv("skin:field", 0.6)); dash.draw()
let picked = testSettings["avatar_skin"]
assert(picked.hasPrefix("#") && picked.count == 7, "custom colour saved, got \(picked)")
if let out = ProcessInfo.processInfo.environment["SKIN_PNG"], let img = dash.context.makeImage(),
   let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d) }
dash.click(uv("set:avatar_skin")); assert(testSettings["avatar_skin"] == "Original", "toggle off restores the original hands")
testSettings.set("avatar_skin", skinSaved.isEmpty ? "Original" : skinSaved); testSettings.set("show_arms", armsSaved.isEmpty ? "Off" : armsSaved)
// restore persisted state mutated by the test
snd.streamVolume = volSaved; snd.balance = balSaved; snd.brightness = brightSaved
if snd.mono != monoSaved { snd.mono = monoSaved }
Settings().set("controller_model", ctlSaved)
print("ALL DASHBOARD INTERACTION TESTS PASSED")
