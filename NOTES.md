# In-game notes
Peripheral names and quirks found in the world. Add output of `peripherals` here.

## Radar / Player Detector (measured in game, probe report 1)
- Peripheral types: `create_radar:plane_radar` (methods getTracks, getPosition, getRange), `player_detector` (16 methods).
- With a wired modem hub the names look like `create_radar:plane_radar_0` and `player_detector_0`.
- A track has: `id`, `position{x,y,z}`, `velocity{x,y,z}`, `category`, `entityType`, `scannedTime`.
- Categories seen: `PLAYER` (entityType `entity.minecraft.player`), `SABLE` (entityType `Sable:ship`).
- The track `id` of a player is a UUID (looks like the Minecraft UUID) and stayed the same for the whole measurement. A Sable ship id is a UUID too and came back unchanged after gaps.
- A radar track position matches the player detector position of the same player (0.0 blocks apart).
- Tracks flicker: each plane radar only reports a target in some samples (average 0.3 to 0.7 tracks per sample for 1 target). Programs must keep a target alive for a few seconds after its last sighting.
- `getRange()` returned 250 on all four plane radars. That was a singleplayer test world with the mod default config; the server runs 512 (changelog v0.11.0). In singleplayer the vertical scan range is only 20 blocks.

## CC:CBC cannon_mount (from source, cc-cbc 1.1.1)
- Methods: setComputerControl(bool), isComputerControl(), setTargetAngles(yaw, pitch), setTargetYaw, setTargetPitch, getInfo(), assemble(bool), fire(bool).
- getInfo(): computerControl, assembled, yaw (0..360), pitch, targetYaw, targetPitch, yawShaftSpeed, pitchShaftSpeed, x, y, z.
- Aiming speed depends on the kinetic (shaft) speed of the mount.
- fire(true) keeps the fire signal on until fire(false).
- When the last computer detaches (computer stops, chunk unloads) the mount leaves computer control and disassembles (unless it has a redstone signal). After every boot: assemble(true) and setComputerControl(true) again.
