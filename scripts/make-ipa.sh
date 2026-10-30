#!/bin/bash
# make-ipa.sh [output.ipa]  -- builds a Release IPA of the app (ad hoc signed by default, entitlements embedded). Your identity (bundle id, team, display name, signing
# identity, optional provisioning profiles) comes from release.config in the repository root (or the file named in $RELEASE_CONFIG).
# Expects HostApp/runtime/jre, HostApp/runtime/natives (WITHOUT the game's own libraries) and HostApp/Frameworks (MetalANGLE, StikJIT) to exist, see docs/BUILDING.md.
# The IPA contains no game files and none of the game's libraries; add them for your own use with scripts/inject-game-natives.sh.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd); OUT=${1:-$ROOT/pziOS.ipa}; DD=${DD:-$ROOT/build/dd}
BUNDLE_ID=com.knt.pzios; TEAM_ID=""; DISPLAY_NAME=pziOS; SIGN_IDENTITY=-; PROFILE_APP=""; PROFILE_JIT=""
[ -f "${RELEASE_CONFIG:-$ROOT/release.config}" ] && . "${RELEASE_CONFIG:-$ROOT/release.config}"
cd "$ROOT/HostApp"
[ -d runtime/jre ] && [ -d runtime/natives ] && [ -d Frameworks/MetalANGLE.framework ] || { echo "missing HostApp/runtime or HostApp/Frameworks (see docs/BUILDING.md)"; exit 1; }
for l in libglfw libGLshim libgl4es_114 libEGLproxy libfmodhal libfmodhal_ca; do [ -f runtime/natives/$l.dylib ] || { echo "runtime/natives/$l.dylib missing"; exit 1; }; done
xcodegen generate >/dev/null
LOG="$ROOT/build/xcodebuild.log"; mkdir -p "$ROOT/build"
if ! xcodebuild -project pziOS.xcodeproj -scheme pziOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" PZ_BUNDLE_ID="$BUNDLE_ID" PZ_TEAM_ID="$TEAM_ID" PZ_DISPLAY_NAME="$DISPLAY_NAME" build > "$LOG" 2>&1; then
  echo "--- build errors ---"
  grep -E "error:|fatal error:" "$LOG" | grep -vE "^[^ ]*: note:" | head -60 || true
  echo "--- end of the build log ---"
  tail -25 "$LOG"
  exit 1
fi
tail -3 "$LOG"
APP="$DD/Build/Products/Release-iphoneos/pziOS.app"
[ -n "$PROFILE_APP" ] && cp "$PROFILE_APP" "$APP/embedded.mobileprovision"
[ -n "$PROFILE_JIT" ] && cp "$PROFILE_JIT" "$APP/PlugIns/ZomJITHelper.appex/embedded.mobileprovision"
"$ROOT/scripts/sign-app.sh" "$APP" "$SIGN_IDENTITY"
rm -rf "$ROOT/build/Payload"; mkdir -p "$ROOT/build/Payload"; cp -R "$APP" "$ROOT/build/Payload/"
( cd "$ROOT/build" && rm -f "$OUT" && zip -qry "$OUT" Payload )
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
