# Worktree Cleaner

A small macOS app that finds git worktrees whose work is already merged and removes the
ones you pick, so finished agent and feature checkouts stop eating disk space. Build caches
stay: the shared compiler cache and each repository's main checkout are never touched.

Worktree Cleaner is open source under the MIT license (`LICENSE`).

## Simple screen

The app opens on one screen: how much space can be freed, from how many finished
worktrees, and a **Clean** button. Clean removes everything in the "Safe to remove" group
below (each re-checked first, see Removing) and tidies git's records of folders that no
longer exist, then shows how much was freed and anything skipped. The first time, it asks
for confirmation; tick "Do not ask again" to skip that. The bottom line shows free disk
space and how many other worktrees were left alone. Show Details, or the Simple / Details
switch in the toolbar, opens the full list.

Scan Again (⌘R) turns into a spinner while it runs. On the simple screen the numbers fade,
Clean is disabled, and "Refreshing…" appears underneath with the current step sliding in
as it changes (reading or fetching a repository, looking up pull requests, "Checking
worktrees · 5 of 20", measuring build caches).

## Details: what it shows

It looks at every git repository directly inside the scan folders (default
`~/CodexProjects`) and lists each repository's extra worktrees, wherever they live
(`.claude/worktrees`, `~/.codex/worktrees`, `/tmp`, sibling folders). Each one is checked
against the repository's main branch (`origin/HEAD`, fetched first by default) and sorted
into groups:

| Group | Meaning | Can remove |
| --- | --- | --- |
| Safe to remove | All commits are on the main branch (including squash merges), no changed or untracked files, no program using it, nothing changed recently | Yes |
| Merged, but used recently | Same, but files changed within the "recent" window (6 hours by default) or a program has its working folder inside | Yes, after you check |
| Claude app worktrees | Merged and clean, but made by the Claude desktop app | No: archive the session in Claude; the app reuses or removes it |
| Keep | Unmerged commits, changed or untracked files, locked, or a check failed | No (its build folder can be deleted) |
| Missing folders | Git still lists them, but the folder is gone | Prune Records tidies git's list |

Each row shows the total size, how much of it is the `build/` folder, the last time a
source file changed (build output, `.git`, `third_party` and dependencies are ignored), and
the branch's pull request when `gh` is available. A "Build caches" section lists ccache and
each main checkout's `build/` for reference.

## Removing

In Details, tick worktrees (or Select All per group) and press Remove Selected…. After you confirm,
each worktree is checked again just before it is deleted and skipped if anything changed
(new commits, unsaved files, a program now using it). Removal runs
`git worktree remove --force`: the force is needed because git refuses worktrees that
contain submodules, and the app's own checks replace git's. Branches and commits stay in
the repository. Results appear in the bar at the bottom (History lists them all).

Right-click a row for Reveal in Finder, Copy Path, and Delete Build Folder… (only
`<worktree>/build`, refused if git tracks files there, another worktree lives inside it,
or a program is using the worktree).

Not handled: Codex leaves a small `.codex-worktree-name` file in each
`~/.codex/worktrees/<task>/` folder; the app leaves those for Codex. Local branches are not
deleted.

## Build and run

```sh
./build.sh                                   # builds build/Worktree Cleaner.app (ad-hoc signed, local use)
open "build/Worktree Cleaner.app"
```

Requires macOS 14 or newer. Like Nightshift's app, the script uses Xcode's toolchain when
Xcode is installed, because the Command Line Tools' `swift-package` on this Mac fails to
load. Copy the app to /Applications if you want it in Launchpad. The icon is drawn by
`icon/make_icon.swift`; run `icon/make-icns.sh` to rebuild `Resources/AppIcon.icns`.

Read-only text report (same scan, never removes anything):

```sh
"build/Worktree Cleaner.app/Contents/MacOS/WorktreeCleaner" --report
```

Options: `--root PATH` (repeatable), `--no-fetch`, `--no-github`, `--recent-hours N`.

Settings (⌘,): scan folders, fetch before checking, pull request lookup, and the
"recent" window.

## Development

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

The tests build throwaway repositories with worktrees in every state (merged,
squash-merged, unmerged, changed, untracked, locked, missing, Claude app, in use, with
submodules) and check the grouping and that removal refuses anything unsafe, including
changes made after the scan.

`WORKTREE_CLEANER_SNAPSHOT=/path/name.png` scans, renders the Details list to `name.png`
and the simple screen's states to `name-simple.png`, `-ready`, `-cleaning`, `-done` and
`-allclean.png`, plus `-refreshing.png` (cleaning, done and refreshing use sample state), then quits. Rendering happens in an
offscreen window, so buttons draw as in an inactive window (grey rather than tinted).

Sources: `Sources/WorktreeCore` (scanning, checks, removal, text report) and
`Sources/WorktreeCleaner` (the SwiftUI app).

## Verified

2026-10-16: built with Swift 6.4 (Xcode toolchain) on macOS 26; 9 tests pass. The report
and a rendered snapshot were checked against a manual audit of the same machine: they
matched (Claude app pool, unmerged and dirty worktrees kept, stale `/tmp` records listed);
a full scan with fetch took about 6 seconds. Removing worktrees and deleting build folders
were exercised by the tests on throwaway repositories, not yet by clicking in the app.

2026-10-20: added the simple screen with one-click Clean and the Simple / Details switch.
Each state (ready, cleaning, done, all clean) was rendered and checked; the 9 tests still
pass. Clean reuses the tested removal path; it was not clicked on screen against real
worktrees.

2026-10-23: refreshing shows a spinner in the toolbar and a "Refreshing…" line with the
current scan step on the simple screen. The scanner now reports each worktree checked
(covered by a new test; 10 tests pass) and the refreshing state was rendered and checked.
The sliding animation itself was not watched on screen.
