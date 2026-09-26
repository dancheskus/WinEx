# WinEx

A Windows Explorer–style file manager for macOS 26+ that can stand in for Finder.

WinEx speaks English and Russian (Settings ▸ General ▸ Language).

## Installation

1. Download `WinEx-<version>.zip` from [Releases](https://github.com/dancheskus/WinEx/releases),
   unzip it and move `WinEx.app` to Applications.
2. First launch: WinEx isn't signed with a paid Apple certificate, so macOS won't open it with a
   double-click. Open System Settings ▸ Privacy & Security and click “Open Anyway” next to WinEx
   (or in Terminal: `xattr -dr com.apple.quarantine /Applications/WinEx.app`). This is needed once.
3. Turn WinEx on in System Settings ▸ Privacy & Security ▸ Full Disk Access — then macOS won't ask
   separately about Desktop, Documents, Downloads and network volumes, and the Trash opens.

After that WinEx updates itself: once a day it checks Releases and offers “Update and Relaunch”
(Settings, or the menu bar icon ▸ “Check for Updates…”). WinEx downloads the update itself, so macOS
doesn't ask about opening it again, and every permission is kept: all versions are signed with the
same certificate, and WinEx installs an update only if its signature matches.

## Releasing a version

```sh
git tag v1.2.0 && git push origin v1.2.0
```

The GitHub Action `.github/workflows/release.yml` builds WinEx with that version, signs it with the
“WinEx Signing” certificate (secrets `SIGNING_P12_BASE64` and `SIGNING_P12_PASSWORD`) and publishes
`WinEx-1.2.0.zip` on Releases. Local builds are marked as “own builds”: releases never replace them
(an own build may be newer), “Check Now” only reports the latest release. A full update check with
the restart, on a copy of the app: `scripts/check-self-update.sh`.

## Building and running

```sh
./build.sh          # builds build/WinEx.app (release)
open build/WinEx.app
```

Only the Command Line Tools (Swift 6.2+) are needed; Xcode is optional.

### Signing and permissions

Run `scripts/setup-signing.sh` once: it creates a self-signed “WinEx Signing” certificate (a copy
and its password go to `~/.winex-signing` — keep them somewhere safe) and puts it into a separate
keychain, `~/.winex-signing/signing.keychain-db`, with its own password — so signing never asks for
your login password — and `build.sh` signs every build with it. On another Mac:
`scripts/setup-signing.sh file.p12`. GitHub Actions sign releases with the same certificate.
macOS then treats new builds as the same app, and permissions (Full Disk Access, Desktop, Documents,
Downloads, network volumes) are granted once instead of after every rebuild. Without the
certificate builds are signed ad hoc, and permissions reset with every build.

## Testing

```sh
swift test                         # unit tests of the logic (names, tags, .DS_Store, undo, shortcuts, placement…)
scripts/run-scenario.sh undo       # a scenario inside the app: undo, newfolder, slowclick, perf, desktop,
                                   # hittest, placement, placement2, desktopreset, monitorgone, fileops, search,
                                   # filecommands, drives, trashaccess, update, addressclick, breadcrumbs, look,
                                   # contextmenu, unzip, paste, sidebar, commandbar, menuswitch, properties,
                                   # terminal, session; mousedrag — with the real mouse, together with
                                   # scripts/mouse-drag-check.swift
scripts/capture-window.sh settings 7   # photographs the windows a scenario shows (build/scenario-<name>/)
```

Scenarios exist in debug builds only: the app drives itself from the inside (no real mouse or
keyboard), writes a log and quits. A scenario has its own settings — your WinEx settings and the
“instead of Finder” mode are left alone.

### Starting from scratch

```sh
scripts/reset-to-fresh.sh --dry-run            # what would be done
scripts/reset-to-fresh.sh                      # WinEx as if never installed
scripts/reset-to-fresh.sh --install-release    # …and the latest release in /Applications, as a download
```

It quits WinEx, gives the desktop back to Finder, removes the login item, resets every privacy
permission WinEx asked for (`tccutil reset All dev.winex.WinEx`) and deletes all its settings,
caches and saved state. Files, Finder's own settings and the signing certificate are left alone.
With `--install-release` the app is marked as downloaded from the internet, so the first launch
meets Gatekeeper like a new user's. For a truly clean Mac (nothing else installed, a different
macOS language) use a separate user account or a macOS virtual machine.

## Languages

