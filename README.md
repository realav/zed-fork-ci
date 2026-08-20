# zed-fork-ci

CI that builds a patched [Zed](https://github.com/zed-industries/zed) for macOS arm64.

This repo holds **only the patches and the workflow** — none of Zed's history. The
workflow clones upstream at the tag in `.fork-base`, applies `patches/*.patch`,
builds, and uploads `Zed.app` as an artifact.

## The patches

1. `show_rerun` in task templates — hide a task tab's rerun button.
2. `terminal.tab_title: "shell_title"` — tab shows the title the running program
   sets via OSC 2 instead of the static task label, so agent CLIs are tellable apart.
3. `show_status_icon` in task templates — omit the tab's ▶/✓/✗ icon entirely.

All three are written to be upstreamable (docs and defaults included).

## Usage

- **Actions → Build patched Zed → Run workflow**, optionally passing a tag.
- Runs automatically Mondays 06:00 UTC (Zed ships stable ~weekly).
- Quit Zed, then run `local/install-build.sh` — it downloads the latest
  successful run's artifact and installs it. Do not just unzip and drag, see
  below for why.

To follow a newer Zed: change `.fork-base`, or pass the tag as workflow input.
If a patch stops applying, `git am` fails loudly — rebase locally and re-export.

## Keeping macOS permissions across builds

The runner has no signing certificate, so `script/bundle-mac` signs the app
ad-hoc. Ad-hoc means there is no identity, so macOS records every permission
grant against the binary's **cdhash** — and a new build has a new cdhash. To
TCC that is a different app, so Accessibility, Screen Recording, Files,
Automation, mic and camera all ask again.

The fix is a self-signed certificate that never changes:

```sh
local/make-signing-cert.sh      # once per machine
local/install-build.sh          # after every build
```

`install-build.sh` with no argument fetches the latest successful run's artifact
via `gh`. It also takes a run id, a downloaded zip, or an existing `Zed.app` to
re-sign in place. It clears the download quarantine, re-signs the helpers and
the bundle (`--preserve-metadata=entitlements`, so JIT/mic/camera survive),
verifies the result, then swaps it into `/Applications`, keeping the old app
until the copy succeeds. The recorded requirement becomes

```
identifier "dev.zed.Zed" and certificate leaf = H"<the cert>"
```

which every later build satisfies. The certificate is self-signed and stays on
this Mac; it cannot notarize, which does not matter for a locally built app.

The very first install after switching still prompts once, because the identity
genuinely changed. After that the grants stick. The same applies to local
`fork.sh build` output — run `local/install-build.sh /Applications/Zed.app` to
re-sign it in place.

## Why the odd steps

- **Free disk** — the free macOS runner has ~14 GB; spare Xcodes and simulator
  runtimes are deleted first. Every step prints `df` so a disk failure is legible.
- **`CARGO_PROFILE_RELEASE_DEBUG: false`** — Zed's release profile sets
  `debug = "limited"`, which dominates the artifact tree (17 GB locally).
- **Metal toolchain** — Xcode 26 ships `metal` as a separate download; gpui
  compiles shaders at build time.
- **Prefetch WebRTC** — `webrtc-sys` fetches a 242 MB blob with no retry and a
  short timeout. Best effort; the build falls back to its own download.
- **`bundle-mac -i`** — installs to `/Applications` and skips DMG creation,
  which needs extra tooling. It exits non-zero after installing, so the step
  checks for the installed app instead of the exit code.

Local equivalent: `~/code/zed` with `fork.sh` (see `FORK.md` there).
