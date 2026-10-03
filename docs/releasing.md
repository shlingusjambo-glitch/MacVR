# Releasing a new version

MacVR ships as five GitHub repositories under `shlingusjambo-glitch`:

| Repo | What | Release assets (names matter, the updater looks them up) |
|---|---|---|
| MacVR | Mac app | `MacVR-X.Y.Z.dmg`, `MacVR-X.Y.Z-mac.zip`, `MacVR-Quest-X.Y.Z.apk` |
| MacVR-Quest | Quest app | `MacVR-Quest-X.Y.Z.apk` |
| WineXR | OpenXR runtime for Wine | `vr4mac_openxr.dll` |
| SiliconXR | Native OpenXR/OpenVR for Minecraft | `libsiliconxr_openxr.dylib`, `libopenvr_api.dylib`, `liblwjgl_openvr.dylib` |
| SiliconXR-Mod | Minecraft mod | `siliconxr.jar` |

MacVR's updater installs MacVR, WineXR and SiliconXR automatically (Settings > Updates).
The Quest app and the mod are installed by hand.

## 1. Pick the version number

Versions are `MAJOR.MINOR.PATCH`:

- **PATCH** (1.3.0 → 1.3.1): fixes only.
- **MINOR** (1.3.1 → 1.4.0): new features or settings.
- **MAJOR** (1.x → 2.0.0): breaking changes, e.g. the wire protocol or shared-memory layout
  (`VR4_SHM_VERSION` in `common/vr4mac.h`) changes and old Quest apps or runtimes stop working.

Only bump a component that changed. A Mac-only release doesn't need a new Quest app.

A beta of the next version is `X.Y.Z-beta.N`, e.g. `1.4.0-beta.1`, `1.4.0-beta.2`, then the
public `1.4.0`.

## 2. Change the version everywhere

| Component | Where | What to change |
|---|---|---|
| MacVR | `mac/Info.plist` | `CFBundleShortVersionString`, e.g. `1.4.0` or `1.4.0-beta.1`. This is what About shows (headset Settings > About, the Mac Settings window, Help > Export Diagnostics) and what the updater compares against the tag. |
| MacVR | `mac/Info.plist` | `MacVRWineXRVersion`, `MacVRSiliconXRVersion`: the runtime versions bundled in this build. Update them whenever you bundle a new WineXR/SiliconXR. |
| MacVR | `mac/Sources/Updates.swift` | Fallback versions in `bundledVersion` (only used if Info.plist is missing a key). Keep them in step. |
| Quest app | `android/app/build.gradle` | `versionName` (`1.4.0`) **and** `versionCode` (+1 every release, or the Quest refuses to install over the old one). |
| WineXR | `runtime/vr4mac_openxr.c` | `runtimeVersion = XR_MAKE_VERSION(...)` in `xrGetInstanceProperties`. |
| SiliconXR | `SiliconXR/openxr/siliconxr_openxr.m` | `runtimeVersion = XR_MAKE_VERSION(...)`. |
| SiliconXR Mod | `SiliconXR-Mod/resources/fabric.mod.json`, `META-INF/mods.toml`, `META-INF/neoforge.mods.toml` | `version`. |
| All | `CHANGELOG.md` | A `## X.Y.Z` section at the top, written for players. |

## 3. Public or Beta

Settings > Updates > **Update Channel**:

- **Public** (default) gets the repo's *Latest* release: a normal release, tag `vX.Y.Z`.
- **Beta** gets the newest release *or pre-release*: betas are published as GitHub
  **pre-releases** with tag `vX.Y.Z-beta.N`. Beta users also get public releases, since a
  public `1.4.0` is newer than `1.4.0-beta.3`.

Switching from Beta back to Public never downgrades: you stay on the beta until a newer
public release comes out.

So:

| | Tag | GitHub release |
|---|---|---|
| Public | `v1.4.0` | normal release, marked Latest |
| Beta | `v1.4.0-beta.1` | `--prerelease` |

## 4. Build

```sh
./release/build-release.sh --apk path/to/MacVR-Quest-X.Y.Z.apk
```

This builds WineXR, SiliconXR, the mod and MacVR **in release mode** (`MACVR_RELEASE=1`,
which leaves out developer tools such as the hand tuner and offline renders), and writes
`dist/MacVR-X.Y.Z/` with the DMG, zip and APK.

The Quest APK must be signed with the release key (kept outside the repo, never commit
it), so it installs over earlier versions:

```sh
set -a; . ~/.macvr-signing/signing.env; set +a
cd android && ./gradlew assembleRelease
```

## 5. Test

```sh
for t in run run-touch run-hands run-shell run-link-lifecycle; do sh mac/Tests/$t.sh; done
sh SiliconXR/test/run.sh
```

Then install on a headset and play one game over USB and one over Wi-Fi.

## 6. Publish

1. Commit, then export the public repos (`release/export-repos.sh`, in the monorepo only)
   and push each changed one.
2. Create the GitHub releases, components first and MacVR last (the updater checks
   MacVR last):

   ```sh
   gh release create v1.4.0 -R shlingusjambo-glitch/MacVR -t "MacVR 1.4.0" -F notes.md \
     dist/MacVR-1.4.0/MacVR-1.4.0.dmg dist/MacVR-1.4.0/MacVR-1.4.0-mac.zip dist/MacVR-1.4.0/MacVR-Quest-1.4.0.apk
   # a beta: tag v1.4.0-beta.1 and add --prerelease
   ```

3. Check every asset shows a SHA-256 digest on GitHub. The updater refuses assets without one.