WinEx speaks Russian and English. Settings ▸ General ▸ Language: the system's language (Russian if
macOS is in Russian, English otherwise) or either of the two. Changing it restarts WinEx at once,
with the same windows, tabs and places.

Interface texts are written in Russian in the code and wrapped in `L("…")`; the translations are in
`Sources/WinEx/Localization/English.swift` (the key is the Russian text). After adding texts:

```sh
scripts/check-translations.py   # which texts have no translation yet
```

The English interface in scenarios: `WINEX_LANG=en scripts/capture-window.sh settings 7`.

## Features

- Tabs: drag them around, tear one off into a new window (drag it up or down off the tab strip),
  drop a tab onto another window's tab strip. The middle mouse button closes a tab.
- Back / Forward / Up (⌘[ ⌘] ⌘↑). Keys as in Finder: Return renames, ⌘↓ / ⌘O open.
  The “Windows keys” setting (off by default): Return opens, F2 renames, Backspace goes up.
  Arrows and ⇧+arrows work in the table, in the grid and on the desktop.
- A Windows 11 address bar: the path as buttons (This Mac › Macintosh HD › Users › …; on a network
  volume — Network › server › share); a click on a step goes there, “›” lists that step's
  subfolders (the icon on the left lists the drives), a long path folds into “…” (with a list of the
  hidden steps). A click on the empty part (or ⌘L / F4) switches to typing a path with the whole
  path selected; Esc goes back. `~` and `file://` work. Right-click: copy the address (path or URL),
  edit it, add the folder to Favorites, clear the back/forward history.
- The command bar under the address bar (can be switched off): New ▾, cut / copy / paste /
  rename / share / delete, Sort ▾ (with More ▸ size, date created, date added; ascending /
  descending), View ▾ (every view, Show ▸ hidden files / the command bar, apply to all folders),
  “…” (compress to ZIP, add to Favorites, copy path, select all / none / invert, properties,
  settings). With a menu open, a click on another command opens that one.
- A Windows 11 context menu: a row of buttons on top (cut, copy, rename, share, delete), then items
  with icons and shortcuts; “Open” shows the app's icon. Roomy rows, small quiet checkmarks and
  submenu arrows. Right-clicking a file selects it. Optionally “Open in Terminal” (Settings ▸
  General) with the terminal of your choice — Terminal, iTerm, Warp, Ghostty, kitty, Alacritty,
  WezTerm, Hyper, Tabby, Rio or any app: a folder opens as is, a file — its folder, an empty spot —
  the folder on screen or the desktop.
- Sounds like Finder's: moving to the Trash, deleting, finishing a paste or a move (when user
  interface sound effects are on in Sound settings).
