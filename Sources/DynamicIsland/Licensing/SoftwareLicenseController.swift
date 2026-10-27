import AppKit
import Foundation
import MeteorLicenseCore
import Observation
import SwiftUI

@MainActor
@Observable
final class SoftwareLicenseController {
    private(set) var state: SoftwareLicenseState
    private(set) var lastError: String?
    private(set) var isBusy = false
    @ObservationIgnored var onAccessChange: ((Bool) -> Void)?
    @ObservationIgnored private let session: SoftwareLicenseSession?
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var lastOnlineCheck = Date.distantPast
    private let refreshInterval: TimeInterval = 15 * 60

    var allowsAccess: Bool { state.allowsAccess }

    init(session: SoftwareLicenseSession) {
        self.session = session
        self.state = session.state
        self.lastError = session.lastError
        session.onStateChange = { [weak self] state in
            guard let self else { return }
            self.state = state
            self.lastError = self.session?.lastError
            self.scheduleDeadline()
            self.onAccessChange?(state.allowsAccess)
        }
    }

    private init(error: String) {
        session = nil
        state = .blocked(error)
        lastError = error
    }

    static func live(bundle: Bundle = .main) -> SoftwareLicenseController {
        do {
            let service = "dev.xisland.software-license.v1"
            let identityStore = KeychainLicenseStore(service: service, account: "device")
            let deviceId = try LicenseDeviceIdentity.resolve(store: identityStore)
            let base = bundle.object(forInfoDictionaryKey: "SoftwareLicenseAPIBaseURL") as? String
                ?? "https://www.imagentx.top"
            guard let url = URL(string: base), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else {
                return SoftwareLicenseController(error: "授权服务地址配置无效，请联系开发者。")
            }
            let session = SoftwareLicenseSession(
                productId: "xisland", deviceId: deviceId,
                deviceName: String((Host.current().localizedName ?? "Mac").prefix(100)),
                publicKeyBase64: bundle.object(forInfoDictionaryKey: "SoftwareLicensePublicKey") as? String,
                api: SoftwareLicenseAPI(baseURL: url),
                store: KeychainLicenseStore(service: service)
            )
            return SoftwareLicenseController(session: session)
        } catch {
            return SoftwareLicenseController(error: error.localizedDescription)
        }
    }

    func start() {
        guard heartbeat == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAccessAndRefreshIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.revalidate() }
        }
        scheduleDeadline()
        revalidate()
    }

    func stop() {
        heartbeat?.invalidate()
        heartbeat = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        requestTask?.cancel()
        requestTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    func checkAccess(now: Date = Date()) {
        session?.checkAccess(now: now)
        synchronizeState()
    }

    private func checkAccessAndRefreshIfNeeded() {
        checkAccess()
        if Date().timeIntervalSince(lastOnlineCheck) >= refreshInterval { revalidate() }
    }

    func revalidate() {
        checkAccess()
        guard !isBusy, let session else { return }
        isBusy = true
        lastOnlineCheck = Date()
        requestTask = Task { [weak self] in
            await session.start()
            guard let self else { return }
            self.isBusy = false
            self.synchronizeState()
            self.requestTask = nil
        }
    }

    func activate(code: String) async {
        await perform { session in try await session.activate(code: code) }
    }

    func requestTrial() async {
        await perform { session in try await session.requestTrial() }
    }

    func deactivate() async {
        await perform { session in try await session.deactivate() }
    }

    private func perform(_ operation: (SoftwareLicenseSession) async throws -> Void) async {
        guard !isBusy, let session else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation(session)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        synchronizeState()
    }

    private func synchronizeState() {
        guard let session else { return }
        state = session.state
        lastError = session.lastError ?? lastError
        scheduleDeadline()
        onAccessChange?(state.allowsAccess)
    }

    private func scheduleDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let session, let deadline = session.nextDeadline else { return }
        let interval = max(0.01, deadline.timeIntervalSince(session.effectiveNow()))
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAccess() }
        }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }
}

private struct SoftwareLicenseControllerKey: EnvironmentKey {
    static let defaultValue: SoftwareLicenseController? = nil
}

extension EnvironmentValues {
    var softwareLicenseController: SoftwareLicenseController? {
        get { self[SoftwareLicenseControllerKey.self] }
        set { self[SoftwareLicenseControllerKey.self] = newValue }
    }
}
