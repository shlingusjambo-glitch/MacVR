#!/usr/bin/env python3
"""Automated Wine & Steam VR Game Scanner for MacVR.

Scans the Wine bottle (Steam libraries and standalone folders like C:\\VR4Mac)
for installed games, inspects their binaries and plugins for VR signatures
(OpenXR, OpenVR, Oculus / Meta XR, Unity XR, Unreal VR, Godot), and outputs a
structured JSON catalog to ~/Library/Application Support/VR4Mac/vr_games.json.
"""

import json
import os
import re
import sys
import time

PREFIX_DEFAULT = os.path.expanduser("~/Applications/Sikarugir/Steam.app/Contents/SharedSupport/prefix")
APP_SUPPORT_DEFAULT = os.path.expanduser("~/Library/Application Support/VR4Mac")

VR_DLL_SIGNATURES = {
    # OpenXR
    "openxr_loader.dll": "OpenXR",
    "openxr.dll": "OpenXR",
    "openxrlibrary.dll": "OpenXR",
    "unityopenxr.dll": "OpenXR (Unity)",
    "unityopenxrhands.dll": "OpenXR (Unity Hands)",
    "microsoftopenxrplugin.dll": "OpenXR (Microsoft)",
    "unity.xr.openxr.dll": "OpenXR (Unity)",
    "openxrhmd.dll": "OpenXR (Unreal)",
    "godotopenxrvendors.dll": "OpenXR (Godot)",
    "libgodot_openxr.dll": "OpenXR (Godot)",
    # OpenVR / SteamVR
    "openvr_api.dll": "OpenVR",
    "xrsdkopenvr.dll": "OpenVR (Unity XRSDK)",
    "unity.xr.openvr.dll": "OpenVR (Unity)",
    "steamvr.dll": "OpenVR (Unreal)",
    "vrclient_x64.dll": "OpenVR (Client)",
    "opencomposite.ini": "OpenComposite Config",
    # Oculus / Meta
    "ovrplugin.dll": "Oculus SDK",
    "oculus.vr.dll": "Oculus SDK",
    "oculushmd.dll": "Oculus SDK (Unreal)"
}

# Known Steam AppIDs with VR support (even if downloaded without full local metadata)
KNOWN_VR_APPIDS = {
    "546560": "Half-Life: Alyx",
    "620980": "Beat Saber",
    "1533390": "Gorilla Tag",
    "1592190": "BONELAB",
    "823500": "BONEWORKS",
    "555160": "Pavlov",
    "629730": "Blade & Sorcery",
    "617830": "SUPERHOT VR",
    "438100": "VRChat",
    "418650": "Space Pirate Trainer",
    "450390": "The Lab",
    "1178490": "Synth Riders",
    "1059530": "Pistol Whip",
    "1366850": "I Expect You To Die 2",
    "400760": "Zenith: The Last City"
}

