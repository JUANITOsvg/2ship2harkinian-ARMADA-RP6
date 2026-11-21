#!/usr/bin/env bash
# 2Ship2Harkinian - native ARM64 build + auto-updates for Armada OS (Retroid Pocket 6)
#
# Usage:  bash 2ship-arm-setup.sh                      # stable releases (recommended)
#         bash 2ship-arm-setup.sh --develop            # track the develop branch instead
#         bash 2ship-arm-setup.sh --game-dir /some/dir # install the game somewhere else
#
# What it does:
#   1. Installs git + build dependencies (dnf, or rpm-ostree on an atomic system)
#   2. Writes ~/2ship/update.sh  (clone/fetch -> build -> install)
#   3. Writes $GAME_DIR/2ship.sh (launcher to add to Steam)
#   4. Runs the first build
# No automatic updates: run ~/2ship/update.sh by hand (it asks before building).
set -euo pipefail

CHANNEL="release"
GAME_DIR="/run/media/armada/JuanchiSD/Games/2ship"   # game, ROM, saves, settings
while (($#)); do
  case "$1" in
    --develop)  CHANNEL="develop" ;;
    --game-dir) GAME_DIR="${2:?--game-dir needs a path}"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

BASE="$HOME/2ship"                                    # source + build (internal storage)

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mxx  %s\033[0m\n' "$*"; exit 1; }

[[ "$(uname -m)" == "aarch64" ]] || warn "This is not an aarch64 system ($(uname -m)). Continuing anyway."
[[ $EUID -ne 0 ]] || die "Run this as your normal user, not with sudo. It asks for your password when needed."

# ---------------------------------------------------------------- 1. dependencies
PKGS=(git gcc gcc-c++ clang cmake ninja-build lsb_release pkgconf-pkg-config
      sdl2-compat-devel SDL2_net-devel libpng-devel libzip-devel libzip-tools
      json-devel tinyxml2-devel spdlog-devel
      opusfile-devel libvorbis-devel libogg-devel
      glew-devel libglvnd-devel zenity)

say "Checking build dependencies"
MISSING=()
for p in "${PKGS[@]}"; do rpm -q --whatprovides "$p" &>/dev/null || MISSING+=("$p"); done

if ((${#MISSING[@]})); then
  echo "Missing: ${MISSING[*]}"
  if [[ -e /run/ostree-booted ]]; then
    say "Atomic (rpm-ostree) system detected: layering packages"
    sudo rpm-ostree install --idempotent --allow-inactive "${MISSING[@]}"
    warn "Packages are layered but only active after a reboot."
    warn "Reboot into Desktop Mode, then run this script again."
    exit 0
  elif command -v dnf &>/dev/null; then
    sudo dnf install -y --skip-unavailable "${MISSING[@]}" \
      || sudo dnf install -y "${MISSING[@]}"
  else
    die "Neither dnf nor rpm-ostree found. Install these manually: ${MISSING[*]}"
  fi
else
  echo "All dependencies present."
fi

# The game folder's parent (e.g. the microSD) must be mounted
SD_ROOT="$(dirname "$(dirname "$GAME_DIR")")"
[[ -d "$SD_ROOT" ]] || die "$SD_ROOT is not mounted. Insert/mount the card and try again."
mkdir -p "$BASE" "$GAME_DIR"
touch "$GAME_DIR/.write-test" 2>/dev/null && rm -f "$GAME_DIR/.write-test" \
  || die "Can't write to $GAME_DIR. Check the card isn't read-only."
echo "$CHANNEL" > "$BASE/channel"
# Install the local fixes shipped next to this script (applied by update.sh on every build)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if compgen -G "$SCRIPT_DIR/patches/*.patch" >/dev/null; then
  mkdir -p "$BASE/patches" && cp -f "$SCRIPT_DIR"/patches/*.patch "$BASE/patches/"
  echo "Installed patches: $(cd "$SCRIPT_DIR/patches" && ls *.patch | tr '\n' ' ')"
fi
echo "$GAME_DIR" > "$BASE/gamedir"
FSTYPE="$(findmnt -no FSTYPE -T "$GAME_DIR" 2>/dev/null || echo unknown)"
echo "Game folder: $GAME_DIR (filesystem: $FSTYPE)"

# ---------------------------------------------------------------- 2. update.sh
say "Writing $BASE/update.sh"
cat > "$BASE/update.sh" <<'UPDATE'
#!/usr/bin/env bash
# Fetch, build and install 2Ship2Harkinian for ARM64.
#   update.sh            if there is a new version, ask, then build + install
#   update.sh --check    only report whether a new version is available
#   update.sh --force    rebuild even if up to date (still asks)
#   update.sh --yes      don't ask (combine with --force if wanted)
#   update.sh --rollback restore the previous build
# Saves + settings are backed up to ~/2ship/save-backups before every install/rollback.
set -euo pipefail

REPO="https://github.com/2ship2harkinian/2ship2harkinian.git"
BASE="$HOME/2ship"
SRC="$BASE/src"
BUILD="$SRC/build-cmake"
GAME_DIR="$(cat "$BASE/gamedir" 2>/dev/null || echo "$HOME/Games/2ship")"
CHANNEL="$(cat "$BASE/channel" 2>/dev/null || echo release)"
JOBS="${JOBS:-4}"           # 4 of the RP6's 8 cores keeps RAM use sane
LOCK="$BASE/.lock"
FORCE=0; ASSUME_YES=0; CHECK_ONLY=0; ROLLBACK=0

log()    { echo "[$(date '+%F %T')] $*"; }
notify() { command -v notify-send &>/dev/null && notify-send -a "2Ship updater" "$1" "${2:-}" || true; }

# Copy saves + settings to internal storage; keep the 10 newest backups
backup_saves() {
  local dest="$BASE/save-backups/$(date +%F_%H%M%S)_$(cat "$GAME_DIR/.version" 2>/dev/null || echo none)"
  mkdir -p "$dest"
  [[ -d "$GAME_DIR/saves" ]] && cp -a "$GAME_DIR/saves" "$dest/"
  [[ -f "$GAME_DIR/2ship2harkinian.json" ]] && cp -a "$GAME_DIR/2ship2harkinian.json" "$dest/"
  ls -1dt "$BASE/save-backups"/*/ 2>/dev/null | tail -n +11 | xargs -r rm -rf
  log "Saves/settings backed up to $dest"
}

exec 9>"$LOCK"; flock -n 9 || { log "Another update is running."; exit 0; }

for arg in "$@"; do
  case "$arg" in
    --force)    FORCE=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --check)    CHECK_ONLY=1 ;;
    --rollback) ROLLBACK=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if ((ROLLBACK)); then
    [[ -f "$GAME_DIR/2s2h.elf.prev" ]] || { log "No previous build to roll back to."; exit 1; }
    pgrep -x 2s2h.elf &>/dev/null && { log "Close 2Ship before rolling back."; exit 1; }
    backup_saves
    mv -f "$GAME_DIR/2s2h.elf.prev" "$GAME_DIR/2s2h.elf"
    [[ -f "$GAME_DIR/2ship.o2r.prev" ]] && mv -f "$GAME_DIR/2ship.o2r.prev" "$GAME_DIR/2ship.o2r"
    if [[ -d "$GAME_DIR/assets.prev" ]]; then rm -rf "$GAME_DIR/assets"; mv -f "$GAME_DIR/assets.prev" "$GAME_DIR/assets"; fi
    [[ -f "$GAME_DIR/.version.prev" ]] && mv -f "$GAME_DIR/.version.prev" "$GAME_DIR/.version"
    log "Rolled back to $(cat "$GAME_DIR/.version" 2>/dev/null || echo 'previous build')."
    exit 0
