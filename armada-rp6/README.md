# 2Ship2Harkinian — native ARM64 build for Armada OS (Retroid Pocket 6)

This branch is the upstream [2Ship2Harkinian](https://github.com/2ship2harkinian/2ship2harkinian)
**5.0.1** release with one addition: this `armada-rp6/` folder. It holds a script that
builds the game natively for ARM64 on [Armada OS](https://github.com/armada-os) (Fedora 44 based,
rpm-ostree, SteamOS-style), sets up manual updates, and makes a Steam-ready launcher.

The game code is changed in exactly one place: [`patches/0001-pr1745-64bit-audio-fixes.patch`](patches/),
a 5.0.1 backport of the open upstream
[PR #1745](https://github.com/2ship2harkinian/2ship2harkinian/pull/1745) by **billsix**.
Without it the game has broken audio and crashes on this platform (see below). `update.sh`
applies it on every build. It skips the patch if upstream has merged it, and it stops
without building if the patch no longer applies.

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
| Distorted or silent sound effects, then a SIGSEGV in `AudioSfx_ChooseActiveSfx` or `AudioSfx_SetProperties` after about 40 s (title demo, South Clock Town) | **Real cause:** Fedora's toolchain built a **non-PIE** executable, and 5.0.1 has 64-bit audio bugs. A port guard (`parentLayer < 0x7FFFFFFF`) skips every note update when the audio heap sits below 2 GB. An uninitialised `AdpcmLoop.sampleEnd` overflows the software-RSP buffer. `osRecvMesg` writes 8 bytes into 4-byte locals. **Fix:** the PR #1745 patch, plus building as **PIE** like upstream's Ubuntu CI. Switching to Clang alone did *not* fix it |
| After a TERM signal (Steam's "Exit game"), 5.0.1 can hang while shutting down | The launcher passes the signal on and force-quits after 3 s. Saves are written when made, so nothing is lost |
| An Armada/Fedora update can ship a newer spdlog, fmt or tinyxml2. Their sonames change (`libspdlog.so.1.15`, `libfmt.so.11`, `libtinyxml2.so.11`), so the game would no longer start | The updater copies these three libraries into `<game-dir>/lib/` on every install, and the launcher puts that folder first in `LD_LIBRARY_PATH`. They only need `libstdc++`. Everything else (glibc, GL, SDL2, zlib, …) stays the system's |

ARM64 Linux in general is fine upstream. The open [PR #1970](https://github.com/2ship2harkinian/2ship2harkinian/pull/1970)
adds an aarch64 Linux CI build (PIE, Ubuntu), tested on Switch Linux.

## Recommended in-game settings (Game Mode, plug-and-play)

Open the menu with **Select/Back** once *Settings → Controller navigation* is on. Before that, use F1 in Desktop Mode.

| Setting | Value | Why |
|---|---|---|
| Fullscreen | on | Without it, Game Mode scales a non-16:9 window, so the picture is stretched or has bars |
| Interpolation FPS | 60 | Smooth 60 fps (game logic stays at its authentic 20 Hz). Uses about 35 % of one core and the GPU stays at its lowest clock, so the fan stays at minimum in *Balanced* |
| Disable Black Bar Letterboxes | on | Edge-to-edge 16:9 in cutscenes |
| Widescreen Actor Culling | on | No pop-in at the 16:9 edges |
| Autosave | on, every 1 min | There is no save-on-exit, so this keeps losses to about a minute |
| Persistent Owl Saves | on | Loading doesn't delete the autosave |
| Pause Menu Save | on | B in the pause menu saves |

Controller mapping is created automatically. Steam Input presents the RP6 as an Xbox pad.

## Files the script creates

| Path | What |
|---|---|
| `~/2ship/src` | upstream source checkout |
| `~/2ship/update.sh` | fetch → build → install (manual) |
| `~/2ship/update.log` | build log |
| `~/2ship/save-backups/` | automatic save/settings backups |
| `~/2ship/patches/` | local source patches (copied from `armada-rp6/patches/`) |
| `<game-dir>/2ship.sh` | launcher (runs `2s2h.elf` from its folder; force-quits a hung exit) |
| `<game-dir>/2s2h.elf`, `2ship.o2r`, `assets/` | the build |
| `<game-dir>/lib/` | bundled spdlog/fmt/tinyxml2, so OS updates can't break the game |

Built and tested on a Retroid Pocket 6 (Snapdragon 8 Gen 2, Armada OS, Fedora 44, Clang 22, PIE + PR #1745).
