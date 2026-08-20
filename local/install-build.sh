#!/usr/bin/env bash
# Install a CI build of Zed with a stable code signature, so macOS keeps the
# permissions it already granted instead of asking again for every build.
#
#   local/install-build.sh ~/Downloads/Zed-v0.203.5-patched-arm64.zip
#   local/install-build.sh /path/to/Zed.app
#
# The runner has no certificate, so `script/bundle-mac` signs ad-hoc and each
# build lands with a different identity. Re-signing here with the one identity
# from local/make-signing-cert.sh keeps that identity constant forever.
# See make-signing-cert.sh for the full reasoning.

set -euo pipefail

IDENTITY="${ZED_SIGN_IDENTITY:-Zed Local Signing}"
DEST="${ZED_APP:-/Applications/Zed.app}"
SRC="${1:-}"

[ -n "$SRC" ] || { echo "usage: $(basename "$0") <artifact.zip|Zed.app>" >&2; exit 1; }
[ -e "$SRC" ]  || { echo "no such file: $SRC" >&2; exit 1; }

security find-identity -v -p codesigning | grep -q "\"$IDENTITY\"" || {
  echo "no code-signing identity named \"$IDENTITY\"." >&2
  echo "run: $(dirname "$0")/make-signing-cert.sh" >&2
  exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The Actions artifact is a zip of the zip the workflow made, so unwrap until
# Zed.app appears rather than assuming one layer or two.
if [ -d "$SRC" ]; then
  APP="$TMP/Zed.app"
  ditto "$SRC" "$APP"
else
  ditto -x -k "$SRC" "$TMP/x1"
  APP=$(find "$TMP/x1" -maxdepth 2 -name 'Zed*.app' -type d | head -1)
  if [ -z "$APP" ]; then
    inner=$(find "$TMP/x1" -maxdepth 2 -name '*.zip' | head -1)
    [ -n "$inner" ] || { echo "no Zed.app and no inner zip in $SRC" >&2; exit 1; }
    ditto -x -k "$inner" "$TMP/x2"
    APP=$(find "$TMP/x2" -maxdepth 2 -name 'Zed*.app' -type d | head -1)
  fi
fi
[ -n "$APP" ] || { echo "could not find Zed.app inside $SRC" >&2; exit 1; }
echo "found $(basename "$APP") ($(du -sh "$APP" | cut -f1))"

# Downloads arrive quarantined; the flag has to go before signing or the seal
# covers an attribute Gatekeeper will strip later.
xattr -cr "$APP"

# Nested code is sealed into the outer signature, so everything inside signs
# first and the bundle last. --preserve-metadata=entitlements carries over each
# binary's own entitlements (JIT, mic, camera, Apple events) untouched.
#
# The helpers are discovered rather than listed, so a future upstream Zed that
# ships another binary or a framework still gets fully signed.
MAIN=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")
while IFS= read -r nested; do
  codesign --force --preserve-metadata=entitlements --sign "$IDENTITY" "$nested"
done < <(
  find "$APP/Contents" -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' \) -print
  find "$APP/Contents/MacOS" -type f -perm -u+x ! -name "$MAIN" -print
)
codesign --force --preserve-metadata=entitlements --sign "$IDENTITY" "$APP"

# Verify before touching the installed app: a failure here must leave the
# working copy in /Applications alone.
codesign --verify --strict --deep "$APP"
echo "signed:"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Authority|Signature'
echo "designated requirement (this is what TCC pins):"
codesign -d -r- "$APP" 2>&1 | grep '^designated'

# Never replace a bundle that is executing: the running process reads lazily
# from its own files, so deleting them mid-session corrupts the live app.
if pgrep -x zed >/dev/null; then
  echo >&2
  echo "Zed is running — quit it (Cmd-Q) and re-run. Nothing was changed." >&2
  exit 1
fi

# Keep the old app until the new one is fully in place, so a failed copy is
# recoverable instead of leaving no editor at all.
if [ -d "$DEST" ]; then
  rm -rf "$DEST.prev"
  mv "$DEST" "$DEST.prev"
fi
if ditto "$APP" "$DEST"; then
  rm -rf "$DEST.prev"
else
  echo "install failed — restoring previous app" >&2
  rm -rf "$DEST"; mv "$DEST.prev" "$DEST"
  exit 1
fi

echo
echo "installed $DEST"
echo "the first launch still asks once — grants after that survive every rebuild."
