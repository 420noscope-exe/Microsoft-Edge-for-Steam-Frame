#!/bin/bash
# install.sh - set up x86-64 Microsoft Edge on the Steam Frame (SteamOS, ARM64) through FEX.
#
# Everything is installed under $HOME. Nothing touches the read-only system partition.
#
# Usage:
#   bash install.sh              download the latest Edge and set everything up
#   bash install.sh --deb FILE   use an Edge .deb (amd64) you already downloaded
#   bash install.sh --uninstall  remove everything this script created
#   bash install.sh --help

set -euo pipefail

STEAM=$HOME/.local/share/Steam
FEX_TOOL=$STEAM/steamapps/common/FEX-Emu/fex-compat-tool
SLR=$STEAM/steamapps/common/SteamLinuxRuntime_4

EDGE_DIR=$HOME/edge-x86
LIBS=$HOME/edge-libs
COMPAT=$HOME/edge-compat
LAUNCHER=$HOME/bin/edge-fex.sh
DESKTOP_FILE=$HOME/.local/share/applications/edge-fex.desktop
LOG=$HOME/edge-launch.log

MS_REPO=https://packages.microsoft.com/repos/edge/pool/main/m/microsoft-edge-stable
DEB_POOL=https://deb.debian.org/debian/pool/main

info() { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

uninstall() {
  [ -n "${HOME:-}" ] || die "HOME is not set."
  info "Removing Edge-on-Steam-Frame files"
  rm -rf "$EDGE_DIR" "$LIBS" "$COMPAT"
  rm -f "$LAUNCHER" "$DESKTOP_FILE" "$LOG"
  update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
  command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 >/dev/null 2>&1 || true
  info "Done. Steam's FEX-Emu and Steam Linux Runtime tools were left alone."
  exit 0
}

DEB_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --deb)       [ $# -ge 2 ] || die "--deb needs a file path"; DEB_FILE=$2; shift 2 ;;
    --uninstall) uninstall ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "Unknown option: $1 (try --help)" ;;
  esac
done

# --- Preflight ---------------------------------------------------------------
[ "$(uname -m)" = "aarch64" ] || die "This is meant for an ARM64 machine (the Steam Frame). uname -m says: $(uname -m)"
[ -x "$FEX_TOOL" ] || die "FEX-Emu tool not found. In Steam: Library > filter: Tools > install FEX-Emu."
ls -d "$SLR"/steamrt4_platform_*/files >/dev/null 2>&1 \
  || die "Steam Linux Runtime 4.0 not found. In Steam: Library > filter: Tools > install it."
for cmd in curl bsdtar; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed."
done
if [ -n "$DEB_FILE" ]; then
  [ -f "$DEB_FILE" ] || die "File not found: $DEB_FILE"
  DEB_FILE=$(cd "$(dirname "$DEB_FILE")" && pwd)/$(basename "$DEB_FILE")
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- 1. Get and extract Edge (not installed system-wide) ------------------------
if [ -z "$DEB_FILE" ]; then
  info "Looking up the latest Microsoft Edge (amd64) package"
  name=$(curl -fsSL "$MS_REPO/" | grep -oE 'microsoft-edge-stable_[^"<> ]*_amd64\.deb' | sort -uV | tail -1) || true
  [ -n "$name" ] || die "Couldn't find the Edge .deb in Microsoft's repository. Download the amd64 .deb in a browser and rerun with: bash install.sh --deb /path/to/file.deb"
  info "Downloading $name"
  curl -fL --progress-bar -o "$TMP/edge.deb" "$MS_REPO/$name"
  DEB_FILE=$TMP/edge.deb
fi

info "Extracting Edge into $EDGE_DIR"
mkdir -p "$TMP/edge"
( cd "$TMP/edge" && bsdtar -xf "$DEB_FILE" && bsdtar -xf data.tar.* -C "$TMP/edge" )
[ -d "$TMP/edge/opt/microsoft/msedge" ] || die "Unexpected package layout: opt/microsoft/msedge not found in the .deb."
rm -rf "$EDGE_DIR"
mkdir -p "$EDGE_DIR"
mv "$TMP/edge/opt" "$EDGE_DIR/opt"
[ -f "$EDGE_DIR/opt/microsoft/msedge/msedge" ] || die "msedge binary missing after extraction."
chmod +x "$EDGE_DIR/opt/microsoft/msedge/msedge"

# --- 2. Libraries the Steam runtime doesn't ship (from Debian) -----------------
mkdir -p "$LIBS"

fetch_deb() {   # usage: fetch_deb <pool subdirectory> <package name>
  local dir=$1 pkg=$2 url listing file work
  url=$DEB_POOL/$dir/
  listing=$(curl -fsSL "$url") || die "Couldn't read the Debian package listing at $url (is the path right, and are you online?)"
  file=$(printf '%s\n' "$listing" | grep -oE "${pkg}_[^\"<> ]*_amd64\.deb" | sort -uV | tail -1) || true
  [ -n "$file" ] || die "No '$pkg' amd64 package found in $url. It may have been renamed; see README, Troubleshooting."
  info "Fetching $file"
  work=$TMP/$pkg
  mkdir -p "$work/d" "$work/x"
  curl -fsSL -o "$work/$file" "$url$file"
  bsdtar -xf "$work/$file" -C "$work/d"
  bsdtar -xf "$work"/d/data.tar.* -C "$work/x"
  cp -a "$work"/x/usr/lib/x86_64-linux-gnu/*.so* "$LIBS/"
}

fetch_deb a/at-spi2-core libatk-bridge2.0-0t64
fetch_deb a/at-spi2-core libatspi2.0-0t64
fetch_deb libx/libxres libxres1

# --- 3. Launcher script ----------------------------------------------------------
# The launcher links the Steam runtime's x86-64 libraries into ~/edge-libs itself,
# and relinks them whenever Steam updates the runtime. Re-running install.sh rewrites it.
info "Writing launcher to $LAUNCHER"
mkdir -p "$(dirname "$LAUNCHER")"
cat > "$LAUNCHER" <<'LAUNCHER_EOF'
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
LAUNCHER_EOF
chmod 755 "$LAUNCHER"

# --- 4. Application launcher entry (desktop mode) --------------------------------
ICON=$(ls "$EDGE_DIR"/opt/microsoft/msedge/product_logo_256.png 2>/dev/null \
       || ls "$EDGE_DIR"/opt/microsoft/msedge/product_logo_*.png 2>/dev/null | tail -1 || true)
[ -n "$ICON" ] || ICON=web-browser

info "Creating application entry $DESKTOP_FILE"
mkdir -p "$(dirname "$DESKTOP_FILE")"
cat > "$DESKTOP_FILE" <<DESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=Microsoft Edge (FEX)
GenericName=Web Browser
Comment=x86-64 Microsoft Edge running through FEX
Exec=$LAUNCHER %U
Icon=$ICON
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
StartupWMClass=edge-fex
DESKTOP
chmod +x "$DESKTOP_FILE"
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 >/dev/null 2>&1 || true

info "Done."
cat <<MSG

Launch Edge from the application launcher (search for "Edge"), or run:
  $LAUNCHER

The first launch links the Steam runtime's libraries and can take a while to open a window.
If nothing appears, read the log of the latest launch:
  cat $LOG

Edge runs with --no-sandbox and --disable-gpu. See the README for what that means.
MSG
