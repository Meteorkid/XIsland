import AppKit

enum IslandHandoffVisibility {
    struct RunningApplication {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let applicationURL: URL?
    }

    @MainActor
    static func isPeerVisible(
        bundleIdentifier: String,
        applicationURL: URL?,
        sourcePID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        guard let peerWindowLevel = windowLevel(for: bundleIdentifier) else { return false }
        let peerPIDs = runningPeerPIDs(bundleIdentifier: bundleIdentifier, applicationURL: applicationURL)
        guard !peerPIDs.isEmpty, let windows = onScreenWindows() else { return false }
        return isPeerVisible(
            windowList: windows, peerPIDs: peerPIDs, sourcePID: sourcePID, peerWindowLevel: peerWindowLevel
        )
    }

    @MainActor
    static func isPeerFrontmost(
        bundleIdentifier: String,
        applicationURL: URL?,
        sourcePID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        guard let peerWindowLevel = windowLevel(for: bundleIdentifier),
              let sourceWindowLevel = windowLevel(
                  for: NSRunningApplication(processIdentifier: sourcePID)?.bundleIdentifier
              ) else { return false }
        let peerPIDs = runningPeerPIDs(bundleIdentifier: bundleIdentifier, applicationURL: applicationURL)
        guard !peerPIDs.isEmpty, let windows = onScreenWindows() else { return false }
        return isPeerFrontmost(
            windowList: windows, peerPIDs: peerPIDs, sourcePID: sourcePID,
            peerWindowLevel: peerWindowLevel, sourceWindowLevel: sourceWindowLevel
        )
    }

    static func windowLevel(for bundleIdentifier: String?) -> Int? {
        switch bundleIdentifier {
        case "dev.xisland.app": return NSWindow.Level.statusBar.rawValue + 1
        case "com.meteorkid.xnook": return NSWindow.Level.statusBar.rawValue + 2
        default: return nil
        }
    }

    static func peerProcessIdentifiers(
        bundleIdentifier: String,
        applicationURL: URL?,
        applications: [RunningApplication]
    ) -> Set<pid_t> {
        Set(applications.compactMap { application in
            guard application.processIdentifier > 0,
                  application.bundleIdentifier == bundleIdentifier else { return nil }
            if let applicationURL {
                guard applicationURL.isFileURL,
                      let candidateURL = application.applicationURL,
                      candidateURL.isFileURL,
                      candidateURL.standardizedFileURL.path == applicationURL.standardizedFileURL.path
                else { return nil }
            }
            return application.processIdentifier
        })
    }

    static func isPeerVisible(
        windowList: [[String: Any]],
        peerPIDs: Set<pid_t>,
        sourcePID: pid_t,
        peerWindowLevel: Int = NSWindow.Level.statusBar.rawValue + 1
    ) -> Bool {
        windowList.contains { info in
            guard let ownerPID = islandWindowOwnerPID(info, windowLevel: peerWindowLevel) else { return false }
            return ownerPID != sourcePID && peerPIDs.contains(ownerPID)
        }
    }

    static func isPeerFrontmost(
        windowList: [[String: Any]],
        peerPIDs: Set<pid_t>,
        sourcePID: pid_t,
        peerWindowLevel: Int = NSWindow.Level.statusBar.rawValue + 1,
        sourceWindowLevel: Int = NSWindow.Level.statusBar.rawValue + 1
    ) -> Bool {
        // CGWindowList 按前后顺序返回；源岛重新置顶后，迟到的 hide 不能通过确认。
        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == sourcePID || peerPIDs.contains(ownerPID) else { continue }
            let expectedLevel = ownerPID == sourcePID ? sourceWindowLevel : peerWindowLevel
            guard islandWindowOwnerPID(info, windowLevel: expectedLevel) != nil else { continue }
            return ownerPID != sourcePID
        }
        return false
    }

    private static func islandWindowOwnerPID(_ info: [String: Any], windowLevel: Int) -> pid_t? {
        guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
              ownerPID > 0,
              let layer = info[kCGWindowLayer as String] as? Int,
              // XIsland 设置窗也使用 statusBar + 2，必须按所属应用匹配精确岛层级。
              layer == windowLevel,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let alpha = info[kCGWindowAlpha as String] as? CGFloat,
              alpha.isFinite, alpha > 0,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let width = bounds["Width"], width.isFinite, width > 0,
              let height = bounds["Height"], height.isFinite, height > 0
        else { return nil }
        return ownerPID
    }

    @MainActor
    private static func runningPeerPIDs(bundleIdentifier: String, applicationURL: URL?) -> Set<pid_t> {
        peerProcessIdentifiers(
            bundleIdentifier: bundleIdentifier,
            applicationURL: applicationURL,
            applications: NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map {
                RunningApplication(
                    processIdentifier: $0.processIdentifier,
                    bundleIdentifier: $0.bundleIdentifier,
                    applicationURL: $0.bundleURL
                )
            }
        )
    }

    private static func onScreenWindows() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]]
    }
}
