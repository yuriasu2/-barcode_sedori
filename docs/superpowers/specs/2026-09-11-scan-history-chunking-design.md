# Scan History Chunking Design

## Goal

Store new scan history in files of at most 100 records so that adding a scan rewrites at most one small file instead of rewriting the complete history. The history screen loads the newest page first and loads older pages as the user scrolls. Search can find records in every chunk.

## Compatibility decision

The existing `Documents/scan_history.json` is legacy data. The new implementation will never read, decode, migrate, overwrite, or delete it. It remains on the device as an unused file. The first launch after the update starts with an empty new history unless the new chunk directory already contains data.

The existing graph archive is isolated in the same way. New graph data is stored under `Library/Application Support/graphs-v2`; the old `graphs` directory is left untouched and is not read by the updated app.

## File layout

```text
Documents/
  scan_history.json             # legacy, untouched and ignored
  scan_history/
    chunk-00000001.json         # JSON array, newest record first
    chunk-00000002.json

Library/Application Support/
  graphs/                        # legacy, untouched and ignored
  graphs-v2/                     # graphs for the new history format
```

Chunk numbers are monotonically increasing. A higher number is newer. Existing chunk numbers are never renumbered when a record is deleted. This makes adding a record an append of a new chunk or an atomic rewrite of the current newest chunk.

## Persistence behavior

- Each chunk contains no more than 100 `ScanHistoryItem` values.
- New records are inserted at the beginning of the newest chunk. A full newest chunk causes a new chunk to be created.
- Deleting records does not rebalance chunks. Empty chunks are removed; sparse chunks remain sparse.
- The existing 5,000 record limit remains. When the limit is exceeded, the oldest records are removed from the oldest chunk(s).
- Chunk writes use an atomic temporary-file replacement.
- The storage layer scans at most about 50 chunk files for the current 5,000 record limit. It does not maintain a separate index or manifest.

## Store and UI behavior

`ScanHistoryStore` remains the observable UI-facing facade. Its `items` property contains only records currently loaded for the history screen. It exposes page state (`hasMore`, `isLoadingMore`, and `totalCount`) and keeps the existing add/update/remove/clear call sites working.

- Initial load reads the newest page, up to 100 records.
- Reaching the last loaded row loads the next older chunk and appends it to `items`.
- Clearing the search field resets the view to the newest page.
- Search runs across all new chunks in a background task and preserves the current title/code/date matching rules. It does not read the legacy file.
- While search is running, the view shows a loading state and does not report “not found” prematurely.
- Selection, deletion, detail navigation, and the iOS 16 `ScrollView` + `LazyVStack` workaround remain available.

The debug history generator writes through the new chunk format and reports the store's total count, rather than the number of records in the currently loaded page.

## Deletion behavior

The app's user-initiated history deletion clears the new `scan_history` directory and the new `graphs-v2` directory. It does not touch the legacy `scan_history.json` or `graphs` directory because those files are deliberately outside the new format and are never used after the update.

## Error handling

Unreadable or malformed new chunk files are skipped so one damaged page does not prevent the app from opening. A failed atomic write leaves the previous chunk intact. The app continues to display whatever valid chunks can be read.

## Validation

Standalone Foundation tests cover chunk creation, page order, legacy-file ignoring, search across old chunks, update/delete in unloaded chunks, sparse chunks, the 5,000 record cap, and clear behavior. The iOS target is then regenerated with XcodeGen and built for an iOS 16 simulator without launching it.
