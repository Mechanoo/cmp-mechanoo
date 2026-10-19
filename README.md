# cmp-mechanoo

ComputerCraft (CC:Tweaked) programs for the CMP Minecraft server (1.21.1, NeoForge, Create + addons).
By Mechanoo, team Void.

> Work in progress. Stage 1 (installer, Discord test, probe) is available.

## Install (in game)
On a computer with HTTP enabled:

    wget run https://raw.githubusercontent.com/Mechanoo/cmp-mechanoo/main/install.lua

This installs everything to `/void` and adds the `void` command. Update later with `void update`.
GitHub caches raw files for a few minutes, so a fresh push can take up to ~5 minutes to arrive.

Upgrading from the first versions (`cmp` command, `/cmp`): run the install command above once. It moves your data from `/cmp-data` to `/void-data` and removes the old `/cmp` install.

## Commands
- `void list` shows installed apps
- `void <app> [args]` runs an app
- `void update` updates everything
- `void version` shows the installed version

## Apps
| App | What it does |
|---|---|
| `discord-test` | Asks for your Discord webhook URLs (stored only on that computer in `/void-data/discord.json`) and sends a test message |
| `radar` | Base watch: merges plane radars and the player detector, friend/foe lists (trusted, visitor, hostile, unknown), ship lists with automatic takeover after reassembly, no-go zone (10x10 chunks, 10 s countdown), chat warning, alarm, Discord alerts. Cannons are not connected yet. `void radar autostart on` starts it on boot |
| `music` | YouTube music player on the computer's speakers (search, queue, loop, volume; Q quits). Based on [terreng/computercraft-streaming-music](https://github.com/terreng/computercraft-streaming-music) (MIT), it uses that project's web service for search and download. Shares the speakers with the radar: the siren takes over, the music pauses and resumes afterwards. `void music tab` opens it in its own tab, `void music autostart on` on boot |
| `probe` | Measures what Plane Radars and the Player Detector return (id stability, positions). `void probe 60 --discord` sends the report to your log channel |

## Layout
- `bin/` the `void` command
- `lib/` shared libraries (`store`, `audiolock`, `discord`, `updater`, `probe_core`, `lists`, `tracker`, `policy`, `zone`, `commands`, `alerts`, `duration`, `vec`)
- `apps/<name>/main.lua` one folder per program
- `tests/` logic tests, run in CraftOS-PC with mocked peripherals
- `scripts/make_manifest.py` regenerates `manifest.json` (run it before every push that changes a Lua file)
- `install.lua` the installer

Webhook URLs and other secrets are never stored in this repository.
