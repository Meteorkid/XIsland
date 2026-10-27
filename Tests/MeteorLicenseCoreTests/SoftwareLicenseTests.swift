import XCTest
import CryptoKit
@testable import MeteorLicenseCore

final class MemoryLicenseStore: LicenseCredentialStore {
    var data: Data?
    var fails = false
    func load() throws -> Data? { if fails { throw SoftwareLicenseError.storage(-1) }; return data }
    func save(_ data: Data) throws { if fails { throw SoftwareLicenseError.storage(-1) }; self.data = data }
    func delete() throws { data = nil }
}

final class StubLicenseTransport: SoftwareLicenseTransport {
    var requests: [URLRequest] = []
    var response = Data()
    var status = 200
    var failure: Error?
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        return (response, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class SoftwareLicenseTests: XCTestCase {
    private let product = "xnook"
    private let device = String(repeating: "a", count: 64)
    private let key = Curve25519.Signing.PrivateKey()

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func lease(productId: String = "xnook", deviceId: String? = nil,
                       kind: String = "lifetime", issuedAt: TimeInterval = Date().timeIntervalSince1970,
                       expiresAt: TimeInterval? = nil, entitlement: TimeInterval? = nil) throws -> String {
        let body: [String: Any] = ["version": 1, "productId": productId, "deviceId": deviceId ?? device,
            "licenseId": "test-license", "kind": kind, "issuedAt": issuedAt,
            "expiresAt": expiresAt ?? issuedAt + 7 * 86_400,
            "entitlementExpiresAt": entitlement as Any? ?? NSNull()]
        let segment = base64URL(try JSONSerialization.data(withJSONObject: body, options: .sortedKeys))
        return "MSL1.\(segment).\(base64URL(try key.signature(for: Data("MSL1.\(segment)".utf8))))"
    }

    private func prepare(_ transport: StubLicenseTransport, lease: String) throws {
        transport.response = try JSONSerialization.data(withJSONObject: ["lease": lease, "deviceToken": "private-test-token"])
    }

    private func session(transport: StubLicenseTransport, store: MemoryLicenseStore = MemoryLicenseStore(),
                         publicKey: String? = nil) -> SoftwareLicenseSession {
        SoftwareLicenseSession(productId: product, deviceId: device, deviceName: "Test Mac",
            publicKeyBase64: publicKey ?? key.publicKey.rawRepresentation.base64EncodedString(),
            api: SoftwareLicenseAPI(baseURL: URL(string: "https://www.imagentx.top")!, transport: transport), store: store)
    }

    func testValidLeaseAndWrongProductOrDevice() throws {
        let verifier = try SoftwareLicenseVerifier(publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString())
        let token = try lease()
        XCTAssertEqual(try verifier.verify(token, productId: product, deviceId: device).kind, .lifetime)
        XCTAssertThrowsError(try verifier.verify(token, productId: "xisland", deviceId: device))
        XCTAssertThrowsError(try verifier.verify(token, productId: product, deviceId: String(repeating: "b", count: 64)))
    }

    func testTamperingAndWrongKeyRejected() throws {
        let verifier = try SoftwareLicenseVerifier(publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString())
        let token = try lease()
        var parts = token.split(separator: ".").map(String.init)
        parts[1] = base64URL(Data("{}".utf8))
        XCTAssertThrowsError(try verifier.verify(parts.joined(separator: "."), productId: product, deviceId: device))
        let other = try SoftwareLicenseVerifier(publicKeyBase64: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
        XCTAssertThrowsError(try other.verify(token, productId: product, deviceId: device))
    }

    func testLeaseCannotExceedSevenDaysOrEntitlement() throws {
        let now = Date().timeIntervalSince1970
        let verifier = try SoftwareLicenseVerifier(publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString())
        XCTAssertThrowsError(try verifier.verify(lease(issuedAt: now, expiresAt: now + 7 * 86_400 + 1), productId: product, deviceId: device))
        XCTAssertThrowsError(try verifier.verify(lease(kind: "monthly", issuedAt: now, expiresAt: now + 100, entitlement: now + 99), productId: product, deviceId: device))
        XCTAssertThrowsError(try verifier.verify(lease(kind: "trial", issuedAt: now, entitlement: now + 14 * 86_400 + 1), productId: product, deviceId: device))
    }

    func testTrialRequestContractAndExactExpiry() async throws {
        let transport = StubLicenseTransport()
        let now = Date().timeIntervalSince1970
        try prepare(transport, lease: lease(kind: "trial", issuedAt: now, expiresAt: now + 7 * 86_400, entitlement: now + 14 * 86_400))
        let client = session(transport: transport)
        try await client.requestTrial()
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://www.imagentx.top/api/software-licenses/trial")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["productId": product, "deviceId": device, "deviceName": "Test Mac"])
        client.checkAccess(now: Date(timeIntervalSince1970: now + 7 * 86_400 - 1))
        XCTAssertTrue(client.state.allowsAccess)
        client.checkAccess(now: Date(timeIntervalSince1970: now + 7 * 86_400))
        XCTAssertEqual(client.state, .expired)
    }

    func testLastTrialDayStillWorksUntilExactEntitlementBoundary() async throws {
        let transport = StubLicenseTransport()
        let now = Date().timeIntervalSince1970
        let end = now + 86_400
        try prepare(transport, lease: lease(kind: "trial", issuedAt: now, expiresAt: end, entitlement: end))
        let client = session(transport: transport)
        try await client.requestTrial()
        client.checkAccess(now: Date(timeIntervalSince1970: now + 1))
        XCTAssertTrue(client.state.allowsAccess, "进入第14天一秒后仍应可用")
        client.checkAccess(now: Date(timeIntervalSince1970: end - 0.01))
        XCTAssertTrue(client.state.allowsAccess)
        client.checkAccess(now: Date(timeIntervalSince1970: end))
        XCTAssertFalse(client.state.allowsAccess)
    }

    func testNetworkFailureUsesOnlyExistingUnexpiredLease() async throws {
        let transport = StubLicenseTransport()
        let now = Date().timeIntervalSince1970
        try prepare(transport, lease: lease(issuedAt: now, expiresAt: now + 100))
        let store = MemoryLicenseStore()
        let client = session(transport: transport, store: store)
        try await client.activate(code: "TEST-PAID-CODE")
        transport.failure = URLError(.notConnectedToInternet)
        do { try await client.refreshOnline(); XCTFail("Expected offline error") } catch {}
        XCTAssertTrue(client.state.allowsAccess)
        let restored = session(transport: transport, store: store)
        XCTAssertTrue(restored.state.allowsAccess)
        restored.checkAccess(now: Date(timeIntervalSince1970: now + 100))
        XCTAssertFalse(restored.state.allowsAccess)
        let fresh = session(transport: transport)
        await fresh.start()
        XCTAssertFalse(fresh.state.allowsAccess)
    }

    func testRevokedServerResponseLocksImmediatelyAndPersists() async throws {
        let transport = StubLicenseTransport()
        try prepare(transport, lease: lease())
        let store = MemoryLicenseStore()
        let client = session(transport: transport, store: store)
        try await client.activate(code: "TEST-CODE")
        transport.status = 403
        transport.response = Data("{\"code\":\"license_revoked\",\"message\":\"授权已撤销\"}".utf8)
        do { try await client.refreshOnline(); XCTFail("Expected revoked") } catch {}
        XCTAssertFalse(client.state.allowsAccess)
        XCTAssertFalse(session(transport: transport, store: store).state.allowsAccess)
    }

    func testDeactivationContractAndNoAutomaticRetrial() async throws {
        let transport = StubLicenseTransport()
        try prepare(transport, lease: lease())
        let client = session(transport: transport)
        try await client.activate(code: "TEST-CODE")
        transport.response = Data("{}".utf8)
        try await client.deactivate()
        let last = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(last.url?.lastPathComponent, "deactivate")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(last.httpBody)) as? [String: String])
        XCTAssertEqual(body["deviceToken"], "private-test-token")
        XCTAssertEqual(body["productId"], product)
        XCTAssertFalse(client.state.allowsAccess)
        let count = transport.requests.count
        await client.start()
        XCTAssertEqual(transport.requests.count, count)
    }

    func testActivationAndRefreshRequestContracts() async throws {
        let transport = StubLicenseTransport()
        try prepare(transport, lease: lease())
        let client = session(transport: transport)
        try await client.activate(code: "  TEST-CODE \n")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(transport.requests[0].httpBody)) as? [String: String])
        XCTAssertEqual(body, ["productId": product, "deviceId": device, "deviceName": "Test Mac", "code": "TEST-CODE"])
        try await client.refreshOnline()
        let refresh = transport.requests[1]
        XCTAssertEqual(refresh.url?.lastPathComponent, "refresh")
        let refreshBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(refresh.httpBody)) as? [String: String])
        XCTAssertEqual(refreshBody, ["productId": product, "deviceId": device, "deviceToken": "private-test-token"])
    }

    func testClockRollbackCannotRestoreExpiredAccess() async throws {
        let transport = StubLicenseTransport()
        let now = Date().timeIntervalSince1970
        try prepare(transport, lease: lease(issuedAt: now, expiresAt: now + 10))
        let store = MemoryLicenseStore()
        let client = session(transport: transport, store: store)
        try await client.activate(code: "TEST-CODE")
        client.checkAccess(now: Date(timeIntervalSince1970: now + 11))
        client.checkAccess(now: Date(timeIntervalSince1970: now - 1000))
        XCTAssertFalse(client.state.allowsAccess)
        XCTAssertFalse(session(transport: transport, store: store).state.allowsAccess)
    }

    func testFreshSignedResponseRecoversAfterAccidentallySettingClockToFuture() async throws {
        let transport = StubLicenseTransport()
        let now = Date().timeIntervalSince1970
        try prepare(transport, lease: lease(issuedAt: now, expiresAt: now + 100))
        let client = session(transport: transport)
        try await client.activate(code: "TEST-CODE")
        client.checkAccess(now: Date(timeIntervalSince1970: now + 30 * 86_400))
        XCTAssertFalse(client.state.allowsAccess)
        client.checkAccess(now: Date(timeIntervalSince1970: now))
        XCTAssertFalse(client.state.allowsAccess, "仅修改本地时钟不能恢复访问")
        try await client.refreshOnline()
        XCTAssertTrue(client.state.allowsAccess, "校准系统时间后的新签名响应应恢复访问")
    }

    func testStaleOnlineResponseCannotResetMonotonicClock() async throws {
        let transport = StubLicenseTransport()
        let now = Date().timeIntervalSince1970
        try prepare(transport, lease: lease(issuedAt: now - 3600, expiresAt: now + 100))
        let client = session(transport: transport)
        do { try await client.activate(code: "TEST-CODE"); XCTFail("Expected stale response rejection") } catch {}
        XCTAssertFalse(client.state.allowsAccess)
    }

    func testExpiryEmitsLockTransition() async throws {
        let transport = StubLicenseTransport()
        let now = Date().timeIntervalSince1970
        try prepare(transport, lease: lease(issuedAt: now, expiresAt: now + 10))
        let client = session(transport: transport)
        var access: [Bool] = []
        client.onStateChange = { access.append($0.allowsAccess) }
        try await client.activate(code: "TEST-CODE")
        client.checkAccess(now: Date(timeIntervalSince1970: now + 10))
        XCTAssertEqual(access, [true, false])
    }

    func testMissingKeyAndLegacyCodeNeverGrantAccess() async throws {
        let transport = StubLicenseTransport()
        let client = session(transport: transport, publicKey: "")
        XCTAssertEqual(client.state, .unconfigured)
        await client.start()
        XCTAssertTrue(transport.requests.isEmpty)
        let configured = session(transport: transport)
        do { try await configured.activate(code: "XNK1-old"); XCTFail("Expected migration") }
        catch { XCTAssertEqual(error as? SoftwareLicenseError, .legacyCode) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testStorageFailureCannotReportSuccessfulActivation() async throws {
        let transport = StubLicenseTransport()
        try prepare(transport, lease: lease())
        let store = MemoryLicenseStore()
        let client = session(transport: transport, store: store)
        store.fails = true
        do { try await client.activate(code: "TEST-CODE"); XCTFail("Expected storage failure") } catch {}
        XCTAssertFalse(client.state.allowsAccess)
    }

    func testFallbackDeviceIdentityPersistsAndIsHashed() throws {
        let store = MemoryLicenseStore()
        let first = try LicenseDeviceIdentity.resolve(store: store, hardwareUUID: { nil })
        let second = try LicenseDeviceIdentity.resolve(store: store, hardwareUUID: { nil })
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, String(data: try XCTUnwrap(store.data), encoding: .utf8))
        let hardware = try LicenseDeviceIdentity.resolve(store: MemoryLicenseStore(), hardwareUUID: { "hardware-uuid" })
        XCTAssertEqual(hardware.count, 64)
        XCTAssertNotEqual(hardware, "hardware-uuid")
    }

    func testExternalServerFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["METEOR_LICENSE_FIXTURE_PATH"] else {
            throw XCTSkip("Provide METEOR_LICENSE_FIXTURE_PATH for server-to-Swift verification")
        }
        struct Fixture: Decodable { let publicKeyBase64: String; let lease: String; let productId: String; let deviceId: String; let now: TimeInterval? }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let verifier = try SoftwareLicenseVerifier(publicKeyBase64: fixture.publicKeyBase64)
        let payload = try verifier.verify(fixture.lease, productId: fixture.productId, deviceId: fixture.deviceId)
        XCTAssertEqual(payload.version, 1)
        if let now = fixture.now { XCTAssertGreaterThan(payload.deadline.timeIntervalSince1970, now) }
    }
}
