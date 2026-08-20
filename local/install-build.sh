#!/usr/bin/env bash
# Install a CI build of Zed with a stable code signature, so macOS keeps the
# permissions it already granted instead of asking again for every build.
#
#   local/install-build.sh                    latest successful Actions build
#   local/install-build.sh 32002069529        a specific workflow run id
#   local/install-build.sh ~/Downloads/x.zip  an artifact already downloaded
#   local/install-build.sh /Applications/Zed.app   re-sign an app in place
#
# The runner has no certificate, so `script/bundle-mac` signs ad-hoc and each
# build lands with a different identity. Re-signing here with the one identity
# from local/make-signing-cert.sh keeps that identity constant forever.
# See make-signing-cert.sh for the full reasoning.

set -euo pipefail

IDENTITY="${ZED_SIGN_IDENTITY:-Zed Local Signing}"
DEST="${ZED_APP:-/Applications/Zed.app}"
WORKFLOW="build-mac.yml"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-}"

security find-identity -v -p codesigning | grep -q "\"$IDENTITY\"" || {
  echo "no code-signing identity named \"$IDENTITY\"." >&2
  echo "run: $(dirname "$0")/make-signing-cert.sh" >&2
  exit 1
}

# Checked before the download, not just before the swap: a 130 MB fetch that
# ends in "quit Zed first" wastes several minutes.
if pgrep -x zed >/dev/null; then
  echo "Zed is running — quit it (Cmd-Q) and re-run. Nothing was changed." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# No argument, or a bare run id: fetch from Actions. Artifacts expire after 30
# days, so an old-but-successful run can still come back empty.
if [ -z "$SRC" ] || [[ "$SRC" =~ ^[0-9]+$ ]]; then
  command -v gh >/dev/null || {
    echo "gh CLI not installed (brew install gh), or pass an artifact path" >&2
    exit 1
  }
  cd "$REPO_DIR"

  RUN="$SRC"
  if [ -z "$RUN" ]; then
    RUN=$(gh run list --workflow "$WORKFLOW" --status success \
            --limit 1 --json databaseId --jq '.[0].databaseId')
    [ -n "$RUN" ] || { echo "no successful $WORKFLOW run found" >&2; exit 1; }
  fi

  read -r NAME SIZE < <(gh api "repos/{owner}/{repo}/actions/runs/$RUN/artifacts" \
    --jq '.artifacts[] | select(.expired == false) | "\(.name) \(.size_in_bytes)"' | head -1)
  [ -n "${NAME:-}" ] || {
    echo "run $RUN has no live artifact (expired, or the build did not finish)" >&2
    echo "re-run the workflow: gh workflow run $WORKFLOW" >&2
    exit 1
  }

  # gh prints no progress, so say up front how much is coming; on a slow link
  # this is several minutes of apparent silence.
  echo "downloading $NAME from run $RUN ($((SIZE / 1024 / 1024)) MB, no progress bar — this can take a few minutes)"
  gh run download "$RUN" -n "$NAME" -D "$TMP/dl"
  SRC="$TMP/dl"
fi

[ -e "$SRC" ] || { echo "no such file: $SRC" >&2; exit 1; }

# Normalize whatever came in (an .app, a zip, an Actions artifact directory
# holding the zip the workflow made) into one staging tree, then unwrap zips
# until Zed.app turns up rather than assuming how many layers deep it is.
STAGE="$TMP/stage"
mkdir -p "$STAGE"
case "$SRC" in
  *.app) ditto "$SRC" "$STAGE/Zed.app" ;;
  *) if [ -d "$SRC" ]; then ditto "$SRC" "$STAGE"; else ditto -x -k "$SRC" "$STAGE"; fi ;;
esac

APP=""
for round in 1 2 3; do
  APP=$(find "$STAGE" -maxdepth 4 -name 'Zed*.app' -type d | head -1)
  [ -n "$APP" ] && break
  zip=$(find "$STAGE" -maxdepth 4 -name '*.zip' -type f | head -1)
  [ -n "$zip" ] || break
  ditto -x -k "$zip" "$STAGE/layer$round"
  rm -f "$zip"
done
[ -n "$APP" ] || { echo "could not find Zed.app inside $SRC" >&2; exit 1; }

[ -d "$DEST" ] && echo "installed: $("$DEST/Contents/MacOS/cli" --version 2>/dev/null | head -1)"
echo "incoming:  $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null) ($(du -sh "$APP" | cut -f1))"

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
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E '^Identifier|^Authority'
echo "designated requirement (this is what TCC pins):"
codesign -d -r- "$APP" 2>&1 | grep '^designated'

# Zed could have been launched during a long download; re-check before the swap.
if pgrep -x zed >/dev/null; then
  echo "Zed started while this ran — quit it and re-run. Nothing was changed." >&2
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
