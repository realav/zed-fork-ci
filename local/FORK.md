# Zed fork — agent-friendly terminal tabs

Two patches on top of stock Zed, so terminal tabs running CLI agents are
tellable apart. Everything else is upstream Zed, same config, same app path.

## What the patches do

**1. `terminal.tab_title`** — a tab can show the title the program sets via the
OSC escape sequence (`\e]2;Title\a`) instead of the static task label. Claude
Code, Codex and friends name their sessions this way, so tabs become
`✳ adaptive-typing-app-impl` instead of four tabs all called `Claude`.

```json
// ~/.config/zed/settings.json
{ "terminal": { "tab_title": "shell_title" } }
```

Values: `"default"` (stock behavior — task label, else process + folder) or
`"shell_title"`. A tab renamed by hand (`terminal::RenameTerminal`) always keeps
its custom name. Falls back to `default` until a title is actually set.

**2. `show_rerun` in tasks.json** — hides the rerun button on a task's tab.
The flag already existed inside Zed but was hardcoded to `true`; now task
templates can set it.

```json
// ~/.config/zed/tasks.json
{ "label": "Claude", "command": "claude", "show_rerun": false, ... }
```

## Layout

```
~/code/zed                        this repo, branch `patches` on tag v1.14.2
  .fork-base                      the tag the patches sit on
  fork.sh                         the only script you need
  patches/*.patch                 exported copies of the commits
~/code/zed-stable-1.14.2-backup.app   stock Zed, for ./fork.sh rollback
```

## Updating when Zed ships a release

```bash
cd ~/code/zed
./fork.sh status     # what's installed vs what's out
./fork.sh upgrade    # rebase onto latest stable, build, install
```

`upgrade` = `update` (git rebase of 2 commits onto the new tag) + `build`
(`script/bundle-mac -i`, which replaces `/Applications/Zed.app`). Zed ships
stable roughly weekly; skipping releases is fine, the rebase doesn't care how
far behind you are.

If a rebase conflicts, `fork.sh` prints the exact file list and the three ways
out (resolve / abort / re-apply from `patches/`). Aborting leaves the currently
installed build untouched — you're never left without an editor.

`git config rerere.enabled true` is set in this repo, so a conflict you resolve
once replays automatically on later rebases.

## Build modes and disk

`./fork.sh build` uses Zed's release profile (thin LTO, one codegen unit) — the
shipping-quality build, ~20-40 min on a 16 GB machine, mostly single-threaded in
the final link.

`./fork.sh build fast` sets `CARGO_PROFILE_RELEASE_LTO=false` and
`CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16`: links in ~2 min instead of ~10, at a
runtime cost you won't feel in an editor. Use it while iterating on a patch.
Its artifacts hash differently, so the *first* fast build is a full rebuild and
both caches then live side by side — pick one mode and stay in it.

`target/` grows without bound because cargo never garbage-collects old
artifacts; three builds left 22 GB behind. `./fork.sh clean` resets it. Adding
`CARGO_PROFILE_RELEASE_DEBUG=false` to a build cuts the steady state roughly in
half, at the cost of poorer crash traces.

## Rollback

```bash
./fork.sh rollback   # restores the stock 1.14.2 app from the backup
```

`auto_update` is `false` in your settings, which is what keeps stock Zed from
overwriting this build.

## Upstreaming

Both commits are written as upstream-shaped changes (setting documented in
`docs/src/terminal.md`, task field in `docs/src/tasks.md`, defaults in
`assets/settings/default.json`). If either lands upstream, drop it from
`patches` and the maintenance burden goes with it.

Related upstream threads: issue #19996 (shell title in tab), PR #26122 (where
`show_rerun` came from).
