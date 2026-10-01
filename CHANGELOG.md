# Changes

## Unreleased

- Menu style: pick Quest (compact dock, windows with a bottom title bar) or SteamVR (the previous wide bar) in the welcome tour or Settings > Universal Menu.
- Quest style puts the menu close: a small window at arm's length and the dock low, near your hands.
- Translucent, life-size hands hold the controllers in MacVR Home (Quest 1, 2, 3 and Steam Frame controllers) and fade out toward the wrist. Fingers follow the trigger, grip, thumbstick, thumbrest and face buttons, and the controller's buttons, trigger, grip and stick move with your input.

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
