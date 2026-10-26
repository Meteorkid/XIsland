import AppKit

struct IslandSwitchColor: Equatable, Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    var isValid: Bool {
        [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

/// 外壳的 AppKit 屏幕坐标，不包含窗口顶部为命中扩展的区域。
struct IslandSwitchGeometry: Equatable, Sendable {
    let frame: CGRect
    let displayID: UInt32
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    let fill: IslandSwitchColor

    init?(frame: CGRect, displayID: UInt32, topRadius: CGFloat, bottomRadius: CGFloat,
          fill: IslandSwitchColor) {
        self.frame = frame
        self.displayID = displayID
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
        self.fill = fill
        guard isValid else { return nil }
    }

    var isValid: Bool {
        let values = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, topRadius, bottomRadius]
        guard values.allSatisfy(\.isFinite), abs(frame.origin.x) <= 100_000,
              abs(frame.origin.y) <= 100_000, frame.size.width > 0, frame.size.width <= 4096,
              frame.size.height > 0, frame.size.height <= 2048, displayID > 0, fill.isValid else { return false }
        let maximumRadius = min(frame.width / 2, frame.height)
        return (0...maximumRadius).contains(topRadius) && (0...maximumRadius).contains(bottomRadius)
    }

    fileprivate static let suffixes = ["X", "Y", "Width", "Height", "DisplayID", "TopRadius", "BottomRadius",
                                       "Red", "Green", "Blue", "Alpha"]

    fileprivate func fields(prefix: String) -> [String: String] {
        let values: [(String, CGFloat)] = [
            ("X", frame.origin.x), ("Y", frame.origin.y), ("Width", frame.width), ("Height", frame.height),
            ("TopRadius", topRadius), ("BottomRadius", bottomRadius),
            ("Red", fill.red), ("Green", fill.green), ("Blue", fill.blue), ("Alpha", fill.alpha),
        ]
        var fields = Dictionary(uniqueKeysWithValues: values.map { (prefix + $0.0, String(Double($0.1))) })
        fields[prefix + "DisplayID"] = String(displayID)
        return fields
    }

    fileprivate static func decode(fields: [String: String], prefix: String) throws -> Self? {
        let present = suffixes.filter { fields[prefix + $0] != nil }
        guard !present.isEmpty else { return nil }
        guard present.count == suffixes.count else { throw IslandSwitchMotion.DecodeError.invalidMotion }
        func value(_ suffix: String) -> CGFloat? {
            guard let raw = fields[prefix + suffix], let number = Double(raw), number.isFinite else { return nil }
            return CGFloat(number)
        }
        guard let x = value("X"), let y = value("Y"), let width = value("Width"), let height = value("Height"),
              let rawDisplayID = fields[prefix + "DisplayID"], let displayID = UInt32(rawDisplayID),
              let topRadius = value("TopRadius"), let bottomRadius = value("BottomRadius"),
              let red = value("Red"), let green = value("Green"), let blue = value("Blue"), let alpha = value("Alpha"),
              let geometry = Self(frame: CGRect(x: x, y: y, width: width, height: height), displayID: displayID,
                                  topRadius: topRadius, bottomRadius: bottomRadius,
                                  fill: IslandSwitchColor(red: red, green: green, blue: blue, alpha: alpha))
        else { throw IslandSwitchMotion.DecodeError.invalidMotion }
        return geometry
    }
}

/// /show 的可选方向信息；旧版本忽略这些参数后仍能安全显示目标岛。
struct IslandSwitchMotion: Equatable, Sendable {
    let requestID: UUID
    let direction: SwipeDirection
    let reduceMotion: Bool
    let issuedUptime: TimeInterval
    let startUptime: TimeInterval?
    let sourceGeometry: IslandSwitchGeometry?
    let targetGeometry: IslandSwitchGeometry?

    init(requestID: UUID = UUID(), direction: SwipeDirection, reduceMotion: Bool,
         issuedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
         startUptime: TimeInterval? = nil, sourceGeometry: IslandSwitchGeometry? = nil,
         targetGeometry: IslandSwitchGeometry? = nil) {
        self.requestID = requestID; self.direction = direction; self.reduceMotion = reduceMotion
        self.issuedUptime = issuedUptime; self.startUptime = startUptime
        self.sourceGeometry = sourceGeometry; self.targetGeometry = targetGeometry
    }

