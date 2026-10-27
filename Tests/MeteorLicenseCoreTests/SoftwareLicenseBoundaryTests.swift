import XCTest
import CryptoKit
@testable import MeteorLicenseCore

@MainActor
final class SoftwareLicenseBoundaryTests: XCTestCase {
    func testExplicitInvalidDeviceDuringDeactivationLocksAndSurvivesColdRestart() async throws {
        for status in [401, 403, 404, 410] {
            let fixture = BoundaryFixture()
            try fixture.respondWithLease()
            let client = fixture.makeSession()
            try await client.activate(code: "AUDIT-CODE")
            fixture.transport.status = status
            fixture.transport.data = Data("{\"code\":\"device_revoked\",\"error\":\"设备已撤销\"}".utf8)
            do { try await client.deactivate(); XCTFail("Expected explicit invalid-device error") } catch {}
            XCTAssertFalse(client.state.allowsAccess, "解绑响应 \(status) 已确认设备无效，不能继续使用缓存")
            XCTAssertFalse(fixture.makeSession().state.allowsAccess, "冷重启也必须保持明确的设备撤销")
        }
    }

    func testSuccessfulServerDeactivationWithStorageFailureLocksCurrentSession() async throws {
        let fixture = BoundaryFixture()
        try fixture.respondWithLease()
        let client = fixture.makeSession()
        try await client.activate(code: "AUDIT-CODE")
        fixture.transport.data = Data("{}".utf8)
        fixture.store.failWrite = true
        do { try await client.deactivate(); XCTFail("Expected persistence error") } catch {}
        XCTAssertFalse(client.state.allowsAccess, "服务端已解绑，本机写入失败也不能保留active状态")
    }

    func testTemporaryReadFailureCanRecoverAfterStorageBecomesAvailable() async throws {
        let fixture = BoundaryFixture()
        try fixture.respondWithLease()
        try await fixture.makeSession().activate(code: "AUDIT-CODE")
        fixture.store.failRead = true
        let reopened = fixture.makeSession()
        XCTAssertFalse(reopened.state.allowsAccess)
        fixture.store.failRead = false
        await reopened.start()
        XCTAssertTrue(reopened.state.allowsAccess, "存储恢复后应能重读已有凭据并联网验证")
    }

    func testTemporaryWriteFailureCanRecoverWithoutDroppingCredential() async throws {
        let fixture = BoundaryFixture()
        try fixture.respondWithLease()
        let client = fixture.makeSession()
        try await client.activate(code: "AUDIT-CODE")
        fixture.store.failWrite = true
        client.checkAccess()
        XCTAssertFalse(client.state.allowsAccess)
        fixture.store.failWrite = false
        await client.start()
        XCTAssertTrue(client.state.allowsAccess, "临时写入失败恢复后不应永久锁死当前会话")
    }

    func testStorageRecoveryDoesNotResurrectAnAcknowledgedRevocation() async throws {
        let fixture = BoundaryFixture()
        try fixture.respondWithLease()
        let client = fixture.makeSession()
        try await client.activate(code: "AUDIT-CODE")
        fixture.store.failWrite = true
        fixture.transport.status = 403
        fixture.transport.data = Data("{\"code\":\"device_revoked\",\"error\":\"设备已撤销\"}".utf8)
        do { try await client.refreshOnline(); XCTFail("Expected revocation") } catch {}
        fixture.store.failWrite = false
        fixture.transport.failure = URLError(.notConnectedToInternet)
        await client.start()
        XCTAssertFalse(client.state.allowsAccess)
        XCTAssertFalse(fixture.makeSession().state.allowsAccess)
    }

    func testUnreadableCredentialIsNotOverwrittenDuringRecovery() async {
        let fixture = BoundaryFixture()
        let invalid = Data("unreadable protected record".utf8)
        fixture.store.data = invalid
        let client = fixture.makeSession()
        await client.start()
        XCTAssertFalse(client.state.allowsAccess)
        XCTAssertEqual(fixture.store.data, invalid)
        XCTAssertTrue(fixture.transport.requests.isEmpty)
    }

