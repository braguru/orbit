#!/bin/bash
# Installs, or updates, Orbit from the latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/manu-tech-code/orbit/HEAD/scripts/install.sh | bash
#
# It asks GitHub for the latest release, downloads its source tarball, checks the
# SHA-256 against the release's checksums.txt, unpacks it, builds a Python
# environment, and sets up the background service. Reinstalling replaces the code
# and keeps your history in data/. The Mac app is built and installed too when
# Swift is available.
#
# Options, as environment variables:
#   ORBIT_INSTALL_DIR=<folder>  install here (default ~/Applications/Orbit)
#   ORBIT_VERSION=v1.0.0        install that release instead of the latest
#   ORBIT_LAN=1                 let phones on your Wi-Fi open the dashboard
#   ORBIT_NO_SERVICE=1          don't set up the background service
#   ORBIT_NO_APP=1              don't build the Mac app
#   ORBIT_PYTHON=python3.12     use this interpreter
set -euo pipefail

REPO="manu-tech-code/orbit"
API="https://api.github.com/repos/$REPO"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Orbit is for Mac, next to a Starlink dish."

PY="${ORBIT_PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || fail "Python 3 isn't installed. Install it from python.org, then run this again."
"$PY" - <<'PY' || fail "Orbit needs Python 3.10 or newer."
import sys
sys.exit(0 if sys.version_info >= (3, 10) else 1)
PY

WORK=$(mktemp -d -t orbit-install)
trap 'rm -rf "$WORK"' EXIT

# --- The release ------------------------------------------------------------

if [ -n "${ORBIT_VERSION:-}" ]; then
  RELEASE_URL="$API/releases/tags/$ORBIT_VERSION"
else
  RELEASE_URL="$API/releases/latest"
fi

say "Finding the latest release"
RELEASE=$(curl -fsSL -H 'Accept: application/vnd.github+json' "$RELEASE_URL") \
  || fail "Couldn't reach GitHub. Check your connection, then try again."

printf '%s' "$RELEASE" > "$WORK/release.json"
"$PY" - "$WORK/release.json" > "$WORK/release.meta" <<'PY' || fail "The release doesn't list a download."
import json, sys
release = json.load(open(sys.argv[1]))
assets = {a["name"]: a["browser_download_url"] for a in release.get("assets", [])}
version = release["tag_name"].lstrip("v")
tarball = f"orbit-{version}.tar.gz"
print(version)
print(assets.get(tarball, ""))
print(assets.get("checksums.txt", ""))
PY

{ read -r VERSION; read -r TARBALL_URL; read -r CHECKSUMS_URL; } < "$WORK/release.meta"
[ -n "$VERSION" ] && [ -n "$TARBALL_URL" ] && [ -n "$CHECKSUMS_URL" ] \
  || fail "That release has no orbit-$VERSION.tar.gz (or no checksums.txt) to install."

case "$TARBALL_URL" in
  "https://github.com/$REPO/releases/download/"*) ;;
  *) fail "Unexpected download address: $TARBALL_URL" ;;
esac

say "Downloading Orbit $VERSION"
TARBALL="orbit-$VERSION.tar.gz"
curl -fL --progress-bar -o "$WORK/$TARBALL" "$TARBALL_URL" || fail "The download failed."
curl -fsSL -o "$WORK/checksums.txt" "$CHECKSUMS_URL" || fail "Couldn't download the checksums."

say "Checking the download"
( cd "$WORK" && awk -v f="$TARBALL" '$2 == f' checksums.txt | shasum -a 256 -c - >/dev/null ) \
  || fail "The download doesn't match its checksum. Try again."

tar -xzf "$WORK/$TARBALL" -C "$WORK" || fail "Couldn't unpack the download."
SRC="$WORK/orbit-$VERSION"
[ -f "$SRC/orbit/__init__.py" ] && [ -f "$SRC/requirements.txt" ] && [ -f "$SRC/scripts/service.sh" ] \
  || fail "The download doesn't look like Orbit."

# --- The installation ------------------------------------------------------

DEST="${ORBIT_INSTALL_DIR:-$HOME/Applications/Orbit}"
mkdir -p "$DEST"
[ -w "$DEST" ] || fail "Can't write to $DEST."

if [ -d "$DEST/data" ]; then
  say "Keeping your history in $DEST/data"
fi

say "Installing in $DEST"
# Replace the code; never the history (data/) or the environment (.venv).
rsync -a --delete --exclude data --exclude .venv "$SRC/" "$DEST/"

if [ ! -x "$DEST/.venv/bin/python" ]; then
  say "Making a Python environment"
  "$PY" -m venv "$DEST/.venv" || fail "Couldn't make a Python environment in $DEST/.venv."
fi
say "Installing Orbit's libraries"
"$DEST/.venv/bin/python" -m pip install -q --disable-pip-version-check \
  -r "$DEST/requirements.txt" || fail "Installing Orbit's libraries failed (see above)."

INSTALLED=$( cd "$DEST" && .venv/bin/python -c "import orbit; print(orbit.__version__)" ) \
  || fail "Orbit installed, but doesn't start. Run: $DEST/.venv/bin/python -m orbit"

# --- The service and the app ----------------------------------------------

if [ -z "${ORBIT_NO_SERVICE:-}" ]; then
  say "Setting up the background service"
  set -- install
  [ -n "${ORBIT_LAN:-}" ] && set -- "$@" --lan
  "$DEST/scripts/service.sh" "$@" || fail "The service didn't start."
fi

if [ -z "${ORBIT_NO_APP:-}" ]; then
  if command -v swift >/dev/null 2>&1; then
    say "Building the Mac app"
    ( cd "$DEST/mac" && ./build.sh --install ) || say "The Mac app didn't build; the dashboard still works."
  else
    say "Skipping the Mac app: no Swift toolchain (install Xcode, then run $DEST/mac/build.sh --install)"
  fi
fi

say "Orbit $INSTALLED is installed"
if [ -z "${ORBIT_NO_SERVICE:-}" ]; then
  echo "Open http://localhost:8787 · log: $HOME/Library/Logs/Orbit/orbit.log"
else
  echo "Start it with: $DEST/scripts/service.sh install"
fi