def parse_acf(acf_path):
    """Parse Steam's appmanifest_<appid>.acf file using regex."""
    try:
        with open(acf_path, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
    except Exception:
        return None

    data = {}
    pattern = re.compile(r'"([a-zA-Z0-9_]+)"\s+"([^"]*)"')
    for match in pattern.finditer(content):
        data[match.group(1)] = match.group(2)
    return data

def pick_best_exe(executables, folder_name):
    """Pick the primary game executable, penalizing utilities and sub-processes."""
    if not executables:
        return ""
    if len(executables) == 1:
        return executables[0]

    folder_lower = folder_name.lower().replace(" ", "").replace("_", "").replace("-", "")

    def score_exe(path):
        f = os.path.basename(path).lower()
        score = 100
        # Unreal shipping game
        if f.endswith("-win64-shipping.exe"):
            score += 50
        # Matches folder name closely
        name_clean = os.path.splitext(f)[0].replace(" ", "").replace("_", "").replace("-", "")
        if name_clean in folder_lower or folder_lower in name_clean:
            score += 40
        # Penalize utilities
        penalties = ["crash", "unins", "redist", "setup", "update", "eac", "epic", "launcher", "bootstrap", "report", "cef"]
        for p in penalties:
            if p in f:
                score -= 60
        # Penalize deep nested paths compared to root
        depth = path.count(os.sep)
        score -= depth * 5
        return score

    sorted_exes = sorted(executables, key=score_exe, reverse=True)
    return sorted_exes[0]

def detect_vr_in_dir(game_dir):
    """Scan directory tree (up to 4 levels deep) for VR signatures and executables."""
    found_signatures = set()
    executables = []

    for root, dirs, files in os.walk(game_dir):
        rel_depth = os.path.relpath(root, game_dir).count(os.sep)
        if rel_depth > 4:
            dirs.clear()
            continue

        for f in files:
            f_lower = f.lower()
            if f_lower in VR_DLL_SIGNATURES:
                found_signatures.add(VR_DLL_SIGNATURES[f_lower])
            elif f_lower.endswith(".exe"):
                if not any(skip in f_lower for skip in ["crash", "unins", "redist", "setup", "update", "eac_", "cef"]):
                    full_p = os.path.join(root, f)
                    executables.append(full_p)

    return sorted(list(found_signatures)), executables

def to_wine_path(posix_path, drive_c_path):
    """Convert POSIX path inside drive_c to Windows path (C:\\...)."""
    try:
        rel = os.path.relpath(posix_path, drive_c_path)
        if not rel.startswith(".."):
            return "C:\\" + rel.replace("/", "\\")
    except Exception:
        pass
    return posix_path

def find_steam_library_folders(prefix_path):
    """Find all configured Steam library folders from libraryfolders.vdf."""
    drive_c = os.path.join(prefix_path, "drive_c")
    default_steamapps = os.path.join(drive_c, "Program Files (x86)", "Steam", "steamapps")
    folders = []
    if os.path.exists(default_steamapps):
        folders.append(default_steamapps)

    vdf_path = os.path.join(default_steamapps, "libraryfolders.vdf")
    if os.path.exists(vdf_path):
        try:
            with open(vdf_path, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
            for match in re.finditer(r'"path"\s+"([^"]+)"', content):
                win_path = match.group(1).replace("\\\\", "\\")
                # Convert Windows path (e.g. C:\...) to POSIX path
                if win_path.upper().startswith("C:\\"):
                    rel = win_path[3:].replace("\\", "/")
                    posix_dir = os.path.join(drive_c, rel, "steamapps")
                    if os.path.exists(posix_dir) and posix_dir not in folders:
                        folders.append(posix_dir)
        except Exception:
            pass

    return folders

def scan_all_games(prefix_path=PREFIX_DEFAULT):
    drive_c = os.path.join(prefix_path, "drive_c")
    if not os.path.exists(drive_c):
        return []

    vr4mac_dir = os.path.join(drive_c, "VR4Mac")
    discovered = []
    seen_appids = set()

    # 1. Scan Steam library folders
    library_folders = find_steam_library_folders(prefix_path)
    for steamapps in library_folders:
        common_dir = os.path.join(steamapps, "common")
        for f in os.listdir(steamapps):
            if f.startswith("appmanifest_") and f.endswith(".acf"):
                acf_path = os.path.join(steamapps, f)
                data = parse_acf(acf_path)
                if not data:
                    continue

                appid = data.get("appid", "")
                if not appid or appid in seen_appids:
                    continue

                name = data.get("name", "")
                installdir = data.get("installdir", "")
                state_flags = int(data.get("StateFlags", "0"))
                installed = (state_flags & 4) != 0

                game_full_dir = os.path.join(common_dir, installdir) if installdir else None
                vr_apis = []
                exes = []
                main_exe_wine = ""

                if game_full_dir and os.path.exists(game_full_dir):
                    vr_apis, exes = detect_vr_in_dir(game_full_dir)
                    best_exe = pick_best_exe(exes, installdir or name)
                    if best_exe:
                        main_exe_wine = to_wine_path(best_exe, drive_c)

                is_vr = len(vr_apis) > 0 or appid in KNOWN_VR_APPIDS
                if is_vr:
                    seen_appids.add(appid)
                    discovered.append({
                        "id": appid,
                        "name": name or KNOWN_VR_APPIDS.get(appid, f"App {appid}"),
                        "type": "steam",
                        "installed": installed,
                        "vr": True,
                        "vr_apis": vr_apis or ["OpenXR / OpenVR"],
                        "install_dir": installdir,
                        "exe_wine": main_exe_wine,
                        "launch_cmd": f"steam://launch/{appid}"
                    })

    # 2. Scan standalone VR games in C:\VR4Mac\
    if os.path.exists(vr4mac_dir):
        for item in os.listdir(vr4mac_dir):
            item_path = os.path.join(vr4mac_dir, item)
            if item.lower() in ["opencomposite", "logs", "config", "wswine.bundle"]:
                continue
            if os.path.isdir(item_path):
                vr_apis, exes = detect_vr_in_dir(item_path)
                if exes and (vr_apis or "vr" in item.lower()):
                    best_exe = pick_best_exe(exes, item)
                    wine_p = to_wine_path(best_exe, drive_c)
                    slug = re.sub(r'[^a-zA-Z0-9_-]', '', item).lower()
                    discovered.append({
                        "id": f"standalone_{slug}",
                        "name": item,
                        "type": "standalone",
                        "installed": True,
                        "vr": True,
                        "vr_apis": vr_apis or ["OpenXR"],
                        "install_dir": item,
                        "exe_wine": wine_p,
                        "launch_cmd": wine_p
                    })

    return discovered

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Scan Wine bottle for VR games")
    parser.add_argument("--prefix", default=PREFIX_DEFAULT, help="Path to Wine prefix")
    parser.add_argument("--output", default=None, help="Output JSON path")
    parser.add_argument("--json", action="store_true", help="Print JSON to stdout")
    args = parser.parse_args()

    games = scan_all_games(args.prefix)
    payload = {
        "scanned_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "prefix": args.prefix,
        "count": len(games),
        "games": games
    }

    out_json = json.dumps(payload, indent=2)

    # Save to App Support default location
    out_path = args.output or os.path.join(APP_SUPPORT_DEFAULT, "vr_games.json")
    try:
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(out_json)
        print(f"[Scanner] Successfully discovered {len(games)} VR games -> {out_path}", file=sys.stderr)
    except Exception as e:
        print(f"[Scanner] Error writing output file {out_path}: {e}", file=sys.stderr)

    if args.json or not args.output:
        print(out_json)

if __name__ == "__main__":
    main()
