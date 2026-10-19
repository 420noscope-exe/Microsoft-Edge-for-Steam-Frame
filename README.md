# Microsoft Edge for the Steam Frame

`install-microsoft-edge-x86-FEX.sh` installs the x86-64 build of Microsoft Edge on a Steam Frame (SteamOS, ARM64) and runs it through FEX, the x86 translation layer Valve ships with the Frame. Microsoft doesn't publish an ARM64 Edge for Linux, so this is a workaround.

Everything is installed under your home folder. Nothing touches the read-only system partition, so it survives SteamOS updates.

> **Unofficial.** Not supported by Valve or Microsoft. Edge runs with `--no-sandbox` and `--disable-gpu` (see [Notes](#notes)), so it is slow and I'd avoid sensitive logins in it.

## Requirements

- A Steam Frame in **Desktop mode**.
- In Steam, under **Library → filter → Tools**, installed: **FEX-Emu** and **Steam Linux Runtime 4.0**.
- `curl` and `bsdtar`, plus an internet connection during install.

The script checks all of this first and stops with a message if something is missing.

## Install

```bash
bash install-microsoft-edge-x86-FEX.sh
```

If the script can't find the Edge package, download the latest `amd64` `.deb` from Microsoft in a browser and pass it in:

```bash
bash install-microsoft-edge-x86-FEX.sh --deb ~/Downloads/microsoft-edge-stable_<version>_amd64.deb
```

Re-running the script is safe. It replaces the Edge files and the launcher with fresh copies, so running it again is also how you update Edge.

## Use

Launch **Microsoft Edge (FEX)** from the application launcher (log out and back in if it doesn't appear at first), or run:

```bash
~/bin/edge-fex.sh
```

The first launch can take a while to show a window. To start it from Steam, add `~/bin/edge-fex.sh` as a Non-Steam Game using its full path and no compatibility tool.

## Uninstall

```bash
bash install-microsoft-edge-x86-FEX.sh --uninstall
```

## Logs

| Where | What |
|---|---|
| Terminal | The installer's progress and any error. If an install fails, the last line says why. |
| `~/edge-launch.log` | Output of the **most recent** Edge launch. It is overwritten on each launch. |

When Edge won't start, read the launch log:

```bash
cat ~/edge-launch.log
```

It records when the launcher relinked the libraries, followed by Edge's own output. Messages about `MESA-LOADER`, `gameoverlayrenderer.so` or SmartScreen timeouts are normal here. A line like `error while loading shared libraries: libXXX.so` means Edge needs a library that isn't available yet. If the log is empty or unchanged, the launcher never ran.

## Cleanup

`--uninstall` removes everything the installer created:

| Path | What it is |
|---|---|
| `~/edge-x86/` | Extracted Edge |
| `~/edge-libs/` | Library folder (symlinks into Steam's runtime plus a few downloaded libraries) |
| `~/edge-compat/` | Scratch folder the FEX compatibility tool requires |
| `~/bin/edge-fex.sh` | The launcher |
| `~/.local/share/applications/edge-fex.desktop` | Application-menu entry |
| `~/edge-launch.log` | Launch log |

It does not remove:

- **Steam's FEX-Emu and Steam Linux Runtime tools.**
- **A Steam shortcut you created.** It stays, but won't launch anything until you reinstall.
- **Edge's own profile data** (bookmarks, logins, cache). Edge normally keeps it in `~/.config/microsoft-edge` and `~/.cache/microsoft-edge`. Delete those by hand for a completely clean slate.

Downloads made during install go to a temporary folder that the script deletes when it finishes, even if it fails partway. If an install fails partway, you can re-run it, or run `--uninstall` to clear what it left.

## Architecture

```
install-microsoft-edge-x86-FEX.sh
│
├─ 1. Preflight      ARM64? FEX-Emu tool? Steam Linux Runtime? curl, bsdtar?
├─ 2. Edge           download the latest amd64 .deb from Microsoft (or --deb)
│                    extract it to ~/edge-x86 (not installed system-wide)
├─ 3. Libraries      fetch 3 libraries Steam's runtime lacks from Debian
│                    into ~/edge-libs
├─ 4. Launcher       write ~/bin/edge-fex.sh (embedded in this script)
└─ 5. Menu entry     write edge-fex.desktop for the application launcher
```

**Why it works this way.** FEX needs an x86-64 userland to run against, and on the Frame that comes from Steam's **Steam Linux Runtime 4.0**, which is built for games. Edge needs a few libraries that runtime doesn't ship (`libatk-bridge`, `libatspi`, `libXRes`), so the installer downloads those from Debian. They are copied into `~/edge-libs`.

**The launcher** (`~/bin/edge-fex.sh`) runs on every start and does three things:

1. Finds the newest `steamrt4_platform_*` folder under Steam's runtime and checks that `~/edge-libs` links into it. If not, it rebuilds the links. This handles Steam updating its runtime, which would otherwise leave them pointing at nothing. Libraries downloaded from Debian are never overwritten.
2. Starts Edge through FEX's compatibility tool with `LD_LIBRARY_PATH` set to `~/edge-libs`.
3. Passes `--class=edge-fex`, which matches `StartupWMClass=edge-fex` in the menu entry so the taskbar keeps Edge's icon.

If the newest runtime folder has no libraries yet (for example, Steam is still downloading it), the launcher stops and writes a message to the log.

## Notes

- `--no-sandbox` turns off Chromium's process sandbox, which is needed because it tends to break under emulation. It makes it easier for a malicious page to affect the rest of your account.
- `--disable-gpu` is needed because GPU acceleration doesn't pass through emulation, so heavy pages and video are slow.
- Edge isn't managed by a package manager here, so updates are manual (re-run the installer).
- The Debian libraries are downloaded over HTTPS, but their signatures aren't verified. The installer takes the newest version of each; if one is too new for Steam's runtime, Edge fails with a `GLIBC_2.xx not found` message in the launch log.
- If Debian renames one of those packages, the installer fails at that step with the URL it tried. Adjust the `fetch_deb` lines near the end of the "Libraries" step in the script.