fi

# The game lives on the microSD: skip quietly if the card isn't there
[[ -d "$GAME_DIR" ]] || { log "$GAME_DIR not found (microSD not mounted?); skipping."; exit 0; }

# Don't compile while a game is running
if pgrep -x 2s2h.elf &>/dev/null; then log "2Ship is running; skipping."; exit 0; fi

# Clone or fetch
if [[ ! -d "$SRC/.git" ]]; then
  log "Cloning $REPO"
  git clone --filter=blob:none "$REPO" "$SRC"
fi
cd "$SRC"
git fetch --tags --force --prune origin

# Pick the target
if [[ "$CHANNEL" == "develop" ]]; then
  TARGET="origin/develop"
  WANT="develop-$(git rev-parse --short "$TARGET")"
else
  # newest tag that looks like a version number (e.g. 5.0.1)
  TARGET="$(git tag -l | grep -E '^v?[0-9]+(\.[0-9]+)+$' | sort -V | tail -n1)"
  [[ -n "$TARGET" ]] || { log "No release tags found."; exit 1; }
  WANT="$TARGET"
fi
HAVE="$(cat "$GAME_DIR/.version" 2>/dev/null || echo none)"
log "Channel: $CHANNEL | installed: $HAVE | latest: $WANT"

if [[ "$WANT" == "$HAVE" && $FORCE -eq 0 ]]; then log "Up to date."; exit 0; fi
if ((CHECK_ONLY)); then log "Update available: $HAVE -> $WANT. Run ~/2ship/update.sh to install."; exit 0; fi

