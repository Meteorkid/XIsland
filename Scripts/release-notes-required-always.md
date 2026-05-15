<!-- Every GitHub release MUST include this block in the release notes body. -->

## macOS Gatekeeper

If macOS blocks the app after installing from the DMG, run:

```bash
xattr -cr /Applications/X\ Island.app
```

Alternatively: **System Settings → Privacy & Security** → scroll to the message about X Island → **Open Anyway**.
