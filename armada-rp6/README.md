# 2Ship2Harkinian — native ARM64 build for Armada OS (Retroid Pocket 6)

This branch is the upstream [2Ship2Harkinian](https://github.com/2ship2harkinian/2ship2harkinian)
**5.0.1** release with one addition: this `armada-rp6/` folder. It holds a script that
builds the game natively for ARM64 on [Armada OS](https://github.com/armada-os) (Fedora 44 based,
rpm-ostree, SteamOS-style), sets up manual updates, and makes a Steam-ready launcher.

**No game code is changed.** Everything below is a build-time fix.

> This repository contains **no Nintendo assets**. You need your own legally dumped
> *Majora's Mask* ROM (`.z64`). Never commit ROMs, `mm.o2r`, or saves.

## Quick start

```bash
bash armada-rp6/2ship-arm-setup.sh                       # stable releases
bash armada-rp6/2ship-arm-setup.sh --game-dir /path/dir  # game folder somewhere else
bash armada-rp6/2ship-arm-setup.sh --develop             # track upstream develop
```

The default game folder is `/run/media/armada/JuanchiSD/Games/2ship`. Change it with `--game-dir`.

On an rpm-ostree system, the first run layers the build dependencies and asks you to
**reboot**. Run it again after the reboot to build. Building takes about 10–15 minutes on the RP6.

Then put your ROM (or a symlink to it) in the game folder and start `2ship.sh` once from
Desktop Mode. It asks to generate `mm.o2r` from the ROM; answer **Yes**.

### Add to Steam
Add a non-Steam game with:
- **Target:** `"<game-dir>/2ship.sh"`
- **Start in:** `"<game-dir>/"`

## Updating (manual only)

```bash
~/2ship/update.sh --check      # is there a new release?
~/2ship/update.sh              # asks for confirmation, then builds + installs
~/2ship/update.sh --force      # rebuild the current version (still asks)
~/2ship/update.sh --rollback   # go back to the previous build
```

Before every install and every rollback, the script copies `saves/` and
`2ship2harkinian.json` to `~/2ship/save-backups/`. It keeps the last 10 copies.

> A save that a newer version has migrated may not load after a rollback.
> The game renames it to `fileN_invalid_<time>.json`. Restore it from `~/2ship/save-backups/`.

There is deliberately no timer or cron job.

## Fixes this script needs on Armada / Fedora 44 ARM64

| Problem | Fix |
|---|---|
| `mesa-libGL-devel` conflicts with Armada's patched Mesa, so rpm-ostree can't resolve it | Use `libglvnd-devel`, which provides the real `GL/gl.h` and `libGL.so`. `mesa-libGL-devel` only ships DRI internals |
| `SDL2-devel` and `nlohmann-json-devel` were renamed | `sdl2-compat-devel` and `json-devel` |
| The first launch fails with *"Extractor assets not found … Missing 'assets/' folder"* | The build creates `build-cmake/mm/assets`, but nothing installs it. The updater now copies it to the game folder |
| The GCC 16 build had distorted audio and crashed in `AudioSfx_ChooseActiveSfx` (SIGSEGV) | Build with **Clang** and `-fsigned-char -fno-strict-aliasing`. This matches the ARM64 configuration upstream tests (macOS: Clang, signed `char`) |

## Files the script creates

| Path | What |
|---|---|
| `~/2ship/src` | upstream source checkout |
| `~/2ship/update.sh` | fetch → build → install (manual) |
| `~/2ship/update.log` | build log |
| `~/2ship/save-backups/` | automatic save/settings backups |
| `<game-dir>/2ship.sh` | launcher (`cd` into the folder and run `2s2h.elf`) |
| `<game-dir>/2s2h.elf`, `2ship.o2r`, `assets/` | the build |

Built on a Retroid Pocket 6 (Snapdragon 8 Gen 2, Armada OS, Fedora 44, Clang 22).
