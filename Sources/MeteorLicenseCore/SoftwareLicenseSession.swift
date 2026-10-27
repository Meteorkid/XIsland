import Foundation

/// 两个产品共用协议与离线判定；调用方负责定时器、唤醒通知及停止产品服务。
@MainActor
public final class SoftwareLicenseSession {
    public private(set) var state: SoftwareLicenseState = .needsConnection {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public private(set) var lastError: String?
    public var onStateChange: ((SoftwareLicenseState) -> Void)?
    public var nextDeadline: Date? {
        if case .active(let payload) = state { return payload.deadline }
        return nil
    }

    private struct Record: Codable {
        var lease: String?
        var deviceToken: String?
        var lastSeen: TimeInterval
        var serverBlocked: Bool = false
    }

    private let productId: String
    private let deviceId: String
    private let deviceName: String
    private let verifier: SoftwareLicenseVerifier?
    private let api: SoftwareLicenseAPI
    private let store: any LicenseCredentialStore
    private var record: Record
    private var anchorTime: TimeInterval
    private var anchorUptime: TimeInterval
    private var isBusy = false
    private var storageFailed = false

    public init(productId: String, deviceId: String, deviceName: String, publicKeyBase64: String?,
                api: SoftwareLicenseAPI, store: any LicenseCredentialStore, now: Date = Date()) {
        self.productId = productId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.api = api
        self.store = store
        self.verifier = publicKeyBase64.flatMap { try? SoftwareLicenseVerifier(publicKeyBase64: $0) }
        self.record = Record(lastSeen: now.timeIntervalSince1970)
        self.anchorTime = now.timeIntervalSince1970
        self.anchorUptime = ProcessInfo.processInfo.systemUptime
        do {
            if let data = try store.load() { record = try JSONDecoder().decode(Record.self, from: data) }
            anchorTime = max(anchorTime, record.lastSeen)
        } catch {
            storageFailed = true
            lastError = "无法读取已保存的授权，请检查钥匙串访问权限。"
        }
        checkAccess(now: now)
    }

    public func effectiveNow(now: Date = Date()) -> Date {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - anchorUptime)
        return Date(timeIntervalSince1970: max(now.timeIntervalSince1970, record.lastSeen, anchorTime + elapsed))
    }

    public func checkAccess(now: Date = Date()) {
        guard let verifier else { state = .unconfigured; return }
        guard !storageFailed else { state = .blocked(lastError ?? "无法读取授权"); return }
        guard !record.serverBlocked else { state = .blocked(lastError ?? "授权已失效，请重新激活或联系管理员。"); return }
        let effective = effectiveNow(now: now)
        record.lastSeen = effective.timeIntervalSince1970
        do { try persist() }
        catch { failStorage(error); return }
        guard let lease = record.lease else { state = .needsConnection; return }
        do {
            let payload = try verifier.verify(lease, productId: productId, deviceId: deviceId)
            state = effective < payload.deadline ? .active(payload) : .expired
        } catch {
            lastError = error.localizedDescription
            state = .blocked(error.localizedDescription)
        }
    }

    public func start() async {
        checkAccess()
        guard verifier != nil, !storageFailed else { return }
        do {
            if record.deviceToken != nil { try await refreshOnline() }
            else if !record.serverBlocked { try await requestTrial() }
        } catch { lastError = error.localizedDescription }
    }

    public func requestTrial() async throws {
        try beginRequest()
        defer { isBusy = false }
        do { try accept(await api.trial(productId: productId, deviceId: deviceId, deviceName: deviceName)) }
        catch { lastError = error.localizedDescription; checkAccess(); throw error }
    }

    public func activate(code: String) async throws {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.uppercased().hasPrefix("XNK1") else { throw SoftwareLicenseError.legacyCode }
        guard !code.isEmpty, code.count <= 512 else { throw SoftwareLicenseError.invalidLease }
        try beginRequest()
        defer { isBusy = false }
        do { try accept(await api.activate(productId: productId, deviceId: deviceId, deviceName: deviceName, code: code)) }
        catch { lastError = error.localizedDescription; checkAccess(); throw error }
    }

    public func refreshOnline() async throws {
        guard let token = record.deviceToken else { throw SoftwareLicenseError.expired }
        try beginRequest()
        defer { isBusy = false }
        do { try accept(await api.refresh(productId: productId, deviceId: deviceId, deviceToken: token)) }
        catch {
            lastError = error.localizedDescription
            // 明确撤销/解绑后停止离线放行；暂时网络错误保留仍有效的租约。
            if case SoftwareLicenseError.server(let status, _, _) = error,
               [401, 403, 404, 410].contains(status) {
                record.serverBlocked = true
                do { try persist() } catch { failStorage(error) }
            }
            checkAccess()
            throw error
        }
    }

    public func deactivate() async throws {
        guard let token = record.deviceToken else { return }
        try beginRequest()
        defer { isBusy = false }
        do {
            try await api.deactivate(productId: productId, deviceId: deviceId, deviceToken: token)
            record.lease = nil
            record.deviceToken = nil
            record.serverBlocked = true
            try persist()
            lastError = nil
            state = .needsConnection
        } catch { lastError = error.localizedDescription; throw error }
    }

    private func beginRequest() throws {
        guard verifier != nil else { throw SoftwareLicenseError.unconfigured }
        guard !isBusy else { throw SoftwareLicenseError.busy }
        guard !storageFailed else { throw SoftwareLicenseError.storage(-1) }
        isBusy = true
    }

    private func accept(_ response: SoftwareLicenseResponse) throws {
        guard let verifier else { throw SoftwareLicenseError.unconfigured }
        let payload = try verifier.verify(response.lease, productId: productId, deviceId: deviceId)
        // 只有新近的已验签 HTTPS 响应可校正历史误设的未来时间；离线缓存仍单调验期。
        let localNow = Date().timeIntervalSince1970
        guard abs(localNow - payload.issuedAt) <= 300 else {
            throw SoftwareLicenseError.server(status: 422, code: "clock_mismatch",
                message: "本机时间与授权服务器不一致，请校准系统时间后重试。")
        }
        let now = max(localNow, payload.issuedAt)
        guard now < payload.deadline.timeIntervalSince1970 else { throw SoftwareLicenseError.expired }
        let updated = Record(lease: response.lease, deviceToken: response.deviceToken, lastSeen: now)
        // 先安全落盘再放行，避免用户看到成功但重启丢失凭证。
        try store.save(JSONEncoder().encode(updated))
        record = updated
        anchorTime = now
        anchorUptime = ProcessInfo.processInfo.systemUptime
        lastError = nil
        state = .active(payload)
    }

    private func persist() throws { try store.save(JSONEncoder().encode(record)) }
    private func failStorage(_ error: Error) {
        storageFailed = true
        lastError = error.localizedDescription
        state = .blocked(error.localizedDescription)
    }
}
