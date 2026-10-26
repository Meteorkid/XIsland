import AppKit
import CoreFoundation

/// 已运行对端的只读预览入口；DNC 只唤醒，图像经认证的私有连接返回。
@MainActor
final class LinkedIslandPreviewService {
    static let capabilityKey = "IslandPreviewProtocolVersion"
    static let protocolVersion = 1

    private let app: IslandApp
    private let capture: @MainActor () -> IslandPreviewSnapshot?
    private var observer: NSObjectProtocol?
    private var response: LinkedIslandPreviewTransport.Handle?
    private var activeRequestID: UUID?

    init(app: IslandApp, capture: @escaping @MainActor () -> IslandPreviewSnapshot?) {
        self.app = app
        self.capture = capture
    }

    static func notificationName(for app: IslandApp) -> Notification.Name {
        Notification.Name("island.preview.request.\(app.rawValue)")
    }

    static func supportsPreview(bundleInfo: [String: Any]?) -> Bool {
        guard let value = bundleInfo?[capabilityKey] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: value.objCType))
        else { return false }
        return value.intValue == protocolVersion
    }

    /// 与发起端共享正式安装位置、能力版本和唯一运行实例的判定。
    static func runningPeer(for app: IslandApp) -> LinkedIslandPreviewPeer? {
        guard let bundle = installedBundle(for: app), supportsPreview(bundleInfo: bundle.infoDictionary),
              let executableURL = bundle.executableURL else { return nil }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier(for: app))
            .filter { !$0.isTerminated && $0.processIdentifier > 0 }
        guard applications.count == 1, let running = applications.first,
              running.bundleURL?.standardizedFileURL.path == bundle.bundleURL.standardizedFileURL.path,
              let runningExecutable = running.executableURL,
              runningExecutable.resolvingSymlinksInPath().path == executableURL.resolvingSymlinksInPath().path
        else { return nil }
        return LinkedIslandPreviewPeer(pid: running.processIdentifier,
                                       executablePath: executableURL.resolvingSymlinksInPath().path)
    }

    func start() {
        guard observer == nil, isCurrentFormalProcess else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName(for: app), object: nil, queue: .main
        ) { [weak self] note in
            guard let request = LinkedIslandPreviewTransport.Request(userInfo: note.userInfo) else { return }
            MainActor.assumeIsolated { self?.receive(request) }
        }
    }

    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        activeRequestID = nil
        response?.cancel()
        response = nil
    }

    private func receive(_ request: LinkedIslandPreviewTransport.Request) {
        guard observer != nil, isCurrentFormalProcess, activeRequestID != request.id,
              response?.isFinished != false,
              let source = Self.runningPeer(for: app == .xisland ? .xnook : .xisland) else { return }
        response?.cancel()
        activeRequestID = request.id
        response = LinkedIslandPreviewTransport.respond(to: request, expectedSource: source) { [weak self] in
            guard let self, self.observer != nil, self.activeRequestID == request.id,
                  self.isCurrentFormalProcess else { return nil }
            return self.capture()
        }
    }

    private var isCurrentFormalProcess: Bool {
        guard Bundle.main.bundleIdentifier == Self.bundleIdentifier(for: app),
              let peer = Self.runningPeer(for: app),
              peer.pid == ProcessInfo.processInfo.processIdentifier,
              let executableURL = Bundle.main.executableURL else { return false }
        return peer.executablePath == executableURL.resolvingSymlinksInPath().path
    }

    private static func installedBundle(for app: IslandApp) -> Bundle? {
        let name = app == .xisland ? "X Island.app" : "X Nook.app"
        for directory in [URL(fileURLWithPath: "/Applications"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            let url = directory.appendingPathComponent(name)
            if let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleIdentifier(for: app) { return bundle }
        }
        return nil
    }

    private static func bundleIdentifier(for app: IslandApp) -> String {
        app == .xisland ? "dev.xisland.app" : "com.meteorkid.xnook"
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        response?.cancel()
    }
}
