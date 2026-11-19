# Streaming service replacement

## Done

- Navidrome as the backbone
- Koito for scrobbling
- ~~Beets for music importing~~

## TODO

- [x] Music downloading
  - [-] Kinda done already through discord bot + slskd
  - [x] More streamlined? How to handle singles??
-  [x] Music discovery
-  [x] Easy library management e.g. deleting music
-  [x] Sync Playlists from/with Tidal (one-way, `apps/aurral-tidal-plugin`)
- [x] **Important**: Backup strategy (`services/backup`). State only: database, scrobbles, aurral, manifest. The music files themselves are not backed up, they are re-acquired from the manifest. See `Runbook - Backup and restore` in Obsidian.


## Tools that seem interesting: 

- https://lidarr.audio/?ref=selfh.st
- https://aurral.org/?ref=selfh.st
- https://ssync.net/?ref=selfh.st#features
- https://droppedneedle.com/?ref=selfh.st

Notes: Aurral, SoulSync and Dropped Needle seem to overlap a lot and with beets and stuff. SoulSync seems very vibecoded
:(. Dropped Needle seems to be a bit more polished and has a good feature set. Aurral is the least vibey out of all of
them, integrates  Subsonic API.

