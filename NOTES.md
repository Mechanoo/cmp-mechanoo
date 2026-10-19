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

## Probe report 2 (singleplayer)
- Player track `id` == Player Detector `uuid` (42 of 42 player matches). Players are identified by UUID; no position matching needed.
- The one "changed id" was a Sable ship next to the player (old probe matched by distance; fixed: players only match PLAYER tracks).
- `velocity` is in blocks per tick: a player standing still showed y = -0.0784 (vanilla gravity per tick).
- Two different SABLE ids appeared (open: two ships, or one ship that got a new id after reassembly?).
- cannon_mount getInfo while not assembled: assembled=false, computerControl=false, yaw=90, pitch=0, shaft speeds 0.

## Probe report 3 (singleplayer, one ship disassembled and reassembled at about 40 s)
- A Sable ship gets a NEW id when it is disassembled and assembled again (19b3... seen 0-37 s, then 8c98... from 41 s).
- The id stays the same while the ship exists, also after flying out of radar range and back (8c98..., gap 9 s).
- The player id stayed the same for the whole run (40/40 equal to the detector uuid).
- A third SABLE id was seen in every sample by exactly one radar and never moved (a leftover test object).
- Gaps: moving targets near the radar cluster had gaps up to 9 s; the stationary object had none. Target hold time should be at least ~10 s.
- CC:Sable on a computer ON a ship: `sublevel.getUniqueId()`, `getName()`, `setName()`, poses and velocity. A ship computer can read its own current id.
