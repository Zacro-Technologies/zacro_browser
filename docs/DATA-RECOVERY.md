# Saved data and recovery

Zacro saves regular-profile metadata in `browser-state.json` inside its application data directory. Normal saves write a temporary file, flush it, and atomically replace the primary file. The previous valid save is kept in `browser-state.json.bak`. Private profiles are excluded from both files.

If the primary file cannot be read, Zacro preserves it as `browser-state.json.damaged-<timestamp>` and attempts recovery from the backup. These recovery files are local; they are not uploaded or included in portable exports.

## Explicit deletion

Clearing history, site permissions, or the tab archive, and deleting a profile, immediately updates both the primary file and the recovery backup with the resulting current state. A later recovery therefore cannot restore records removed by that action. Current records belonging to other profiles are preserved.

The same operation removes files matching Zacro's exact reserved damaged-recovery filename pattern in that directory. Damaged files cannot be reliably filtered by profile, so those older recovery copies are discarded entirely. Unrelated files, folders, and user-created exports are not removed. An error is reported if updating or removing the recovery data fails; the next save retries the cleanup.

“Clear browsing data” additionally clears the selected Chromium session's cookies, site storage, cache, and authentication cache. Saved tabs and bookmarks remain. Ordinary metadata recovery files do not contain Chromium cookies or AI API keys.

These operations remove application-managed records. They do not securely erase disk blocks, operating-system backups, filesystem snapshots, or exports the user saved elsewhere.