    func starting(at uptime: TimeInterval, reduceMotion locallyReduced: Bool) -> Self {
        Self(requestID: requestID, direction: direction, reduceMotion: reduceMotion || locallyReduced,
             issuedUptime: issuedUptime, startUptime: uptime,
             sourceGeometry: sourceGeometry, targetGeometry: targetGeometry)
    }

    func arriving(at geometry: IslandSwitchGeometry?) -> Self {
        Self(requestID: requestID, direction: direction, reduceMotion: reduceMotion,
             issuedUptime: issuedUptime, startUptime: startUptime,
             sourceGeometry: sourceGeometry, targetGeometry: geometry)
    }

    func isTimely(at uptime: TimeInterval) -> Bool {
        guard uptime.isFinite, issuedUptime.isFinite, issuedUptime >= 0,
              issuedUptime <= uptime + 0.25, uptime - issuedUptime <= 10 else { return false }
        guard let startUptime else { return true }
        return startUptime.isFinite && startUptime >= issuedUptime
            && startUptime <= uptime + 0.25 && uptime - startUptime <= 1
    }

    private var fields: [String: String] {
        var result = ["slideVersion": "1", "handoffID": requestID.uuidString,
                      "slideDirection": direction.rawValue, "slideReduceMotion": reduceMotion ? "1" : "0",
                      "slideIssuedAt": String(issuedUptime)]
        if let startUptime { result["slideStartAt"] = String(startUptime) }
        sourceGeometry?.fields(prefix: "slideSource").forEach { result[$0.key] = $0.value }
        targetGeometry?.fields(prefix: "slideTarget").forEach { result[$0.key] = $0.value }
        return result
    }

    var userInfo: [String: String] { fields }

    func adding(to url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let existing = components.queryItems ?? []
        guard !existing.contains(where: { Self.keys.contains($0.name) }) else { return nil }
        components.queryItems = existing + fields.keys.sorted().map { URLQueryItem(name: $0, value: fields[$0]) }
        return components.url
    }

    enum DecodeError: Error { case invalidMotion }
    private static let keys: Set<String> = Set([
        "slideVersion", "handoffID", "slideDirection", "slideReduceMotion", "slideIssuedAt", "slideStartAt",
    ] + ["slideSource", "slideTarget"].flatMap { prefix in
        IslandSwitchGeometry.suffixes.map { prefix + $0 }
    })

    static func decode(url: URL) throws -> Self? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let motionItems = items.filter { keys.contains($0.name) }
        guard !motionItems.isEmpty else { return nil }
        var fields: [String: String] = [:]
        for item in motionItems {
            guard fields[item.name] == nil, let value = item.value else { throw DecodeError.invalidMotion }
            fields[item.name] = value
        }
        return try decode(fields: fields)
    }

    static func decode(userInfo: [AnyHashable: Any]?) throws -> Self? {
        guard let userInfo, keys.contains(where: { userInfo[$0] != nil }) else { return nil }
        var fields: [String: String] = [:]
        for key in keys where userInfo[key] != nil {
            guard let value = userInfo[key] as? String else { throw DecodeError.invalidMotion }
            fields[key] = value
        }
        return try decode(fields: fields)
    }

    private static func decode(fields: [String: String]) throws -> Self {
        guard fields["slideVersion"] == "1", let rawID = fields["handoffID"], rawID.count == 36,
              let id = UUID(uuidString: rawID), let rawDirection = fields["slideDirection"],
              let direction = SwipeDirection(rawValue: rawDirection), let rawReduced = fields["slideReduceMotion"],
              ["0", "1"].contains(rawReduced), let rawIssued = fields["slideIssuedAt"],
              let issued = Double(rawIssued), issued.isFinite, issued >= 0 else { throw DecodeError.invalidMotion }
        let start: TimeInterval?
        if let rawStart = fields["slideStartAt"] {
            guard let value = Double(rawStart), value.isFinite, value >= issued else { throw DecodeError.invalidMotion }
            start = value
        } else { start = nil }
        return try Self(requestID: id, direction: direction, reduceMotion: rawReduced == "1",
                        issuedUptime: issued, startUptime: start,
                        sourceGeometry: IslandSwitchGeometry.decode(fields: fields, prefix: "slideSource"),
                        targetGeometry: IslandSwitchGeometry.decode(fields: fields, prefix: "slideTarget"))
    }
}
