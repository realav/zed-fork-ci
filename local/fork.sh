#!/usr/bin/env bash
# Manage the patched Zed fork: rebase the local patches onto a new upstream
# release, build it, install it.
#
#   ./fork.sh setup      re-create ~/code/zed from upstream + patches/
#   ./fork.sh status     what's installed, what's upstream, what's patched
#   ./fork.sh update     rebase patches onto the latest stable tag (no build)
#   ./fork.sh build      build + install /Applications/Zed.app (~20-40 min)
#   ./fork.sh build fast iterating on a patch: no LTO, parallel codegen (~2-5 min
#                        after its own first full build; keeps a separate cache)
#   ./fork.sh upgrade    update, then build — the whole ritual, one command
#   ./fork.sh rollback   restore the stock Zed.app from the backup
#   ./fork.sh clean      delete target/ (~9 GB) at the cost of a slow next build
#   ./fork.sh export     write patches/*.patch (survives a broken branch)
#
# The patches are commits on the `patches` branch, sitting on top of a release
# tag recorded in .fork-base. Nothing else is customized, so a bad rebase is
# never fatal: `git rebase --abort` leaves the working fork exactly as it was.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANCH="patches"
BASE_FILE="$REPO/.fork-base"
BACKUP="$HOME/code/zed-stable-1.14.2-backup.app"
WEBRTC="$HOME/code/zed-deps/extracted/mac-arm64-release"
WEBRTC_URL="https://github.com/zed-industries/livekit-rust-sdks/releases/download/webrtc-0001d84-4/webrtc-mac-arm64-release.zip"
cd "$REPO"

base_tag()   { cat "$BASE_FILE"; }
latest_tag() { git tag -l 'v*' --sort=-v:refname | grep -Ev -- '-(pre|rc)' | head -1; }
installed()  { defaults read /Applications/Zed.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo none; }

# The working tree is disposable: CI builds releases, so a local checkout only
# exists while a patch is being edited. This rebuilds it from patches/*.patch.
cmd_setup() {
    local tag; tag=$(cat "$(dirname "$0")/../.fork-base")
    [ -d "$REPO/.git" ] && { echo "$REPO already exists"; return 0; }
    git clone --filter=blob:none https://github.com/zed-industries/zed.git "$REPO"
    cd "$REPO"
    git config rerere.enabled true
    git checkout -q "$tag"
    git checkout -q -B "$BRANCH"
    git am "$(dirname "$0")/../patches"/*.patch
    echo "$tag" > "$BASE_FILE"
    cp "$(dirname "$0")/fork.sh" "$(dirname "$0")/FORK.md" "$REPO/"
    echo "ready: $REPO on $tag + $(ls "$(dirname "$0")/../patches"/*.patch | wc -l | tr -d ' ') patches"
}

cmd_status() {
    git fetch -q --tags origin
    echo "installed /Applications/Zed.app : $(installed)"
    echo "patches sit on                  : $(base_tag)"
    echo "latest upstream stable          : $(latest_tag)"
    echo
    echo "patches:"
    git log --oneline "$(base_tag)..$BRANCH" | sed 's/^/  /'
    echo
    if [ "$(base_tag)" = "$(latest_tag)" ]; then
        echo "up to date"
    else
        echo "new release available -> ./fork.sh upgrade"
    fi
}

cmd_export() {
    mkdir -p patches && rm -f patches/*.patch
    git format-patch -o patches "$(base_tag)..$BRANCH" >/dev/null
    echo "exported $(ls patches/*.patch | wc -l | tr -d ' ') patches to $REPO/patches/"
}

cmd_update() {
    git fetch --tags origin
    local old new
    old=$(base_tag); new=$(latest_tag)

    if [ "$old" = "$new" ]; then echo "already on $new, nothing to do"; return 0; fi

    cmd_export                      # keep a copy before touching the branch
    git checkout "$BRANCH"
    echo "rebasing patches: $old -> $new"
    if git rebase --onto "$new" "$old" "$BRANCH"; then
        echo "$new" > "$BASE_FILE"
        git add "$BASE_FILE" && git commit -q --amend --no-edit
        echo "rebased onto $new — now run ./fork.sh build"
    else
        cat <<'EOF'

Rebase stopped on a conflict. The patches only ever touch these files:
  crates/terminal_view/src/terminal_view.rs   tab title logic
  crates/terminal/src/terminal_settings.rs    tab_title setting
  crates/settings_content/src/terminal.rs     tab_title setting + enum
  crates/settings/src/vscode_import.rs        one None field
  crates/task/src/task_template.rs            show_rerun field
  assets/settings/default.json                tab_title default
  docs/src/{terminal,tasks}.md                docs

Resolve, then:  git add -A && git rebase --continue && echo <new-tag> > .fork-base
Bail out with:  git rebase --abort      (fork stays on the old release, still works)
Start clean:    git checkout -B patches <new-tag> && git am patches/*.patch
EOF
        return 1
    fi
}

cmd_build() {
    git checkout "$BRANCH"
    # `fast` trades LTO and single-unit codegen for much shorter links. Its
    # artifacts hash differently, so the first fast build is a full one and the
    # two caches then coexist — don't flip modes casually.
    if [ "${1:-}" = "fast" ]; then
        export CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
        echo "fast mode: no LTO, 16 codegen units"
    fi
    # webrtc-sys downloads a 242 MB prebuilt blob with no retry and a short
    # timeout; GitHub's CDN stalls ~75s before sending, so it reliably fails.
    # Point it at a copy fetched once with curl instead.
    if [ -d "$WEBRTC" ]; then
        export LK_CUSTOM_WEBRTC="$WEBRTC"
    else
        echo "warning: $WEBRTC missing — the build will try to download WebRTC itself and may time out"
        echo "  refetch: curl -L --retry 5 -o /tmp/w.zip $WEBRTC_URL && unzip -q /tmp/w.zip -d $(dirname "$WEBRTC")"
    fi
    echo "building $(base_tag) + patches — 20-40 min the first time, less after"
    local stamp; stamp=$(mktemp)
    # bundle-mac installs the app and *then* fails trying to stage a DMG it
    # already moved away, so judge success by the installed app, not its exit code.
    script/bundle-mac -i || true
    if [ /Applications/Zed.app/Contents/MacOS/zed -nt "$stamp" ]; then
        rm -f "$stamp"
        echo "installed: $(installed) — quit and reopen Zed to run it"
    else
        rm -f "$stamp"
        echo "BUILD FAILED — /Applications/Zed.app was not replaced"; return 1
    fi
}

cmd_clean() {
    local before
    before=$(du -sh target 2>/dev/null | cut -f1)
    cargo clean
    echo "freed $before — next build is a full one (~40 min) instead of ~10"
}

cmd_rollback() {
    [ -d "$BACKUP" ] || { echo "no backup at $BACKUP"; exit 1; }
    rm -rf /Applications/Zed.app
    ditto "$BACKUP" /Applications/Zed.app
    echo "restored stock Zed from $BACKUP"
}

case "${1:-status}" in
    setup)    cmd_setup ;;
    status)   cmd_status ;;
    update)   cmd_update ;;
    build)    cmd_build "${2:-}" ;;
    upgrade)  cmd_update && cmd_build "${2:-}" ;;
    rollback) cmd_rollback ;;
    clean)    cmd_clean ;;
    export)   cmd_export ;;
    *)        sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