    func testOfflineDeactivationKeepsValidCredentialAndCanBeRetried() async throws {
        let fixture = BoundaryFixture()
        try fixture.respondWithLease()
        let client = fixture.makeSession()
        try await client.activate(code: "AUDIT-CODE")
        fixture.transport.failure = URLError(.notConnectedToInternet)
        do { try await client.deactivate(); XCTFail("Expected network error") } catch {}
        XCTAssertTrue(client.state.allowsAccess)
        XCTAssertTrue(fixture.makeSession().state.allowsAccess)
        fixture.transport.failure = nil
        fixture.transport.data = Data("{}".utf8)
        try await client.deactivate()
        XCTAssertFalse(client.state.allowsAccess)
    }

    func testCancelledTrialRejectsLateSuccessfulResponseWithoutSavingCredential() async throws {
        let fixture = BoundaryFixture()
        let gate = BoundaryDelayedTransport()
        let client = fixture.makeSession(transport: gate)
        let task = Task { try await client.requestTrial() }
        await gate.waitUntilRequested()
        task.cancel()
        await gate.complete(data: try fixture.responseData(kind: "trial", duration: 60, entitlement: fixture.now + 14 * 86_400))
        do { try await task.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertFalse(client.state.allowsAccess)
        XCTAssertNil(try fixture.savedObject()["deviceToken"])
        XCTAssertNil(try fixture.savedObject()["lease"])
    }

    func testCancelledRefreshCannotReplaceAnExistingReceipt() async throws {
        let fixture = BoundaryFixture()
        try fixture.respondWithLease(duration: 120)
        try await fixture.makeSession().activate(code: "AUDIT-CODE")
        let oldLease = try XCTUnwrap(fixture.savedObject()["lease"] as? String)
        let gate = BoundaryDelayedTransport()
        let client = fixture.makeSession(transport: gate)
        let task = Task { try await client.refreshOnline() }
        await gate.waitUntilRequested()
        task.cancel()
        await gate.complete(data: try fixture.responseData(duration: 600))
        do { try await task.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertEqual(try fixture.savedObject()["lease"] as? String, oldLease)
        XCTAssertTrue(client.state.allowsAccess)
    }

    func testColdRestartCannotReviveExpiredSubscriptionByTurningClockBack() async throws {
        let fixture = BoundaryFixture()
        try fixture.respondWithLease(kind: "annual", duration: 60, entitlement: fixture.now + 60)
        let client = fixture.makeSession()
        try await client.activate(code: "AUDIT-CODE")
        client.checkAccess(now: Date(timeIntervalSince1970: fixture.now + 60))
        XCTAssertEqual(client.state, .expired)
        let reopened = fixture.makeSession(now: Date(timeIntervalSince1970: fixture.now - 365 * 86_400))
        XCTAssertEqual(reopened.state, .expired)
    }

    func testColdRestartChecksExactSevenDayDeadlineForLifetimeLease() async throws {
        let fixture = BoundaryFixture()
        try fixture.respondWithLease(duration: 7 * 86_400)
        try await fixture.makeSession().activate(code: "AUDIT-CODE")
        XCTAssertTrue(fixture.makeSession(now: Date(timeIntervalSince1970: fixture.now + 7 * 86_400 - 1)).state.allowsAccess)
        XCTAssertFalse(fixture.makeSession(now: Date(timeIntervalSince1970: fixture.now + 7 * 86_400)).state.allowsAccess)
    }

    func testTamperedCachedLeaseDoesNotBecomeAnOfflineTrial() async throws {
        let fixture = BoundaryFixture()
        try fixture.respondWithLease()
        try await fixture.makeSession().activate(code: "AUDIT-CODE")
        var saved = try fixture.savedObject()
        saved["lease"] = "MSL1.e30.invalid"
        fixture.store.data = try JSONSerialization.data(withJSONObject: saved)
        fixture.transport.failure = URLError(.notConnectedToInternet)
        let reopened = fixture.makeSession()
        await reopened.start()
        XCTAssertFalse(reopened.state.allowsAccess)
        XCTAssertFalse(fixture.transport.requests.contains { $0.url?.lastPathComponent == "trial" })
    }

    func testWrongProductAndDeviceResponseCannotReplacePreviouslyValidLicense() async throws {
        for mismatch in ["product", "device"] {
            let fixture = BoundaryFixture()
            try fixture.respondWithLease()
            let client = fixture.makeSession()
            try await client.activate(code: "AUDIT-CODE")
            let oldLease = try XCTUnwrap(fixture.savedObject()["lease"] as? String)
            fixture.transport.data = try fixture.responseData(
                product: mismatch == "product" ? "xisland" : "xnook",
                device: mismatch == "device" ? String(repeating: "b", count: 64) : fixture.device)
            do { try await client.refreshOnline(); XCTFail("Expected binding rejection") } catch {}
            XCTAssertEqual(try fixture.savedObject()["lease"] as? String, oldLease)
            XCTAssertTrue(client.state.allowsAccess)
        }
    }

    func testInitialOfflineStartNeverReportsAnActiveTrialAndRetriesOnline() async throws {
        let fixture = BoundaryFixture()
        fixture.transport.failure = URLError(.notConnectedToInternet)
        let client = fixture.makeSession()
        await client.start()
        XCTAssertFalse(client.state.allowsAccess)
        XCTAssertNotNil(client.lastError)
        fixture.transport.failure = nil
        try fixture.respondWithLease(kind: "trial", duration: 60, entitlement: fixture.now + 14 * 86_400)
        await client.start()
        XCTAssertTrue(client.state.allowsAccess)
        XCTAssertEqual(fixture.transport.requests.map { $0.url?.lastPathComponent }, ["trial", "trial"])
    }
}

private final class BoundaryStore: LicenseCredentialStore {
    var data: Data?
    var failRead = false
    var failWrite = false
    func load() throws -> Data? { if failRead { throw SoftwareLicenseError.storage(-1) }; return data }
    func save(_ data: Data) throws { if failWrite { throw SoftwareLicenseError.storage(-1) }; self.data = data }
    func delete() throws { data = nil }
}

private final class BoundaryTransport: SoftwareLicenseTransport {
    var data = Data()
    var status = 200
    var failure: Error?
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor BoundaryDelayedTransport: SoftwareLicenseTransport {
    private var response: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var observer: CheckedContinuation<Void, Never>?
    private var request: URLRequest?
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return try await withCheckedThrowingContinuation { continuation in
            response = continuation
            observer?.resume(); observer = nil
        }
    }
    func waitUntilRequested() async {
        if response != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func complete(data: Data) {
        response?.resume(returning: (data, HTTPURLResponse(url: request!.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        response = nil
    }
}

@MainActor
private final class BoundaryFixture {
    let now = Date().timeIntervalSince1970
    let device = String(repeating: "a", count: 64)
    let key = Curve25519.Signing.PrivateKey()
    let store = BoundaryStore()
    let transport = BoundaryTransport()
    func makeSession(transport override: (any SoftwareLicenseTransport)? = nil, now: Date = Date()) -> SoftwareLicenseSession {
        SoftwareLicenseSession(productId: "xnook", deviceId: device, deviceName: "Audit fixture",
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            api: SoftwareLicenseAPI(baseURL: URL(string: "https://license-audit.invalid")!, transport: override ?? transport), store: store, now: now)
    }
    func savedObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(store.data)) as? [String: Any])
    }
    func respondWithLease(kind: String = "lifetime", duration: TimeInterval = 600, entitlement: TimeInterval? = nil) throws {
        transport.data = try responseData(kind: kind, duration: duration, entitlement: entitlement)
    }
    func responseData(kind: String = "lifetime", duration: TimeInterval = 600, entitlement: TimeInterval? = nil,
                      product: String = "xnook", device: String? = nil) throws -> Data {
        let payload: [String: Any] = ["version": 1, "productId": product, "deviceId": device ?? self.device,
            "licenseId": "audit-license", "kind": kind, "issuedAt": now, "expiresAt": now + duration,
            "entitlementExpiresAt": entitlement as Any? ?? NSNull()]
        let segment = base64URL(try JSONSerialization.data(withJSONObject: payload))
        let lease = "MSL1.\(segment).\(base64URL(try key.signature(for: Data("MSL1.\(segment)".utf8))))"
        return try JSONSerialization.data(withJSONObject: ["lease": lease, "deviceToken": "audit-token"])
    }
    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
