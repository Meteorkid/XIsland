import AppKit

struct IslandWindowSnapshot {
    let number: Int
    let ownerPID: pid_t
    let bounds: CGRect
    let alpha: CGFloat
}

enum IslandWindowOwnership {
    static func canHandleGlobalSwipe(
        isVisible: Bool,
        isCollapsed: Bool,
        windowFrame: CGRect,
        mouseLocation: CGPoint
    ) -> Bool {
        isVisible && isCollapsed && windowFrame.contains(mouseLocation)
    }

    static func frontmostWindowNumber(
        overlapping currentBounds: CGRect,
        snapshots: [IslandWindowSnapshot],
        islandPIDs: Set<pid_t>
    ) -> Int? {
        snapshots.first { snapshot in
            islandPIDs.contains(snapshot.ownerPID)
                && snapshot.alpha > 0
                && snapshot.bounds.intersects(currentBounds)
        }?.number
    }

    static func isFrontmostIslandWindow(
        _ window: NSWindow,
        bundleIdentifiers: Set<String>
    ) -> Bool {
        guard window.isVisible,
              let windowList = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]]
        else { return false }

        var islandPIDs: Set<pid_t> = [ProcessInfo.processInfo.processIdentifier]
        for bundleIdentifier in bundleIdentifiers {
            islandPIDs.formUnion(
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                    .map(\.processIdentifier)
            )
        }

        let snapshots = windowList.compactMap { info -> IslandWindowSnapshot? in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let values = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = values["X"],
                  let y = values["Y"],
                  let width = values["Width"],
                  let height = values["Height"]
            else { return nil }

            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1
            return IslandWindowSnapshot(
                number: number,
                ownerPID: ownerPID,
                bounds: CGRect(x: x, y: y, width: width, height: height),
                alpha: alpha
            )
        }

        guard let currentBounds = snapshots.first(where: { $0.number == window.windowNumber })?.bounds
        else { return false }

        return frontmostWindowNumber(
            overlapping: currentBounds,
            snapshots: snapshots,
            islandPIDs: islandPIDs
        ) == window.windowNumber
    }
}
