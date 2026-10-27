import AppKit
import CryptoKit
import MeteorLicenseCore
import SwiftUI
import XCTest
@testable import XIsland

@MainActor
final class SoftwareLicenseControllerTests: XCTestCase {
    func testSignedLeaseExpirationStopsRuntimeAndPreservesSettingsStartup() throws {
        _ = NSApplication.shared
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let store = LicenseTestStore()
        let lease = try signedLease(key: key, now: now, duration: 60)
        store.value = try JSONSerialization.data(withJSONObject: [
            "lease": lease, "deviceToken": "test-only-token", "lastSeen": now.timeIntervalSince1970, "serverBlocked": false,
        ])
        let controller = makeController(key: key, store: store)
        defer { controller.stop() }
        var settingsStarts = 0
        var runtimeStarts = 0
        var runtimeStops = 0
        let app = AppDelegate(
            testConfiguration: AppTestConfiguration(isEnabled: false, fixtureName: nil,
                fixturePath: nil, diagnosticsPath: nil, disableAnimations: false),
            launchHooks: AppDelegate.LaunchHooks(
                performInitialStartup: { _ in settingsStarts += 1 },
                performProductionGlobalStartup: { _ in },
                performLicensedStartup: { _ in runtimeStarts += 1 },
                performLicenseLockdown: { _ in runtimeStops += 1 }
            ), softwareLicense: controller
        )
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertEqual(settingsStarts, 1)
        XCTAssertEqual(runtimeStarts, 1)
        XCTAssertTrue(app.licensedRuntimeRunning)
        controller.checkAccess(now: now.addingTimeInterval(61))
        XCTAssertFalse(app.licensedRuntimeRunning)
        XCTAssertEqual(runtimeStops, 1)
        controller.checkAccess(now: now.addingTimeInterval(62))
        XCTAssertEqual(runtimeStops, 1)
        XCTAssertEqual(settingsStarts, 1)
    }