- ZIP compression and extraction with a progress window (percentage, current file, cancel);
  exactly the selection goes into the archive (a file without the folder it's in).
- The sidebar, as in Finder:
  - Favorites: standard folders plus pinned ones; drop folders between them to pin, drag to
    reorder, “Remove from Sidebar” in the right-click menu;
  - Locations: This Mac, iCloud Drive, disks and network shares (⏏ eject), AirDrop (the system
    window), Network (Bonjour servers, connect with the system login), Trash (put back, delete
    immediately, empty; a bar with “Empty” on top; needs Full Disk Access);
  - Tags.
  Files dropped on an entry go into that folder or disk, to the Trash, or get the tag. The sidebar
  keeps its width when the window is resized (170 pt at least). What it shows: Settings ▸ Sidebar.
  “Connect to Server…” — ⌘K; “Share…” (AirDrop and more) — in the context menu.
- Views: extra large / large / medium / small icons, list, details, tiles (the View button,
  ⌘1…⌘7, ⌘+scroll wheel or pinch — like Ctrl+wheel in Windows). Icons show thumbnails of pictures
  and documents. The view is remembered per folder; “View ▸ Apply to All Folders” makes the current
  view the default and forgets the remembered ones.
- Details view columns: right-click the header to size one column or all of them to fit and to
  show or hide columns (Date Modified, Date Created, Date Added, Type, Size, Tags); the order,
  widths and choice are remembered.
- Space — Quick Look of the selected files, in windows and on the desktop; arrows move between
  files while it's open.
- Windows-style selection in every view: ⇧-click selects a range from the anchor, ⌘-click adds or
  removes, ⇧⌘-click adds a range, ⇧+arrows, Home/End, a rubber band on an empty spot, type-to-select.
- Files: sorting, search by name, context menu, rename (F2), new folder (⇧⌘N), copy / cut / paste
  files (⌘C / ⌘X / ⌘V; cut files fade until they're pasted or something else is copied; pasting
  moves them), to the Trash (⌘⌫), drag files to other apps.
- A Dock icon (Explorer's yellow folder with its blue band, on a blue squircle; redraw it with `swift Resources/make-icon.swift`). A click brings
  the windows forward, unminimizes, or opens a new one; right-click lists the open folders (tabs
  grouped by window) and “New Window”. The menu bar icon stays: “Quit” there brings Finder back.
- Undo / Redo (⌘Z / ⇧⌘Z): renaming, moving to the Trash, moving, copying, creating folders and
  files, tag changes — one history for all windows and the desktop; while text is being typed (a
  name, the path), ⌘Z undoes the typing.
- Properties (⌘I or ⌥↩, like Alt+Enter) in WinEx's own look, with tabs:
  - General: type, the app it opens with (can be changed), location (“Show”), size and contents
    (counted in the background), dates created / modified / opened / added;
  - Details — what matters for the kind of file: pictures (dimensions, megapixels, DPI, color,
    camera, lens, exposure, focal length, place with a map link), audio and video (duration,
    frame size and rate, codecs, bit rates, channels), PDF (pages, paper size, title, author,
    producer), text (lines, words, encoding), apps (version, identifier, processors, minimum
    macOS), where a download came from;
  - Access: owner, group, permissions in words and as a code, what you may do; the Read Only and
    Hidden attributes.
- Finder tags: the row of colored circles in the context menu, colored dots by the names, the Tags
  column, Tags ▸ (with “New Tag…”); the sidebar's tags list every file with the tag (Spotlight).
  Settings ▸ Tags: every tag — color, rename and delete (on all files), whether the sidebar shows
  it and whether it's a favorite; favorites are shared with Finder. Folders take their tag's color
  (can be switched off).
- “Customize Folder…” as in macOS 26: a color (tag), a symbol or an emoji on the folder — in
  Finder's format (the `com.apple.icon.folder#S` attribute), so Finder shows the same.
- A Windows context menu: Open With ▸ (the system's apps plus “Choose Another App…”), New ▸ folder
  and files — txt, RTF, Markdown, Word, Excel, PowerPoint (only when some app opens them), Sort By ▸,
  View ▸. Files and folders can be dragged between windows, onto folders and onto the desktop
  (⌥ copies).
- Windows remember their place, size and monitor: a new window opened when no other is open comes
  back where the last moved, resized or closed window was (at quit — the front one; if its monitor
  is gone — on the main one). Further windows cascade from the front one, same size. A window left
  mostly off screen after a monitor change is moved back onto a monitor.
- This Mac (first under Locations): every drive with a usage bar (red above 90%) and “X free of
  Y”, network ones separately; double-click opens, “Eject” in the menu.
- The status bar shows the size of the selection: files at once, folders counted in the background
  (low priority, after a pause in selecting, cancelled when the selection changes).
- An empty list explains itself: “This Folder Is Empty”, “Nothing Found”, “No Access to the Trash”
  (with a button for the Full Disk Access settings; once access is granted, the Trash reloads by
  itself when you come back to WinEx).
- “New windows open in”: the home folder, Desktop, Downloads, Documents, This Mac or any folder —
  for new windows, the Dock icon and the global shortcut.
- Finder's commands (context menu and File): Duplicate (⌘D), Compress (one item → “name.zip”,
  several → “Archive.zip”), Extract (a double-click on a .zip extracts it next to it, without
  Archive Utility), Make Alias (⌃⌘A), Show Original, Show Package Contents. An alias of a folder
  opens in WinEx. Everything can be undone with ⌘Z.
- A global shortcut, like Win+E: opens a WinEx window from any app (⌥⌘E by default; another one or
  off in Settings). Registered with the system — no keyboard monitoring.
- Always: ⌃Tab / ⌃⇧Tab and ⌃1…9 switch tabs; dragging with ⌘ moves (even to another disk), with
  ⌥ copies, with ⌘⌥ makes an alias. With “Windows keys” also F3, F4 / ⌥D, F5, F11, Delete,
  ⇧Delete, ⌥← ⌥→ ⌥↑, ⇧F10 (arrows and Delete don't get in the way of text fields).
- Search (⌘F or the field in the toolbar): in the current folder and its subfolders (or the whole
  Mac — the field's menu), in names (every word, case-insensitive) and in file contents. Results
  behave like a folder: Back returns, a Folder column, “Show in Folder”, live updates. Recent
  searches are in the field's menu. It runs on Spotlight: no index of its own, no background
  scanning — while you don't search, WinEx doesn't use the processor. A query starts 0.35 s after
  typing, shows up to 2000 best matches, live updates at most twice a second, and stops as soon as
  the results are hidden. Folders Spotlight doesn't index (network volumes, some external drives)
  are walked by name once, at low priority and with a limit (⌘R — again).
- Copy, move, Trash and delete work as in Windows: if the job takes longer than half a second, a
  progress window shows the percentage, pause, cancel, a speed graph, time and items left (“Fewer /
  More Details”). When names collide — “Replace or Skip Files”: replace (the old files go to the
  Trash), skip, or decide for each file (replace / skip / keep both). On APFS copies are clones
  (instant, no extra space).
- Folders are read in the background: the window doesn't freeze even with tens of thousands of
  files, and a stream of changes (copying thousands of files) updates the list a few times, not
  once per file.

## The WinEx desktop

- A click on an empty spot moves the windows aside, like “Click wallpaper to reveal desktop” in
  Desktop & Dock (follows that setting and “Show items on Desktop / in Stage Manager”).
- File thumbnails (with rounded corners), colored tags, drives as set in Finder (“Show these items
  on the desktop”), “Eject”.
- Labels as in Finder: as wide as Finder's, in its bold weight, up to two lines; a long name loses
  its middle on the second line so the extension stays visible; the tag dot stays in front of the
  name.
- Several monitors: each has its own desktop with its own icons; icons can be dragged between
  them. When a monitor is unplugged (a laptop without its monitors), its icons are shown on the
  remaining one — in free spots, never on top of the icons living there — and go back when the
  monitor returns.
- On first launch it takes the icon layout from Finder (`~/Desktop/.DS_Store`, `dilc` records:
  bytes 0…3 — the monitor), then keeps its own. Icons avoid desktop widgets, as in Finder.
- Icons can be dragged with the mouse, selected with a rubber band, renamed (F2).
- Menu: View ▸ large / medium / small icons, Auto Arrange Icons, Align Icons to Grid, Show Desktop
  Icons; Sort By ▸ name / size / type / date; New ▸ — the new file appears where the menu was opened.

## First launch

A setup assistant walks through the essentials, each step can be skipped: language, Full Disk
Access (with a live status), WinEx instead of Finder, Finder or Windows keys and the global shortcut,
the default folder view, the command bar, hidden files, opening at login, updates and where new
windows open. It slides from step to step, comes back after a restart it asked for (a new language,
Full Disk Access), and can be run again from Settings ▸ General or the menu. People who used WinEx
before it existed don't see it after updating.

## Settings

- General: language, where new windows open, the default folder view, the global shortcut, hidden files, the command bar,
  “Open in Terminal” and the terminal, “Open WinEx at login” (a login item — at login WinEx starts
  without a window); save every setting to a file — with the favourite tags, the login item and the
  sample files of your own New ▸ types — load them back (WinEx restarts with the same
  windows), or restore the defaults (the desktop icon arrangement and the Finder mode stay).
- Sidebar: which favorites, locations and tags it shows.
- Tags: the tag editor (see above).
- Finder: “Use WinEx instead of Finder”; “Reset the Desktop as in Finder…” (after a confirmation)
  forgets WinEx's arrangement and takes Finder's icon places (`~/Desktop/.DS_Store`), icon size and
  sorting (`DesktopViewSettings`).
- Keyboard: “Windows keys” and the list of shortcuts.
- Access: Full Disk Access status.
- Updates: automatic checks, “Check Now”, the releases page.

## “Instead of Finder” mode (Settings ▸ Finder)

When it's on:
- `defaults write -g NSFileViewer dev.winex.WinEx` — “Show in Finder” in other apps opens WinEx;
- `defaults write com.apple.finder CreateDesktop -bool false` plus a Finder restart — WinEx draws
  the desktop.

WinEx can't become the default app for folders: on macOS 26+ LaunchServices answers `paramErr (-50)`
to a change of the `public.folder` handler. So folders that other apps open directly
(`open ~/Documents`) still open in Finder.

Quitting WinEx undoes all of it. If WinEx crashes or is killed, a watchdog — a separate process
waiting for WinEx to go away — gives the desktop back to Finder. If the desktop is gone anyway:

```sh
defaults delete com.apple.finder CreateDesktop; defaults delete -g NSFileViewer; killall Finder
```
