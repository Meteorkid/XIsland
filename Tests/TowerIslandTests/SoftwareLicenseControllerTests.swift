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
        defer { controller.stop() }
        let previousLanguage = AppPreferences.defaults.object(forKey: "appLanguage")
        defer {
            if let previousLanguage { AppPreferences.defaults.set(previousLanguage, forKey: "appLanguage") }
            else { AppPreferences.defaults.removeObject(forKey: "appLanguage") }
        }
        for language in ["zh", "en"] {
            AppPreferences.defaults.set(language, forKey: "appLanguage")
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
                .write(to: output.appendingPathComponent("xisland-license-\(language).png"))
        }
    }

    private func makeController(key: Curve25519.Signing.PrivateKey, store: LicenseTestStore,
                                response: Data? = nil) -> SoftwareLicenseController {
        SoftwareLicenseController(session: SoftwareLicenseSession(
            productId: "xisland", deviceId: String(repeating: "a", count: 64), deviceName: "Test Mac",
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            api: SoftwareLicenseAPI(baseURL: URL(string: "https://license.invalid")!,
                transport: LicenseTestTransport(response: response)), store: store
        ))
    }

    private func signedLease(key: Curve25519.Signing.PrivateKey, now: Date, duration: TimeInterval) throws -> String {
        let payload: [String: Any] = [
            "version": 1, "productId": "xisland", "deviceId": String(repeating: "a", count: 64),
            "licenseId": "test-license", "kind": "monthly", "issuedAt": now.timeIntervalSince1970 - 1,
            "expiresAt": now.timeIntervalSince1970 + duration,
            "entitlementExpiresAt": now.timeIntervalSince1970 + 30 * 86_400,
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
