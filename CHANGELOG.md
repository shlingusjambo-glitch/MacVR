# Changes

## 1.2.1

- Fix transparent hands appearing behind menu panels, pickers and Mac windows.
- Fix hidden hands when body mode is enabled outside a home environment.
- Simplify Quick Settings, Settings categories and the Library; keep per-game menus.
- Highlight hovered controls without moving them or recentering windows.
- Add GitHub release updates for MacVR, WineXR and SiliconXR, enabled by default.
- Add model-based homes with stick-activated teleport points and an arcing pointer.
- Add experimental rigged arms, torso, skin colours and a stationary mirror.
- Restore the original flat hand appearance: default grey is translucent; other skin tones are opaque. No neck or head mesh.
- Improve controller pointer placement, surface-aligned activation rings and UI proximity fading.

## 1.2.0

### Universal Menu: the big update

- Home: a "Continue playing" card with your last game's art, when you last played and your total play time, plus Play and Details. Next to it, a tip of the day (or Steam news for your games) and four quick actions. Your recent games sit underneath.
- Swipe to scroll everywhere a list scrolls: lists keep gliding after you let go, stretch a little at the ends and spring back. Touching a moving list stops it. The Previous and Next buttons glide a page.
- Touch and hold a game (finger or pinch) to open its menu. A ring fills while you hold.
- App Library: filter by All, Installed, VR, Flat or Pinned, and sort by Recent, A–Z or Most Played. Search finds games, built-in apps and settings as you type, ignores accents, and lists names that start with your words first. Built-in apps are one tidy row.
- Game details page: big art, VR or flatscreen, installed or downloading, last played and play time, Play, Play in Theater, Pin to Dock, Uninstall, and the per-game resolution, world scale and Theater options.
- Pinned games stay on the dock (up to six), ahead of your recent games. Games without art show their initial.
- Quick Settings: a big clock, live status chips (USB or Wi-Fi, headset, stream bitrate, fps) and ten tiles: Recenter, Theater, Direct Touch, Headset Mic, Do Not Disturb, Stream Quality, Menu Style, Text Size, Notifications and Quit Game (or how to use your hands). The Environment card shows a peek of your home.
- Power menu, from the dock's power button (Settings > Universal Menu > Show Power Options) or Quick Settings: Resume or Close Menu, Quit Game, Recenter, Refresh Video (fixes a frozen or blocky picture), Theater and Quit MacVR, which asks twice.
- Notifications: grouped into Games, Downloads, Connection and System, with times like "5 min ago". Repeats count up instead of piling up. Clear one, a group or everything. Some come with a button, such as "Turn On" when Mac Desktop is switched off.
- Pop-ups slide in just above the dock, so they never cover what you're doing. Tap one to open Notifications. Do Not Disturb (Quick Settings, Notifications or Settings) keeps them quiet; they still collect in Notifications.
- Settings: search, a short description under every setting, choices you tap directly instead of cycling, picture previews for the two menu styles, and Pointing Hand under Controllers. Settings opens from Quick Settings even when its dock icon is hidden.
- Accessibility (new Settings section, also in the Mac's Settings window): Text Size (Default, Large, Largest), High Contrast, Reduce Motion and a Left-Handed Layout that mirrors the dock and moves Delete and Done to the keyboard's left. The welcome tour asks for your text size.
- Keyboard: word suggestions as you type (game names in search, everyday words on the Mac), Shift, caps lock (tap Shift twice), a 123 layer for numbers and symbols, a bubble that pops up from each key you press, and no dead gaps between keys for fingertips.
- Motion: tiles lift with a soft shadow when you point at them and sink when pressed, windows fade up into place when you switch apps, switches slide, the selection in a choice glides across, and dock names fade in. Reduce Motion turns all of it off.
- The welcome tour shows "Step 3 of 12", has a hand-tracking step, and its progress bar stretches into the next step.
- Fixes: a pop-up no longer blocks the button under it; Quick Settings > Settings no longer bounces you to the App Library when the dock's Settings icon is hidden.

### Workspace and Search

- Each spatial window has its own Back history. Moving windows carries their history; switching workspace presets clears stale navigation.
- Workspace overview exposes left, center, and right windows. Add Library or controls to an empty slot, close a side window, bring it to the center, or switch to Play, Focus, and Explore layouts.
- Save and restore a custom workspace, including window destinations, panorama, and home architecture. Restoration recenters the layout, respects disabled destinations, and never launches a game automatically.
- Search apps, Steam games, and system actions using the VR keyboard. Launch/install games, recenter, switch theater, or turn Do Not Disturb on or off from paginated results. Search does not change the Library filter.

### MacVR OS shell update

- Mac windows in VR: tap Mac Windows in Quick Settings and pick any open Mac window (cards with a live thumbnail). It floats beside the menu as its own panel, sharp at Retina resolution.
  - Point and pull the trigger to click and drag in it, grip to right-click, thumbstick up/down to scroll, left/right to make it bigger or smaller.
  - The bar under it moves it anywhere around you (it turns to face you; push or pull with the stick). Grab the bar with both hands and pull them apart to resize.
  - Bar buttons: keyboard (types into that window), pin (it stays when the menu closes, and you can still use it), and close.
  - The window you're using is lit and the others dim slightly; each casts a soft shadow. If the window closes on the Mac, it closes in VR.
  - Clicking needs MacVR allowed under Accessibility, like the Mac Desktop view.
- Screenshots: hold the menu button (≡) and pull a trigger, or tap Screenshot in Quick Settings. The headset view is saved to Pictures > MacVR, with a shutter sound and a thumbnail toast. Works in games too, and the game doesn't see that trigger pull.
- Headset battery: the menu's status line shows the headset's charge, and MacVR warns you at 10%.
- Performance Overlay (Settings > Display & Video): frame rate, render and encode time, stream bitrate, the headset's decode rate, latency and dropped frames, and battery. It floats in your view, in games too.
- Auto bitrate now adapts: when frames back up on the cable or the headset drops them, MacVR lowers the stream bitrate right away, then raises it again after a few clean seconds. The Performance Overlay shows the current target.
- Notifications reach you while the menu is closed: a small toast below your view, in games too.
- Smooth transitions: changing your Space crossfades the panoramas, entering or leaving Theater fades the room, and leaving a game fades your home back in from black.
- Launching a VR game closes the menu and takes you to a starry loading space with the game's card and a spinner until the game's first frame. If the game hasn't started after 90 seconds, you're taken home and told to check your Mac.
- Theater (Settings > Display & Video): pick the screen size (Small, Medium, Large, IMAX), a curved or flat screen, and the room lights. Dark is a cinema where the picture's colour spills onto the floor and glows around the screen; Dim darkens your Space around it; Home keeps your Space as it is.
- Windows spring into their slot when you let go of them. With side windows open, the one you're pointing at stays bright and the others dim slightly.
- Reduce Motion (Settings > Universal Menu) turns off fades, hops and glides.
- New pointer cursor: a ring where your laser meets the menu. With hand tracking it closes in as your thumb and index come together and fills when you pinch; with controllers the trigger does the same. The hand laser is fainter.

### Home & Universal Menu update

- New Home destination: personal greeting, return to your running game, recently launched installed games, and shortcuts to desktop, controls, recentering, and Spaces.
- Home is always available in the dock. Quest windows also have Home and Spaces navigation in their title bar; selecting a closed destination reopens it.
- Spaces: browse all 13 panoramas with large preview cards, selection indicators, and explicit paging. Choose Open vista, Pavilion, or Observatory architecture independently of the panorama.
- Pavilion adds a grounded platform, timber columns, warm light accents, and planters. Observatory adds a platform, cool light accents, and overhead orbital rings. Geometry is static and hidden during games, theater, and the welcome tour.
- Quick Settings workspaces: Play clears side windows, Focus opens Mac Desktop with Home and controls beside it, Explore opens Spaces with Home and Library beside it. Existing window dragging remains available.
- Library: pinned-game filter, visible game action menus, and Previous/Next controls for browsing without a thumbstick. Quick Settings opens the visual space picker.
- Resizable Mac companion with Home, searchable Library, Spaces, headset mirroring, and USB setup guidance.
- UI and touch test scripts now enable assertions. Added navigation, paging, workspace, and home-geometry checks; fixed the original Oculus Quest model alias.


### Hands, menu and fixes

- Possible unfixed bug where MacVR could DoS your local network. The feature (Wi-Fi discovery and Wi-Fi play) is disabled until we confirm it was MacVR that did this. Use the USB connection until then. MacVR now only listens on loopback.

- Menu style: pick Quest (compact dock, windows with a bottom title bar) or SteamVR (the previous wide bar) in the welcome tour or Settings > Universal Menu.
- Quest style puts the menu close: a small window at arm's length and the dock low, near your hands.
- Translucent, life-size hands hold the controllers in MacVR Home (Quest 1, 2, 3 and Steam Frame controllers) and fade out toward the wrist. Fingers follow the trigger, grip, thumbstick, thumbrest and face buttons, and the controller's buttons, trigger, grip and stick move with your input.
- Hand tracking: put the controllers down and the same hands follow your real fingers. Pinch to click (it fires when you let go) and to grab window and dock bars. The laser only shows over the menu while your thumb and index are ready to pinch. Pinch with your left palm facing you to open or close the menu.
- Direct touch and pinch: swipe a list or Settings to scroll it.
- Multitasking: three windows side by side. Drag a window by its bar to move it between slots. New apps open in the middle.
- The window and dock face your eyes and curve around them. The dock is a rounded rectangle. Everything renders at 2x and is scaled down, for sharper text and smoother edges.
- Direct touch forgives sliding: a tap still counts if your finger slides while lifting, and scrolling starts only after about 2 cm of vertical movement.
- The welcome tour can no longer be closed, which used to leave you stuck.
- If MacVR crashes while the Quest menu is open, the next launch uses the SteamVR menu and tells you. You can switch back in Settings.
- Quit Game now quits the game. It used to leave Wine games running.

### WineXR (Windows VR games)

- Hand tracking in games: put the controllers down and games that support hand tracking see your real fingers, pinches and pointing rays. Games that switch between controllers and hands do so as you put a controller down or pick it up.
- Games that only know Valve Index, HTC Vive, Windows Mixed Reality, HP Reverb G2, Vive Cosmos or Quest Touch Plus/Pro controllers now get your Touch input, mapped sensibly: Index "A/B" on the left hand are X/Y, a Vive trackpad is the thumbstick, and a missing menu button is B.
- Floating menus, video screens and curved panels that games draw on top of the world now show up where the game puts them, instead of being ignored or stretched flat across your view.
- Direct3D 12 games can now run in VR.
- Games that ask for depth images, performance hints or hand tracking no longer get an error back.
- Frames reach the headset sooner, and a game waiting for an idle headset no longer keeps a CPU core busy.
- The game backdrop behind the MacVR menu now lines up in games that use a seated reference space.
- The runtime log names exactly what a game asked for and didn't get, once each.

### SiliconXR (native Mac games) and the SiliconXR mod

- Hand tracking in native OpenXR games. Put a controller down and games that support hands see your real fingers. Pinch, aim, poke and grab work in games that use the standard hand-interaction controls, and picking the controller back up switches that hand back.
- More games understand your controllers. Games made for Valve Index, HTC Vive, HP Reverb, Windows Mixed Reality, Quest Pro, Quest 3 Touch Plus or "simple" controllers now get working buttons from your Touch controllers. Index A/B on the left hand are X/Y.
- Menus, video players and HUDs drawn as flat, curved or 360° panels now show up in the headset, even in apps that show only a panel and no 3D scene. They used to be missing or squashed.
- Games can skip drawing the lens corners you can't see, which saves GPU time. Vivecraft does this automatically.
- Minecraft (Vivecraft) runs smoother: sending frames to MacVR no longer makes Minecraft wait for the GPU.
- Vibration on both hands at once works. One of the two pulses used to get lost.
- Vivecraft: switching between controllers and hand tracking updates where your hand aims. Fades to a color work. Play-area and device information (controller type, battery, buttons) is more complete.
- Finger tracking for OpenVR mods: hand bones and finger curls come from your tracked hands, or from how you hold the trigger and grip.
- Better compatibility with Quest ports: haptic clips, performance counters, foveation and other Meta extensions are accepted, and the game is told when the headset is connected or disconnected.
- The SiliconXR mod (1.1.0) carries the new natives. It still works on Fabric, Quilt, Forge and NeoForge.

## 1.1.1

- Hands are no longer shifted or rotated in OpenComposite games (Gorilla Tag and others). 1.1.0 advertised XR_EXT_palm_pose without real palm data, so OpenComposite read the grip pose as a palm pose. The extension is no longer advertised.

## 1.1.0

- Quick Settings: Resume and Quit Game tiles while a game runs, and a one-tap Headset Mic tile.
- Fixes:
  - The OpenXR runtime now registers while Wine is running. Fresh installs used to miss it until the bottle was stopped.
  - Quit Game now actually quits.
  - HEVC falls back to H.264 when the encoder can't start, instead of streaming black.
  - A hung adb no longer blocks Retry USB.
  - Several crash and thread-safety fixes, plus cheaper library rescans.

- Microphones: Settings > Audio > Microphone picks any Mac mic or the headset's own mic. Games record from the chosen one.
  - The headset mic reaches games through "MacVR Headset Mic", a small loopback audio driver.
  - MacVR offers to install the driver on first launch, and it needs your password once.
  - The Quest streams its mic as VR4_MIC packets.
- Universal Menu redone after the late (v60-v76) Quest design:
  - Near-black translucent dock: avatar and clock (opens Quick Settings), white system glyphs, colourful app icons (Steam's square game icons), a tiny active-app indicator, and labels only on hover.
  - Hover is a calm plate with no enlarging, and clicks show a brief pressed state.
  - One sound per click, at commit: a soft confirm when a window opens, a tick otherwise. Hover and scroll sounds sit well under clicks.
  - Text is medium weight.
  - Opening is a 160 ms fade with a tiny settle, and closing fades out in 120 ms.
  - Holding the menu button recenters the menu in front of you.
- SiliconXR (`SiliconXR/`): VR for games that run natively on macOS, the Mac twin of WineXR.
  - OpenXR runtime with Metal (`XR_KHR_metal_enable`). MacVR registers it in `~/.config/openxr/1/active_runtime.json` unless another runtime is registered there.
  - OpenVR runtime for Vivecraft (Minecraft Java), plus the LWJGL Apple Silicon natives LWJGL lacks. Works with LWJGL 3.3.1–3.3.6 (`IVRCompositor_027`/`028`).
- SiliconXR mod (`SiliconXR-Mod/`, `siliconxr.jar`): one jar for Fabric, Quilt, Forge and NeoForge that puts the natives on LWJGL's path. MacVR drops it next to every Vivecraft jar (Prism, MultiMC, Modrinth, CurseForge, official launcher).

## 1.0.1

- Changing a running game's world scale in either Settings window now applies immediately. Changing another game's settings does not affect the current game. Render resolution and Theater defaults apply on the next launch.
- Reconnecting a headset clears old queued-send counters, held desktop input, controller button state, and the stale VR preview.
- USB setup runs away from the network queue so an authorization prompt cannot stall incoming headset packets.
- The Mac status window shows connection errors and USB/Wi-Fi troubleshooting steps, with a button to retry USB setup.
- Controllers without a valid tracked pose cannot click or drag the menu.

Validation: optimized Mac app build; TCP tests for replacement with pending sends, reconnect HELLO, EOF cleanup and occupied ports; override tests for live changes, game isolation, next-launch resolution and resetting defaults.
