# LX Sync playlist migration and recovery

LX Sync now includes every local library playlist, including QQ Music and
NetEase account copies. Provider source and playlist IDs remain synchronized;
`providerSyncEnabled` remains a device-local refresh permission and is never
sent in the LX wire model.

Before assigning sync IDs, the first playlist preparation stores the previous
policy's excluded QQ/NetEase rows in the immutable UserDefaults key
`moumusic.localPlaylists.v1.lxSyncLegacyAccountCopiesBackup.v1`. During the
first `merge_local_remote` handshake's `list_sync_set_list_data` only, the
client supplements the server snapshot with currently existing local QQ/NetEase
rows missing by stable ID and provider identity. It reads current rows (so
provider refreshes/local edits after backup are retained), never restores rows
from the backup. The IDs introduced are recorded in
`imusic.lxSync.legacyAccountPlaylistsIntroducedIDs.v1`; an interrupted publish
is recorded by `imusic.lxSync.legacyAccountPlaylistsMigrationPending.v1`.
Only after the server's `finished` message does the client publish the current
local snapshot on that same socket/generation and mark
`imusic.lxSync.legacyAccountPlaylistsMerged.v1` complete. Pending retries use
only still-existing introduced rows/current library state. Subsequent remote
actions, including removals and overwrites, never receive migration additions;
after completion, server removals continue to remove playlists on this device.

The backup is retained after completion for rollback/recovery. To recover a
pre-migration account copy, decode the backup value as `[LocalPlaylist]` (the
dates use ISO-8601 encoding) and restore the desired row into the existing
`moumusic.localPlaylists.v1` collection through the app's normal playlist
storage path. Do not clear the marker to resolve ordinary sync deletions; that
would reintroduce every backed-up playlist. Clearing the marker is only an
intentional migration retry after verifying/restoring local data. No existing
playlist storage key, schema, or identity format changes in this migration.
