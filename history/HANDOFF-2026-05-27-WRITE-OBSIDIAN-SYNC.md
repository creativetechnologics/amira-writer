# Handoff: Write → Obsidian Sync (2026-05-27)

## Goal
When the Amira app opens a project, it watches the project's `Write/` directory and keeps it synced with the corresponding `Write/` directory in the user's Obsidian iCloud vault at:
```
~/Library/Mobile Documents/iCloud~md~obsidian/Documents/<project-name>/Write/
```
This lets the user swap between the Amira app and Obsidian to edit markdown card/scene files, with the newer file timestamp winning on conflicts.

## Files Changed

### New: `Sources/WriteUI/Services/WriteObsidianSyncService.swift`
A `@MainActor` service class that:
- **Init**: Takes a `projectURL`, derives the Obsidian vault path from it (replacing the project name into the iCloud path), and checks both directories exist. Returns `nil` (failable init) if either path is missing.
- **Periodic sync**: Every 5 seconds while active, enumerates all files recursively (non-hidden, non-package) in both directories and copies newer files to the other side. Handles new files in either direction. Uses file modification dates for conflict resolution — newer timestamp wins.
- **On-demand sync**: `syncNow()` triggers an immediate full scan.
- **Lifecycle**: `start()`/`stop()` control the polling timer. Should be tied to the Write workspace's background work lifecycle.

### Modified: `Sources/WriteUI/WriteWorkspace.swift`
- Added `@ObservationIgnored private var obsidianSyncService: WriteObsidianSyncService?`
- `resumeBackgroundWork()` now also ensures the sync service is created (lazy, on first resume) and starts it
- `suspendBackgroundWork()` stops the sync service
- `ensureObsidianSyncService()` wires up `store.onDidSave` to call `syncNow()` after each app save

### Modified: `Sources/WriteUI/ScriptStore.swift`
- Added `var onDidSave: (() -> Void)?` property (line 927)
- Called at line 1026 after a successful save completes

## What's NOT Covered
- Only works when the app is open and on the Write tab (respects the existing `suspendBackgroundWork`/`resumeBackgroundWork` lifecycle)
- Does NOT handle deletion propagation (files removed from one side are not removed from the other)
- Does NOT handle binary file conflicts in any special way (same timestamp-copy logic applies)
- The Obsidian vault path is hard-coded to the iCloud~md~obsidian scheme. If the user changes their Obsidian vault location, the path derivation will fail silently and the service won't start.
- `.stfolder` marker files are ignored by the `skipsHiddenFiles` flag in enumeration

## Verification
- Build: `rtk swift build -c release --product Opera` — compiles clean (0 errors)
- Initial file seed: both directories already populated with matching content via `cp -R`

## Next Steps / Re-apply If Lost
1. Re-create `Sources/WriteUI/Services/WriteObsidianSyncService.swift` from the description above
2. Add `@ObservationIgnored` property + lifecycle hooks to `WriteWorkspaceController`
3. Add `onDidSave` callback property to `ScriptStore` and fire it after successful save
4. Verify with `rtk swift build -c release --product Opera`
5. Deploy: `Scripts/build-app.sh`
