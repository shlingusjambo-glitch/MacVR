# Changes

## 1.0.1

- Changing a running game's world scale in either Settings window now applies immediately. Changing another game's settings does not affect the current game. Render resolution and Theater defaults apply on the next launch.
- Reconnecting a headset clears old queued-send counters, held desktop input, controller button state, and the stale VR preview.
- USB setup runs away from the network queue so an authorization prompt cannot stall incoming headset packets.
- The Mac status window shows connection errors and USB/Wi-Fi troubleshooting steps, with a button to retry USB setup.
- Controllers without a valid tracked pose cannot click or drag the menu.

Validation: optimized Mac app build; TCP tests for replacement with pending sends, reconnect HELLO, EOF cleanup and occupied ports; override tests for live changes, game isolation, next-launch resolution and resetting defaults.