    func testSuccessfulActivationUpdatesControllerAndNotifiesRuntime() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let lease = try signedLease(key: key, now: now, duration: 3_600)
        let data = try JSONSerialization.data(withJSONObject: ["lease": lease, "deviceToken": "test-only-token"])
        let controller = makeController(key: key, store: LicenseTestStore(), response: data)
        defer { controller.stop() }
        var accessChanges: [Bool] = []
        controller.onAccessChange = { accessChanges.append($0) }
        XCTAssertFalse(controller.allowsAccess)
        await controller.activate(code: "TEST-ACTIVATION-CODE")
        XCTAssertTrue(controller.allowsAccess)
        XCTAssertTrue(accessChanges.contains(true))
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.lastError)
    }

    func testNetworkFailureKeepsValidSignedLeaseButCannotOpenExpiredLease() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let store = LicenseTestStore()
        store.value = try JSONSerialization.data(withJSONObject: [
            "lease": signedLease(key: key, now: now, duration: 60),
            "deviceToken": "test-only-token", "lastSeen": now.timeIntervalSince1970, "serverBlocked": false,
        ])
        let controller = makeController(key: key, store: store)
        defer { controller.stop() }
        await controller.activate(code: "UNAVAILABLE-TEST-CODE")
        XCTAssertTrue(controller.allowsAccess)
        XCTAssertNotNil(controller.lastError)
        controller.checkAccess(now: now.addingTimeInterval(61))
        XCTAssertFalse(controller.allowsAccess)
    }

    func testSuccessfulRefreshClearsPreviousErrorEvenWhenLeaseIsUnchanged() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let lease = try signedLease(key: key, now: now, duration: 3_600)
        let response = try JSONSerialization.data(withJSONObject: ["lease": lease, "deviceToken": "test-only-token"])
        let transport = AuditLicenseTransport(steps: [.reply(503, Data("{\"error\":\"temporary outage\"}".utf8)), .reply(200, response)])
        let controller = try restoredController(key: key, lease: lease, now: now, transport: transport)
        defer { controller.stop() }
        controller.revalidate()
        try await waitUntil { !controller.isBusy }
        XCTAssertNotNil(controller.lastError)
        XCTAssertTrue(controller.allowsAccess)
        controller.revalidate()
        try await waitUntil { !controller.isBusy }
        XCTAssertTrue(controller.allowsAccess)
        XCTAssertNil(controller.lastError)
    }

    func testNewActivationValidationErrorReplacesPreviousNetworkError() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let transport = AuditLicenseTransport(steps: [.reply(503, Data("{\"error\":\"temporary outage\"}".utf8))])
        let controller = try restoredController(key: key,
            lease: signedLease(key: key, now: now, duration: 3_600), now: now, transport: transport)
        defer { controller.stop() }
        controller.revalidate()
        try await waitUntil { !controller.isBusy }
        await controller.activate(code: "XNK1-OLD-OFFLINE-CODE")
        XCTAssertEqual(controller.lastError, SoftwareLicenseError.legacyCode.localizedDescription)
        XCTAssertTrue(controller.allowsAccess)
        let requests = await transport.requestCount
        XCTAssertEqual(requests, 1, "旧协议码应显示迁移提示，不发出错误激活请求")
    }

    func testStopCancelsActivationAndRejectsLateSuccess() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let response = try JSONSerialization.data(withJSONObject: [
            "lease": signedLease(key: key, now: now, duration: 3_600), "deviceToken": "test-only-token",
        ])
        let transport = AuditLicenseTransport(steps: [.delayed])
        let controller = makeController(key: key, store: LicenseTestStore(), transport: transport)
        defer { controller.stop() }
        var accessChanges: [Bool] = []
        controller.onAccessChange = { accessChanges.append($0) }
        let activation = Task { await controller.activate(code: "DELAYED-ACTIVATION") }
        try await waitUntil { await transport.requestCount == 1 }
        controller.stop()
        await transport.resolve(status: 200, body: response)
        await activation.value
        XCTAssertFalse(controller.allowsAccess)
        XCTAssertFalse(accessChanges.contains(true))
        XCTAssertFalse(controller.isBusy)
    }

    func testStopSuppressesLateRefreshCallbacksForExistingLease() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let lease = try signedLease(key: key, now: now, duration: 3_600)
        let response = try JSONSerialization.data(withJSONObject: ["lease": lease, "deviceToken": "test-only-token"])
        let transport = AuditLicenseTransport(steps: [.delayed])
        let controller = try restoredController(key: key, lease: lease, now: now, transport: transport)
        defer { controller.stop() }
        var callbacks = 0
        controller.onAccessChange = { _ in callbacks += 1 }
        controller.revalidate()
        try await waitUntil { await transport.requestCount == 1 }
        controller.stop()
        let before = callbacks
        await transport.resolve(status: 200, body: response)
        try await waitUntil { !controller.isBusy }
        XCTAssertEqual(callbacks, before)
    }

    func testActualDeadlineTimerLocksWithoutAnotherManualCheck() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let transport = AuditLicenseTransport(steps: [.reply(503, Data("{}".utf8))])
        let controller = try restoredController(key: key,
            lease: signedLease(key: key, now: now, duration: 0.2), now: now, transport: transport)
        defer { controller.stop() }
        let expired = expectation(description: "signed deadline stopped access")
        var reported = false
        controller.onAccessChange = { allowed in
            if !allowed, !reported { reported = true; expired.fulfill() }
        }
        controller.start()
        await fulfillment(of: [expired], timeout: 3)
        XCTAssertFalse(controller.allowsAccess)
    }

    func testWakeRevalidatesOnceAfterRepeatedStart() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let transport = AuditLicenseTransport(steps: [.reply(503, Data("{}".utf8)), .reply(503, Data("{}".utf8))])
        let controller = try restoredController(key: key,
            lease: signedLease(key: key, now: now, duration: 3_600), now: now, transport: transport)
        defer { controller.stop() }
        controller.start()
        controller.start()
        try await waitUntil { !controller.isBusy }
        let initialRequests = await transport.requestCount
        XCTAssertEqual(initialRequests, 1)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitUntil { await transport.requestCount == 2 && !controller.isBusy }
        XCTAssertTrue(controller.allowsAccess)
    }

    func testForbiddenRefreshStopsRuntimeAndReactivationRestoresItOnce() async throws {
        _ = NSApplication.shared
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let lease = try signedLease(key: key, now: now, duration: 3_600)
        let response = try JSONSerialization.data(withJSONObject: ["lease": lease, "deviceToken": "renewed-test-token"])
        let transport = AuditLicenseTransport(steps: [
            .reply(503, Data("{\"error\":\"temporary outage\"}".utf8)),
            .reply(403, Data("{\"error\":\"device revoked\",\"code\":\"revoked\"}".utf8)),
            .reply(200, response),
        ])
        let controller = try restoredController(key: key, lease: lease, now: now, transport: transport)
        defer { controller.stop() }
        var starts = 0
        var stops = 0
        let app = AppDelegate(
            testConfiguration: AppTestConfiguration(isEnabled: true, fixtureName: nil, fixturePath: nil,
                diagnosticsPath: nil, disableAnimations: false),
            launchHooks: .init(performInitialStartup: { _ in }, performProductionGlobalStartup: { _ in },
                performLicensedStartup: { _ in starts += 1 }, performLicenseLockdown: { _ in stops += 1 }),
            softwareLicense: controller
        )
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try await waitUntil { !controller.isBusy }
        XCTAssertTrue(app.licensedRuntimeRunning)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0)
        controller.revalidate()
        try await waitUntil { !controller.isBusy }
        XCTAssertFalse(app.licensedRuntimeRunning)
        XCTAssertEqual(stops, 1)
        await controller.activate(code: "REACTIVATE-THIS-DEVICE")
        XCTAssertTrue(app.licensedRuntimeRunning)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 1)
        controller.checkAccess()
        XCTAssertEqual(starts, 2)
    }

    func testLicenseSettingsRenderInBothLanguages() async throws {
        guard let directory = ProcessInfo.processInfo.environment["X_ISLAND_RENDER_LICENSE_DIR"] else {
            throw XCTSkip("显式启用授权页面渲染")
        }
        _ = NSApplication.shared
        XCTAssertTrue(AppPreferences.isIsolated)
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let store = LicenseTestStore()
        store.value = try JSONSerialization.data(withJSONObject: [
            "lease": signedLease(key: key, now: now, duration: 3_600),
            "deviceToken": "test-only-token", "lastSeen": now.timeIntervalSince1970, "serverBlocked": false,
        ])
        let controller = makeController(key: key, store: store)
        let trial = try restoredController(key: key,
            lease: signedLease(key: key, now: now, duration: 3_600, trial: true), now: now,
            transport: LicenseTestTransport(response: nil))
        let expired = try restoredController(key: key,
            lease: signedLease(key: key, now: now.addingTimeInterval(-100), duration: 1), now: now,
            transport: LicenseTestTransport(response: nil))
        let modes = [("", controller), ("-trial", trial), ("-expired", expired)]
        defer { for (_, item) in modes { item.stop() } }
        let previousLanguage = AppPreferences.defaults.object(forKey: "appLanguage")
        defer {
            if let previousLanguage { AppPreferences.defaults.set(previousLanguage, forKey: "appLanguage") }
            else { AppPreferences.defaults.removeObject(forKey: "appLanguage") }
        }
        for language in ["zh", "en"] {
            AppPreferences.defaults.set(language, forKey: "appLanguage")
            for (suffix, controller) in modes {
                let view = PreferencesView(initialPane: "license")
                    .environment(SessionManager()).environment(AudioEngine()).environment(UpdateManager())
                    .environment(QuotaTracker()).environment(SessionPersistenceManager()).environment(ThemeManager())
                    .environment(\.softwareLicenseController, controller)
                    .defaultAppStorage(AppPreferences.defaults)
                let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
                host.appearance = NSAppearance(named: .darkAqua)
                host.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("xisland-license-\(language)\(suffix).png"))
            }
        }
    }

    private func makeController(key: Curve25519.Signing.PrivateKey, store: LicenseTestStore,
                                response: Data? = nil,
                                transport: (any SoftwareLicenseTransport)? = nil) -> SoftwareLicenseController {
        SoftwareLicenseController(session: SoftwareLicenseSession(
            productId: "xisland", deviceId: String(repeating: "a", count: 64), deviceName: "Test Mac",
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            api: SoftwareLicenseAPI(baseURL: URL(string: "https://license.invalid")!,
                transport: transport ?? LicenseTestTransport(response: response)), store: store
        ))
    }

    private func restoredController(key: Curve25519.Signing.PrivateKey, lease: String, now: Date,
                                    transport: any SoftwareLicenseTransport) throws -> SoftwareLicenseController {
        let store = LicenseTestStore()
        store.value = try JSONSerialization.data(withJSONObject: [
            "lease": lease, "deviceToken": "test-only-token", "lastSeen": now.timeIntervalSince1970, "serverBlocked": false,
        ])
        return makeController(key: key, store: store, transport: transport)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let completed = await condition()
        XCTAssertTrue(completed, "隔离授权请求未在时限内完成")
    }

    private func signedLease(key: Curve25519.Signing.PrivateKey, now: Date, duration: TimeInterval,
                             trial: Bool = false) throws -> String {
        let payload: [String: Any] = [
            "version": 1, "productId": "xisland", "deviceId": String(repeating: "a", count: 64),
            "licenseId": "test-license", "kind": trial ? "trial" : "monthly", "issuedAt": now.timeIntervalSince1970 - 1,
            "expiresAt": now.timeIntervalSince1970 + duration,
            "entitlementExpiresAt": now.timeIntervalSince1970 + (trial ? 14 * 86_400 - 1 : 30 * 86_400),
        ]
        let body = urlBase64(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let signed = "MSL1.\(body)"
        return "\(signed).\(urlBase64(try key.signature(for: Data(signed.utf8))))"
    }

    private func urlBase64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private final class LicenseTestStore: LicenseCredentialStore {
    var value: Data?
    func load() throws -> Data? { value }
    func save(_ data: Data) throws { value = data }
    func delete() throws { value = nil }
}

private struct LicenseTestTransport: SoftwareLicenseTransport {
    let response: Data?
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let response else { throw URLError(.notConnectedToInternet) }
        return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor AuditLicenseTransport: SoftwareLicenseTransport {
    enum Step { case reply(Int, Data), delayed }
    private var steps: [Step]
    private var pending: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private var pendingURL: URL?
    private(set) var requestCount = 0
    init(steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        guard !steps.isEmpty else { throw URLError(.notConnectedToInternet) }
        switch steps.removeFirst() {
        case let .reply(status, body):
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .delayed:
            pendingURL = request.url
            return await withCheckedContinuation { pending = $0 }
        }
    }
    func resolve(status: Int, body: Data) {
        guard let pending, let pendingURL else { return }
        self.pending = nil
        pending.resume(returning: (body, HTTPURLResponse(url: pendingURL, statusCode: status, httpVersion: nil, headerFields: nil)!))
    }
}
