# cmp-mechanoo

ComputerCraft (CC:Tweaked) programs for the CMP Minecraft server (1.21.1, NeoForge, Create + addons).
By Mechanoo, team Void.

> Work in progress. Stage 1 (installer, Discord test, probe) is available.

## Install (in game)
On a computer with HTTP enabled:

    wget run https://raw.githubusercontent.com/Mechanoo/cmp-mechanoo/main/install.lua

This installs everything to `/cmp` and adds the `cmp` command. Update later with `cmp update`.
GitHub caches raw files for a few minutes, so a fresh push can take up to ~5 minutes to arrive.

## Commands
- `cmp list` shows installed apps
- `cmp <app> [args]` runs an app
- `cmp update` updates everything
- `cmp version` shows the installed version

## Apps
| App | What it does |
|---|---|
| `discord-test` | Asks for your Discord webhook URLs (stored only on that computer in `/cmp-data/discord.json`) and sends a test message |
| `probe` | Measures what Plane Radars and the Player Detector return (id stability, positions). `cmp probe 60 --discord` sends the report to your log channel |

## Layout
- `bin/` the `cmp` command
- `lib/` shared libraries (`store`, `discord`, `updater`, `probe_core`)
- `apps/<name>/main.lua` one folder per program
- `tests/` logic tests, run in CraftOS-PC with mocked peripherals
- `scripts/make_manifest.py` regenerates `manifest.json` (run it before every push that changes a Lua file)
- `install.lua` the installer

Webhook URLs and other secrets are never stored in this repository.
