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
        let peerPIDs = runningPeerPIDs(bundleIdentifier: bundleIdentifier, applicationURL: applicationURL)
        guard !peerPIDs.isEmpty, let windows = onScreenWindows() else { return false }
        return isPeerVisible(windowList: windows, peerPIDs: peerPIDs, sourcePID: sourcePID)
    }

    @MainActor
    static func isPeerFrontmost(
        bundleIdentifier: String,
        applicationURL: URL?,
        sourcePID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        let peerPIDs = runningPeerPIDs(bundleIdentifier: bundleIdentifier, applicationURL: applicationURL)
        guard !peerPIDs.isEmpty, let windows = onScreenWindows() else { return false }
        return isPeerFrontmost(windowList: windows, peerPIDs: peerPIDs, sourcePID: sourcePID)
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
        sourcePID: pid_t
    ) -> Bool {
        windowList.contains { info in
            guard let ownerPID = islandWindowOwnerPID(info) else { return false }
            return ownerPID != sourcePID && peerPIDs.contains(ownerPID)
        }
    }

    static func isPeerFrontmost(
        windowList: [[String: Any]],
        peerPIDs: Set<pid_t>,
        sourcePID: pid_t
    ) -> Bool {
        // CGWindowList 按前后顺序返回；源岛重新置顶后，迟到的 hide 不能通过确认。
        for info in windowList {
            guard let ownerPID = islandWindowOwnerPID(info),
                  ownerPID == sourcePID || peerPIDs.contains(ownerPID) else { continue }
            return ownerPID != sourcePID
        }
        return false
    }

    private static func islandWindowOwnerPID(_ info: [String: Any]) -> pid_t? {
        guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
              ownerPID > 0,
              let layer = info[kCGWindowLayer as String] as? Int,
              // XIsland 与 XNook 分别使用 statusBar + 1 和 + 2。
              layer == NSWindow.Level.statusBar.rawValue + 1 || layer == NSWindow.Level.statusBar.rawValue + 2,
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
