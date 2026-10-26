import Foundation
import Darwin

/// 优先提醒作废此前已经投递、尚未显示的切换，避免旧 /show 抢回显示权。
enum IslandAttentionEpoch {
    static let defaultsKey = "island.integration.attentionEpoch"
    private static let initialID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    struct Admission: Equatable {
        let id: UUID
    }

    struct Store {
        let defaults: UserDefaults
        var bootSession: () -> String? = { IslandAttentionEpoch.bootSession }
        var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

        @discardableResult
        func advance() -> Bool {
            let now = uptime()
            guard let boot = bootSession(), now.isFinite, now >= 0 else { return false }
            defaults.set(["id": UUID().uuidString, "boot": boot, "uptime": now], forKey: defaultsKey)
            return defaults.synchronize()
        }

        func capture() -> Admission { Admission(id: current()?.id ?? initialID) }

        func admission(for url: URL, motion: IslandSwitchMotion? = nil) -> Admission? {
            guard url.absoluteString.utf8.count <= 16_384,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            let fields = (components.queryItems ?? []).filter { $0.name.hasPrefix("attention") }
            let current = current()
            if fields.isEmpty {
                // 旧版无方向 URL 没有发出时间，只能兼容；其准备回调仍受下面的世代保护。
                if let current, let motion, motion.issuedUptime <= current.uptime { return nil }
                return Admission(id: current?.id ?? initialID)
            }
            guard fields.count == 2,
                  fields.filter({ $0.name == "attentionVersion" }).count == 1,
                  fields.first(where: { $0.name == "attentionVersion" })?.value == "1",
                  let rawID = fields.first(where: { $0.name == "attentionEpoch" })?.value,
                  rawID.count == 36, let id = UUID(uuidString: rawID),
                  id == (current?.id ?? initialID) else { return nil }
            return Admission(id: id)
        }

        func isCurrent(_ admission: Admission) -> Bool { capture() == admission }

        private func current() -> (id: UUID, uptime: TimeInterval)? {
            // 仅在低频切换边界同步，读取另一进程刚写入的单条记录；不在滑动逐帧路径调用。
            defaults.synchronize()
            guard let record = defaults.dictionary(forKey: defaultsKey), record.count == 3,
                  let rawID = record["id"] as? String, rawID.count == 36,
                  let id = UUID(uuidString: rawID), id != initialID,
                  let boot = record["boot"] as? String, boot == bootSession(),
                  let issued = record["uptime"] as? Double,
                  issued.isFinite, issued >= 0, issued <= uptime() else { return nil }
            return (id, issued)
        }
    }

    static func adding(_ admission: Admission, to url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !(components.queryItems ?? []).contains(where: { $0.name.hasPrefix("attention") }) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "attentionVersion", value: "1"),
            URLQueryItem(name: "attentionEpoch", value: admission.id.uuidString),
        ]
        return components.url
    }

    private static var liveStore: Store { Store(defaults: IslandIntegrationSettings.sharedDefaults) }
    @discardableResult static func advance() -> Bool { liveStore.advance() }
    static func capture() -> Admission { liveStore.capture() }
    static func admission(for url: URL, motion: IslandSwitchMotion? = nil) -> Admission? {
        liveStore.admission(for: url, motion: motion)
    }
    static func isCurrent(_ admission: Admission) -> Bool { liveStore.isCurrent(admission) }

    private static let bootSession: String? = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1, size <= 128 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0,
              let id = UUID(uuidString: String(cString: bytes)) else { return nil }
        return id.uuidString
    }()
}
