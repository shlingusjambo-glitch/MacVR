#!/bin/sh
# Splits this monorepo into publishable repos with User-only authorship:
#   WineXR      runtime/ + common/ (+ protocol README)
#   MacVR       mac/ + common/ (vendored) + release/ + README/docs
#   QuestClient android/ (+ client README)
#   SiliconXR   SiliconXR/ + common/ (+ README, notices)
#   SiliconXR-Mod  SiliconXR-Mod/ (flat)
# Nothing is pushed. The User reviews, creates the GitHub repos, and pushes.
#
# Required env (never defaulted — agent git identity must not leak in):
#   AUTHOR_NAME, AUTHOR_EMAIL   e.g. your GitHub profile name + noreply email.
# Usage: AUTHOR_NAME="..." AUTHOR_EMAIL="...@users.noreply.github.com" ./release/export-repos.sh [--out DIR]
set -e
cd "$(dirname "$0")/.."
: "${AUTHOR_NAME:?set AUTHOR_NAME to the User's GitHub name}"
: "${AUTHOR_EMAIL:?set AUTHOR_EMAIL to the User's GitHub email}"
OUT="$PWD/dist/export"
if [ "$1" = "--out" ]; then OUT="$2"; fi
rm -rf "$OUT"; mkdir -p "$OUT"

copy() { # $1=repo $2..=paths (relative to monorepo root)
    repo="$1"; shift
    mkdir -p "$OUT/$repo"
    for p in "$@"; do cp -R "$p" "$OUT/$repo/"; done
}

# --- WineXR ---
copy WineXR runtime common LICENSE THIRD_PARTY_NOTICES.md
cp runtime/README.md "$OUT/WineXR/README.md"

# --- MacVR ---
copy MacVR mac common LICENSE THIRD_PARTY_NOTICES.md README.md CHANGELOG.md release tools
# published layout wants docs/ at top level: move mac/docs up, fix README refs
mv "$OUT/MacVR/mac/docs" "$OUT/MacVR/docs"
sed -i '' 's#mac/docs/screenshots#docs/screenshots#g' "$OUT/MacVR/README.md" 2>/dev/null || \
  sed -i 's#mac/docs/screenshots#docs/screenshots#g' "$OUT/MacVR/README.md"
cat > "$OUT/MacVR/common/VENDORED.txt" <<'EOF'
Vendored copy. Canonical source: the WineXR repository (common/vr4mac.h).
Sync when VR4_SHM_VERSION or the wire protocol changes — both sides must match.
EOF

# --- QuestClient ---
copy QuestClient android LICENSE THIRD_PARTY_NOTICES.md
cp android/README.md "$OUT/QuestClient/README.md"

# --- SiliconXR ---
copy SiliconXR SiliconXR common LICENSE
cp SiliconXR/README.md "$OUT/SiliconXR/README.md"
mv "$OUT/SiliconXR/SiliconXR/THIRD_PARTY_NOTICES.md" "$OUT/SiliconXR/THIRD_PARTY_NOTICES.md"

# --- SiliconXR-Mod ---
mkdir -p "$OUT/SiliconXR-Mod"; cp -R SiliconXR-Mod/. "$OUT/SiliconXR-Mod/"; cp LICENSE "$OUT/SiliconXR-Mod/"

# scrub dev-only files from all
for r in WineXR MacVR QuestClient SiliconXR SiliconXR-Mod; do
    (cd "$OUT/$r" && rm -rf build SiliconXR/build mac/build runtime/build android/build android/app/build \
        android/.gradle android/app/.cxx android/local.properties android/VR4Mac.apk \
        .agentcollab __pycache__ dist a.out *.pem *.ppm *.png 2>/dev/null || true; find . -name .DS_Store -delete)
done

# fresh history, User as author, no agent trailers
for r in WineXR MacVR QuestClient SiliconXR SiliconXR-Mod; do
    (cd "$OUT/$r" && git init -q && git add -A && \
     git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" \
         commit -qm "Initial public release" && \
     echo "$r: $(git log --format='%an <%ae> %s' -1)")
done
echo "exported to $OUT — review, create the GitHub repos, push."