# Never build without confirmation
if ((ASSUME_YES == 0)); then
  if [[ -t 0 ]]; then
    read -r -p "Build and install 2Ship $WANT (installed: $HAVE)? Takes ~10-15 min. [y/N] " ans
    [[ "$ans" =~ ^[yYsS] ]] || { log "Cancelled; nothing changed."; exit 0; }
  else
    log "Not running interactively and --yes not given; nothing changed."; exit 0
  fi
fi

notify "Building 2Ship $WANT" "This takes a while; don't launch the game until it finishes."
log "Checking out $TARGET"
git checkout --force --detach "$TARGET"
git submodule sync --recursive
git submodule update --init --recursive --force

# Local fixes on top of upstream (e.g. PR #1745: 64-bit audio crashes / broken SFX).
# The checkout above resets the tree, so each patch is applied fresh on every build.
for p in "$BASE"/patches/*.patch; do
  [[ -e "$p" ]] || continue
  if git apply --check "$p" 2>/dev/null; then
    git apply "$p"; log "Applied patch: $(basename "$p")"
  elif git apply --reverse --check "$p" 2>/dev/null; then
    log "Patch already included upstream, skipping: $(basename "$p")"
  else
    log "PATCH DOES NOT APPLY: $(basename "$p"). Upstream changed; check if it was merged or needs updating."
    log "Nothing was built; the installed version was left untouched."
    notify "2Ship update stopped" "A local patch no longer applies. See ~/2ship/update.log."
    exit 1
  fi
done

# A new release can change CMake options; start the cache clean on version change
[[ "$WANT" != "$HAVE" ]] && rm -rf "$BUILD"

log "Configuring"
# Clang + signed char like upstream's macOS ARM64 build (not the crash fix itself; see patches/)
# PIE matches upstream's Linux CI layout (Ubuntu builds PIE by default; Fedora's default here was non-PIE)
CFLAGS_EXTRA="-fsigned-char -fno-strict-aliasing -fPIE"
cmake -H. -B"$BUILD" -GNinja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_C_FLAGS="$CFLAGS_EXTRA" -DCMAKE_CXX_FLAGS="$CFLAGS_EXTRA" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_EXE_LINKER_FLAGS="-pie"

log "Generating 2ship.o2r"
nice -n 10 cmake --build "$BUILD" --target Generate2ShipOtr -j"$JOBS"

log "Compiling (-j$JOBS)"
if ! nice -n 10 cmake --build "$BUILD" -j"$JOBS"; then
  notify "2Ship build failed" "See ~/2ship/update.log. Your installed version still works."
  log "BUILD FAILED. The installed version was left untouched."
  exit 1
fi

# Locate outputs (the binary lives in build-cmake/mm on current versions)
ELF="$(find "$BUILD" -maxdepth 3 -type f -name '2s2h.elf' | head -n1)"
O2R="$(find "$BUILD" "$SRC" -maxdepth 3 -type f -name '2ship.o2r' | head -n1)"
[[ -n "$ELF" ]] || { log "Build finished but 2s2h.elf was not found."; exit 1; }
[[ -n "$O2R" ]] || { log "Build finished but 2ship.o2r was not found."; exit 1; }

log "Installing to $GAME_DIR"
backup_saves
mkdir -p "$GAME_DIR"
[[ -f "$GAME_DIR/2s2h.elf" ]] && cp -f "$GAME_DIR/2s2h.elf" "$GAME_DIR/2s2h.elf.prev"
[[ -f "$GAME_DIR/2ship.o2r" ]] && cp -f "$GAME_DIR/2ship.o2r" "$GAME_DIR/2ship.o2r.prev"
[[ -f "$GAME_DIR/.version" ]] && cp -f "$GAME_DIR/.version" "$GAME_DIR/.version.prev"
# plain cp + chmod (|| true) so exFAT/FAT cards, which ignore permissions, also work
cp -f "$ELF" "$GAME_DIR/2s2h.elf.new" && mv -f "$GAME_DIR/2s2h.elf.new" "$GAME_DIR/2s2h.elf"
chmod 755 "$GAME_DIR/2s2h.elf" 2>/dev/null || true
# Bundle the libraries whose file names change between versions, so an OS update can't
# break the game (the launcher puts $GAME_DIR/lib first). Old copies are kept for --rollback.
bundle_libs() {
  mkdir -p "$GAME_DIR/lib"
  local soname path
  for soname in $(readelf -d "$GAME_DIR/2s2h.elf" | awk '/NEEDED/{gsub(/[][]/,"",$5); print $5}' \
                  | grep -E '^lib(spdlog|fmt|tinyxml2)\.so'); do
    path="$(ldd "$GAME_DIR/2s2h.elf" | awk -v l="$soname" '$1==l{print $3}')"
    [[ -n "$path" && -f "$path" ]] && cp -fL "$path" "$GAME_DIR/lib/$soname" && log "Bundled $soname"
  done
}
bundle_libs
cp -f "$O2R" "$GAME_DIR/2ship.o2r"
# extractor XMLs/configs needed on first launch to build mm.o2r from the ROM
ASSETS="$(dirname "$ELF")/assets"
if [[ -d "$ASSETS" ]]; then
  rm -rf "$GAME_DIR/assets.prev"
  [[ -d "$GAME_DIR/assets" ]] && mv -f "$GAME_DIR/assets" "$GAME_DIR/assets.prev"
  cp -r "$ASSETS" "$GAME_DIR/assets"
fi
DB="$(dirname "$ELF")/gamecontrollerdb.txt"
[[ -f "$DB" ]] && cp -f "$DB" "$GAME_DIR/gamecontrollerdb.txt"
sync
echo "$WANT" > "$GAME_DIR/.version"

log "Done: 2Ship $WANT installed."
notify "2Ship $WANT installed" "Ready to play."
UPDATE
chmod +x "$BASE/update.sh"

# ---------------------------------------------------------------- 3. launcher
say "Writing launcher $GAME_DIR/2ship.sh"
cat > "$GAME_DIR/2ship.sh" <<'LAUNCH'
#!/usr/bin/env bash
# Steam launcher for 2Ship2Harkinian. Saves and settings live in this folder.
cd "$(dirname "$(readlink -f "$0")")"
# Use the bundled copies of version-sensitive libraries first (see update.sh: bundle_libs)
export LD_LIBRARY_PATH="$PWD/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# 2s2h 5.0.1 can hang while shutting down after a TERM/INT signal (e.g. Steam's "Exit game").
# Forward the signal, give it 3 s to exit cleanly, then force it. Saves are written when made,
# so nothing is lost by forcing the exit.
./2s2h.elf "$@" &
GAME=$!
stop_game() {
  kill -TERM "$GAME" 2>/dev/null
  for _ in 1 2 3 4 5 6; do kill -0 "$GAME" 2>/dev/null || exit 0; sleep 0.5; done
  kill -KILL "$GAME" 2>/dev/null
  exit 0
}
trap stop_game TERM INT HUP
wait "$GAME"
LAUNCH
chmod +x "$GAME_DIR/2ship.sh" 2>/dev/null || true

# ---------------------------------------------------------------- 4. first build
say "First build (channel: $CHANNEL). Keep the charger plugged in; this takes 10-40 min."
"$BASE/update.sh" --force --yes 2>&1 | tee -a "$BASE/update.log"

say "All set!"
cat <<EOF
  Next:
   1. Copy your Majora's Mask ROM (.z64) into: $GAME_DIR
   2. Run once from Desktop Mode:  $GAME_DIR/2ship.sh
      (it asks to generate mm.o2r from your ROM; answer Yes)
   3. Steam > Games > Add a Non-Steam Game > browse to $GAME_DIR/2ship.sh

  Check for update: ~/2ship/update.sh --check   Update: ~/2ship/update.sh (asks first)
  Roll back:        ~/2ship/update.sh --rollback  Log: ~/2ship/update.log
  Save backups:     ~/2ship/save-backups/
EOF
