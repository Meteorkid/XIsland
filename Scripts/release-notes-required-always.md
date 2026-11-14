<!-- Every GitHub release MUST include this block in the release notes body. -->

## English summary

One or two sentences in English describing what this release changes. GitHub's audience is mostly English-speaking and release notes are indexed by search engines, so a body written only in Chinese reaches neither group.

## Integration changes

List every AI client or agent integration that was **added, removed or re-classified** in this release. Use the same wording as the README table — `contract tests passed` and `verified on a real client` are different claims and must not be merged into "supported".

Write `None` when nothing changed. Do not drop the section: an explicit "none" is information, a missing section is an omission.

This section is the only per-release record of coverage changes, and it is what people search for when they ask whether a specific agent is supported yet.

## macOS Gatekeeper

If macOS blocks the app after installing from the DMG, run:

```bash
xattr -cr /Applications/X\ Island.app
```

Alternatively: **System Settings → Privacy & Security** → scroll to the message about X Island → **Open Anyway**.
