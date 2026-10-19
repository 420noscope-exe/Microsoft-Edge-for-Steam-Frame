---
title: Running Microsoft Edge on the Steam Frame (x86-64 via FEX)
tags: [steam-frame, steamos, fex, edge, arm64, how-to]
created: 2026-10-12
status: working on the Frame (terminal and app launcher); Steam shortcut not retested since the auto-relink script
---

# Running Microsoft Edge on the Steam Frame

Microsoft only ships Edge for Linux on **x86-64**, and the Steam Frame is **ARM64**. There's no native build and no Edge Flatpak for ARM. This guide gets the x86-64 build of Edge running through **FEX**, the x86 translation layer Valve ships with the Frame.

> [!warning] Unofficial and experimental
> Nothing here is documented by Valve or Microsoft. It was worked out step by step on a real Frame (Edge 155.0.4283.45, Steam Linux Runtime 4.0 build `4.0.20260805.254769`). Versions will drift, so expect to adapt things.

> [!tip] If you just want a browser
> Chromium from Flathub (`org.chromium.Chromium`) runs natively on ARM64, is the same engine as Edge, and needs none of this. Use this guide only if you specifically want Edge.

## How it works (the short version)

- FEX translates x86-64 instructions to ARM64, but needs an x86-64 userland to run against.
- Valve's setup gets that userland from the **Steam Linux Runtime 4.0** tool, not from a standalone rootfs.
- Running Edge by hand skips Steam's container, so Edge can't find its libraries. The fix here is to build a small folder of x86-64 libraries (`~/edge-libs`) and point Edge at it with `LD_LIBRARY_PATH`.
- Steam's runtime is built for games, so a few browser-specific libraries are missing. We download those from Debian.

## Result

