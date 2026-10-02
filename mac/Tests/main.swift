import Foundation
import CoreGraphics
import AppKit

// Focused interaction test for the remastered in-headset menu.
// Uses the Dashboard's own test hooks (testUV/testHasRegion/testQuery) so no
// coordinates are hardcoded: every control is clicked through its region and
// asserted through its real effect. Run via Tests/run.sh.
let testSettings = Settings()
let dash = Dashboard(settings: testSettings, games: Games())
let snd = UISounds.shared
let volSaved = snd.streamVolume, balSaved = snd.balance, monoSaved = snd.mono
let brightSaved = snd.brightness
let ctlKey = "controller_model", ctlOpts = Settings.items[ctlKey]!.options
let ctlSaved = Settings()[ctlKey]
func uv(_ id: String, _ fx: CGFloat = 0.5) -> CGPoint { dash.testUV(id, fx: fx)! }
func show(_ v: String) { dash.view = v; dash.draw() }

// every view draws without crashing and registers interactive regions
for v in ["home", "spaces", "library", "quick", "keyboard", "settings", "desktop"] {
    show(v)
    assert(dash.testRegionCount() > 10, v + " has no regions")
}
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
dash.click(uv("space:style:2")); assert(testSettings["home_style"] == "Observatory")
dash.draw(); dash.click(uv("spaces:next")); dash.draw()
assert(dash.testHasRegion("space:Starry Night"), "second page of spaces")
dash.click(uv("space:Starry Night")); assert(testSettings["environment"] == "Starry Night")
dash.draw(); dash.click(uv("spaces:next")); dash.draw()
assert(!dash.testHasRegion("spaces:next"), "last space page has no next action")
dash.click(uv("spaces:home")); assert(dash.view == "home")
show("quick"); dash.click(uv("q:env")); assert(dash.view == "spaces", "visual environment picker")
testSettings.set("show_desktop_tabs", "On")
show("quick"); dash.click(uv("workspace:Focus"))
assert(dash.view == "desktop" && dash.sideViews == ["home", "quick"], "Focus layout")
show("quick"); dash.click(uv("workspace:Play"))
assert(dash.sideViews == [nil, nil], "Play clears side windows")
show("library"); dash.click(uv("clearq")); dash.draw(); dash.click(uv("filter:3")); dash.draw()
assert(!dash.testHasRegion("sys:desktop"), "Pinned filter shows games only")
dash.click(uv("filter:0")); dash.draw()
assert(dash.testHasRegion("lib:next"), "touch-accessible library paging")
dash.click(uv("lib:next")); dash.draw()
assert(dash.testHasRegion("lib:previous"), "previous page available")
dash.click(uv("lib:previous")); dash.draw()
if let folder = ProcessInfo.processInfo.environment["MACVR_UI_CAPTURES"] {
    try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    snd.brightness = 100
    Thread.sleep(forTimeInterval: 5.1) // let transient notices expire before visual captures
    show("spaces"); dash.click(uv("spaces:previous")); dash.draw(); dash.click(uv("spaces:previous"))
    testSettings.set("environment", "Golden Bay")
    for v in ["home", "spaces", "quick", "library"] {
        show(v)
        let image = dash.context.makeImage()!
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        try! data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(v + ".png"))
    }
}
testSettings.set("environment", originalEnvironment); testSettings.set("home_style", originalStyle)
testSettings.set("menu_style", originalMenu); testSettings.set("show_desktop_tabs", originalDesktop)

// restore persisted state mutated by the test
snd.streamVolume = volSaved; snd.balance = balSaved; snd.brightness = brightSaved
if snd.mono != monoSaved { snd.mono = monoSaved }
Settings().set("controller_model", ctlSaved)
print("ALL DASHBOARD INTERACTION TESTS PASSED")
