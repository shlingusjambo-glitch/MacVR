# Changes

## Unreleased

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