- Edge launches and opens a window from a terminal, from the desktop-mode application launcher, and (before the latest runtime update) from a Steam shortcut.
- It runs with `--no-sandbox` and `--disable-gpu`, so expect it to be slow on heavy pages and video.
- A few Edge background services (SmartScreen, the new-tab feed) log timeouts. See [[#What the output means]].

---

## 1. Prerequisites

- [ ] Steam Frame in **Desktop mode** (KDE Plasma), with a terminal (Konsole).
- [ ] In Steam: **Library → filter → Tools**, then install:
  - **FEX-Emu** (the tool's internal name is `fex`)
  - **Steam Linux Runtime 4.0**
- [ ] Verify both are intact: right-click each tool → **Properties → Installed Files → Verify integrity**.
- [ ] A working network connection (for the `.deb` downloads).

Confirm FEX is in place:

```bash
ls ~/.steam/steam/steamapps/common/FEX-Emu
```

You should see `fex-compat-tool`, `emulator.json`, `usr`, and so on.

> [!note] Dead end: don't use `/usr/bin/FEXBash`
> That's only a wrapper that expects Steam's tool folders. It complains about a missing RootFS and `SteamLinuxRuntime_4`. The `fex-compat-tool` route below is the one that works. Also note that `/proc/sys/fs/binfmt_misc` has no x86 handler on the Frame, so x86 Flatpaks (`flatpak install --arch=x86_64 ...`) don't work either.

## 2. Download and extract Edge (don't install it)

Get the latest `amd64` `.deb` from Microsoft's repository, either in a browser or with curl:

```bash
B=https://packages.microsoft.com/repos/edge/pool/main/m/microsoft-edge-stable
f=$(curl -s $B/ | grep -oE 'microsoft-edge-stable_[^"]*_amd64\.deb' | sort -uV | tail -1)
echo "$f"
mkdir -p ~/Downloads && curl -o ~/Downloads/"$f" "$B/$f"
```

Extract it into your home folder. SteamOS's root filesystem is read-only, so we run Edge from here instead of installing it:

```bash
mkdir -p ~/edge-x86 && cd ~/edge-x86
bsdtar -xf ~/Downloads/microsoft-edge-stable_*_amd64.deb
bsdtar -xf data.tar.xz
ls -l opt/microsoft/msedge/msedge
```

Check which file is the real binary:

```bash
file opt/microsoft/msedge/msedge opt/microsoft/msedge/microsoft-edge
```

`msedge` should be `ELF 64-bit ... x86-64`. `microsoft-edge` is only a shell script, so always launch `msedge`.

## 3. Build the library folder from Steam's runtime

Find the runtime's library folder. The version number in the path changes between updates, so use a wildcard:

```bash
R=$(ls -d ~/.local/share/Steam/steamapps/common/SteamLinuxRuntime_4/steamrt4_platform_*/files | tail -1)
L=$R/lib/x86_64-linux-gnu
echo "$L"
ls "$L" | head
```

The runtime's libraries have long versioned names (`libglib-2.0.so.0.8400.4`) without the short names Edge asks for (`libglib-2.0.so.0`). Make a folder of symlinks with both:

```bash
mkdir -p ~/edge-libs && cd ~/edge-libs

# link every library under its full name
for f in "$L"/*.so*; do ln -sf "$f" "$(basename "$f")"; done

# add the short soname (libfoo.so.N) for each versioned file (libfoo.so.N.x.y)
for f in "$L"/*.so.*.*; do
  b=$(basename "$f")
  ln -sf "$f" "$(echo "$b" | sed -E 's/(\.so\.[0-9]+)\..*/\1/')"
done

ls ~/edge-libs | grep -E 'glib-2|nss3|nspr4'
```

This leaves Steam's own files untouched, and you can delete `~/edge-libs` at any time.

> [!note]
> You only need to run this by hand once. The launcher script in section 6 repeats these steps automatically whenever Steam updates its runtime.

## 4. Add the libraries the runtime doesn't ship

Define a helper that downloads a Debian package and copies its libraries into `~/edge-libs`:

```bash
mkdir -p ~/edge-debs
fetch() {  # usage: fetch <pool subdir> <package name>
  B=https://deb.debian.org/debian/pool/main/$1
  f=$(curl -s $B/ | grep -oE "$2_[^\"]*_amd64\.deb" | sort -uV | tail -1); echo "got: $f"
  cd ~/edge-debs && rm -rf d x && mkdir d x && curl -sO "$B/$f" \
    && bsdtar -xf "$f" -C d && bsdtar -xf d/data.tar.* -C x \
    && cp -a x/usr/lib/x86_64-linux-gnu/*.so* ~/edge-libs/
}
```

Then fetch the three that turned out to be missing:

```bash
fetch a/at-spi2-core libatk-bridge2.0-0t64
fetch a/at-spi2-core libatspi2.0-0t64
fetch libx/libxres libxres1
```

Each should print a `got: ..._amd64.deb` line. If one prints `got:` with nothing after it, the package name or pool directory has changed. Browse `https://deb.debian.org/debian/pool/main/` to find the new one.

### Optional: check for any other missing libraries

Edge's own bundled `.so` files have dependencies too, so scan everything:

```bash
cd ~/edge-x86/opt/microsoft/msedge
for f in msedge *.so*; do readelf -d "$f" 2>/dev/null | grep NEEDED | sed -E 's/.*\[(.*)\]/\1/'; done \
  | sort -u | while read n; do [ -e ~/edge-libs/$n ] || echo "MISSING: $n"; done
```

Ignore these:

- `libc.so.6`, `libm.so.6`, `libdl.so.2`, `libpthread.so.0`, `librt.so.1`, `ld-linux-x86-64.so.2`: they come from the loader.
- `libQt5*` and `libQt6*`: optional theming and dialog shims that Edge works without.

Anything else is a real gap. Find its Debian package at <https://packages.debian.org> and `fetch` it the same way.

## 5. Launch Edge by hand

```bash
mkdir -p ~/edge-compat
cd ~/edge-x86/opt/microsoft/msedge

LD_LIBRARY_PATH=$HOME/edge-libs \
STEAM_COMPAT_DATA_PATH=$HOME/edge-compat \
STEAM_COMPAT_CLIENT_INSTALL_PATH=$HOME/.local/share/Steam \
~/.local/share/Steam/steamapps/common/FEX-Emu/fex-compat-tool run -- ./msedge --no-sandbox --disable-gpu
```

- `STEAM_COMPAT_DATA_PATH` and `STEAM_COMPAT_CLIENT_INSTALL_PATH` are required: without the first, the tool just says "No compat data path?".
- `--no-sandbox` is needed because Chromium's sandbox tends to break under emulation. It also weakens browser security (see [[#Security notes]]).
- `--disable-gpu` is needed because GPU acceleration doesn't pass through the emulation layer.

The first window can take a while to appear.

### What the output means

| Message | Meaning |
|---|---|
| `error while loading shared libraries: libXXX.so` | A missing x86-64 library. Look in the runtime (`ls "$L" \| grep XXX`) or `fetch` it from Debian, then retry. |
| `MESA-LOADER: failed to open dri ... dri_gbm.so` | Harmless GPU probe failure (GPU is disabled). |
| `smartscreen_dns_resolver ... DidTimeOut` | Edge's SmartScreen and new-tab services timing out. |
| `handshake failed ... SSL error` | A few background connections failing. Check normal browsing, below. |
| `welcome-edge ... importerType` | A JavaScript error on the first-run page, probably a side effect of the failed requests. |

**Check that normal browsing works:** load a couple of ordinary HTTPS sites. If they load, the errors are limited to Microsoft's background services and can be ignored. If pages fail or show certificate errors, DNS or root certificates are probably broken inside the emulated environment, which is a separate problem to dig into.

## 6. Launch from Steam with a self-healing script

Steam's compatibility-tool route (forcing `fex` on the Edge shortcut) exits within a couple of seconds with no error. A launcher script that calls FEX itself works instead, and it logs what happens.

The script also solves a second problem: Steam periodically updates the Linux Runtime and installs a new `steamrt4_platform_<version>` folder. The symlinks in `~/edge-libs` point into the old one and go stale, and Edge then fails with `libglib-2.0.so.0` missing. So the script checks the links on every launch and rebuilds them against the newest runtime when needed. It adds no noticeable delay when the links are already good.

> [!note] Status
> Launching through a script from Steam worked on the Frame on 2026-10-12, then broke after a runtime update (`4.0.20260805.254769` → `4.0.20260928.262390`). The auto-relinking version below is what runs on the Frame now (via the app-launcher entry in section 7). Its relink logic was also tested in a sandbox with fake runtime folders: it relinks stale links, skips relinking when they're fine, keeps downloaded Debian files, and stops with a clear message if the runtime is empty. The Steam shortcut hasn't been retested since the switch to this version, though it runs the same script.

### Create the script

```bash
mkdir -p ~/bin
cat > ~/bin/edge-fex.sh <<'EOF'
#!/bin/bash
# Launch x86-64 Microsoft Edge on the Steam Frame through FEX.
# Relinks ~/edge-libs against the newest Steam Linux Runtime when needed,
# so Steam runtime updates don't break it. Log of the latest launch: ~/edge-launch.log

LOG=$HOME/edge-launch.log
LIBS=$HOME/edge-libs
STEAM=$HOME/.local/share/Steam
SLR=$STEAM/steamapps/common/SteamLinuxRuntime_4

exec >"$LOG" 2>&1
echo "=== $(date) ==="

# Newest runtime that has its files
R=$(ls -d "$SLR"/steamrt4_platform_*/files 2>/dev/null | sort -V | tail -1)
L=$R/lib/x86_64-linux-gnu
if [ -z "$R" ] || ! ls "$L"/libglib-2.0.so.0* >/dev/null 2>&1; then
  echo "ERROR: no x86-64 libraries found in the Steam Linux Runtime ($L)."
  echo "Verify 'Steam Linux Runtime 4.0' in Steam (Properties > Installed Files)."
  exit 1
fi

# Relink only if the links don't already point into this runtime
mkdir -p "$LIBS"
cur=$(readlink "$LIBS/libglib-2.0.so.0" 2>/dev/null)
if [ "${cur#"$L"/}" = "$cur" ] || [ ! -e "$LIBS/libglib-2.0.so.0" ]; then
  echo "Relinking libraries against $R"
  find "$LIBS" -type l -lname '*steamrt4_platform_*' -delete
  cd "$LIBS" || exit 1
  for f in "$L"/*.so*; do
    n=$(basename "$f")
    [ -e "$n" ] && [ ! -L "$n" ] && continue   # keep downloaded Debian files
    ln -sf "$f" "$n"
  done
  for f in "$L"/*.so.*.*; do
    n=$(basename "$f" | sed -E 's/(\.so\.[0-9]+)\..*/\1/')
    [ -e "$n" ] && [ ! -L "$n" ] && continue
    ln -sf "$f" "$n"
  done
fi

cd "$HOME/edge-x86/opt/microsoft/msedge" || exit 1
mkdir -p "$HOME/edge-compat"
LD_LIBRARY_PATH=$LIBS \
STEAM_COMPAT_DATA_PATH=$HOME/edge-compat \
STEAM_COMPAT_CLIENT_INSTALL_PATH=$STEAM \
exec "$STEAM/steamapps/common/FEX-Emu/fex-compat-tool" run -- ./msedge --no-sandbox --disable-gpu --class=edge-fex "$@"
EOF
chmod +x ~/bin/edge-fex.sh
```

The `--class=edge-fex` flag gives Edge's window a fixed name, which section 7 uses to keep the right icon on the taskbar. It's harmless if you never create a launcher entry.

Test it from a terminal first: `~/bin/edge-fex.sh`. Edge should open, and `~/edge-launch.log` shows what happened. The log holds only the latest launch, since each launch overwrites it.

### Point Steam at the script

If you already have an Edge shortcut, edit it. Otherwise use **Add a Game → Add a Non-Steam Game** and browse to the script (set the file picker's filter to "All files").

- **Target:** `/home/steamos/bin/edge-fex.sh`. Use the full absolute path, since Steam may not expand `~`.
- **Start In:** `/home/steamos/bin/`
- **Launch Options:** leave empty. The script supplies `--no-sandbox` and `--disable-gpu`.
- **Compatibility:** untick "Force the use of a specific Steam Play compatibility tool", so Steam runs the script natively.

### If it doesn't open

```bash
cat ~/edge-launch.log
```

- **Empty or missing log:** Steam never ran the script. Check the Target path and that the script is executable (`ls -l ~/bin/edge-fex.sh`).
- **`ERROR: no x86-64 libraries found ...`:** the newest runtime folder has no files, often because Steam is still downloading it. Verify **Steam Linux Runtime 4.0** in Steam (Properties → Installed Files → Verify integrity) and try again.
- **A different `error while loading shared libraries` line:** the new runtime may lack a library the old one had. `fetch` it as in section 4.
- **`ld.so: object '...gameoverlayrenderer.so' ... cannot be preloaded`:** Steam's overlay failing to load into the emulated process. This is harmless and ignored.

## 7. Add Edge to the application launcher

A `.desktop` file in your home folder makes Edge appear in KDE Plasma's application launcher in desktop mode. It survives SteamOS updates because it lives in `~/.local`, not the read-only system.

Check that Edge's icons are where expected:

```bash
ls ~/edge-x86/opt/microsoft/msedge/product_logo_*.png
```

If that lists `product_logo_256.png`, create the entry:

```bash
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/edge-fex.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Microsoft Edge (FEX)
GenericName=Web Browser
Comment=x86-64 Microsoft Edge running through FEX
Exec=$HOME/bin/edge-fex.sh %U
Icon=$HOME/edge-x86/opt/microsoft/msedge/product_logo_256.png
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
StartupWMClass=edge-fex
EOF
chmod +x ~/.local/share/applications/edge-fex.desktop
update-desktop-database ~/.local/share/applications 2>/dev/null
kbuildsycoca6
```

- The heredoc is deliberately unquoted so `$HOME` becomes your real home path (`/home/steamos`) when the file is written. Desktop entries don't expand `~` or `$HOME` themselves.
- `StartupWMClass=edge-fex` must match the `--class=edge-fex` flag in the launcher script (section 6). Together they tell Plasma which taskbar entry the Edge window belongs to.
- Search for "Edge" in the launcher. If it doesn't appear, log out and back in.
- To pin it, right-click the entry and choose **Pin to Task Manager**.

> [!bug] Symptom: the icon goes generic a few seconds after launch
> The launcher shows the right icon at startup, then the taskbar switches to a generic one once Edge's window opens. That's a window-class mismatch: Plasma matches the open window to a desktop entry by the window's class or app ID, and Edge's default name didn't match the entry. `xprop WM_CLASS` returned nothing, which suggests Edge runs as a native Wayland window (`xprop` only sees X11 windows).
>
> The fix is the pair of settings above (`--class=edge-fex` in the script and `StartupWMClass=edge-fex` in the entry). The entry's file name, `edge-fex.desktop`, also matches. After changing them, close Edge fully, unpin and re-pin it, and relaunch from the launcher.
>
> If the icon ever goes generic again, find the window's real class by right-clicking Edge's title bar → **More Actions → Configure Special Application Settings** and using the window-detection option. Then set `StartupWMClass` to that value and run `kbuildsycoca6`.

Notes:

- **Default browser:** you can choose it in System Settings → Default Applications, but every link will start a slow, emulated launch.
- **Gaming mode:** the launcher entry only exists in desktop mode. Gaming mode uses the Steam shortcut from section 6.
- **No icon at all:** use whichever `product_logo_*.png` file the `ls` above actually listed.

## Troubleshooting

- **Instant exit from Steam, no message:** run the manual command from section 5. The terminal shows the real error. Steam's compat log (`~/.steam/steam/logs/compat_log.txt`) only records that a session started and ended.
- **Still reports `libglib-2.0.so.0` missing:** the symlink folder in section 3 wasn't built, or `LD_LIBRARY_PATH` isn't reaching Edge. Re-run section 3 and check `ls ~/edge-libs | grep glib`.
- **`GLIBC_2.xx not found`:** the library you downloaded is newer than Steam's runtime provides. Use an older Debian release's package for that library.
- **After a Steam runtime update:** the folder name under `steamrt4_platform_*` changes and the symlinks go stale (Edge then reports `libglib-2.0.so.0` missing). The launcher script in section 6 rebuilds them automatically. If you launch Edge by hand instead, redo the symlink step in section 3, which is safe to repeat.
- **Generic icon on the taskbar:** see the symptom box in section 7.
- **Edge updates:** nothing updates it automatically. Repeat section 2 to replace `~/edge-x86`.

## Security notes

- `--no-sandbox` disables Chromium's process sandbox. A compromised web page has a much easier time reaching the rest of your account. I'd avoid banking and other sensitive logins in this build.
- The Debian libraries are fetched over HTTPS from `deb.debian.org`, but nothing here verifies package signatures.
- Edge isn't managed by any package manager here, so security updates are manual.

## Clean up

```bash
rm -rf ~/edge-x86 ~/edge-libs ~/edge-debs ~/edge-compat ~/bin/edge-fex.sh ~/edge-launch.log ~/.local/share/applications/edge-fex.desktop
```

This removes everything created by this guide. Steam's FEX-Emu and Steam Linux Runtime tools are left alone.
