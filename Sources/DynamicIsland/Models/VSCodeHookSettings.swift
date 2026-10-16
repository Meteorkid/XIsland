import Foundation

/// 只编辑目标字段的 token，原有注释、空白和换行均保留。
enum VSCodeHookSettings {
    enum ConfigurationError: Error, Equatable {
        case invalidJSONC(Int)
        case rootMustBeObject
        case duplicateKey(String)
        case invalidLocations
        case userDisabled(String)
    }

    private static let setting = "chat.hookFilesLocations"

    static func registering(in source: String, hookPath: String) throws -> String {
        var parser = Parser(source)
        let root = try parser.root()
        if let locations = try locations(in: root) {
            if let existing = locations.members.first(where: { $0.key == hookPath }) {
                guard case .boolean(true) = existing.value.kind else {
                    throw ConfigurationError.userDisabled(hookPath)
                }
                return source
            }
            return try inserting(quoted(hookPath) + ": true", into: locations, source: source)
        }
        return try inserting(quoted(setting) + ": {" + quoted(hookPath) + ": true}", into: root, source: source)
    }

    static func removing(from source: String, hookPath: String) throws -> String {
        var parser = Parser(source)
        let root = try parser.root()
        guard let locations = try locations(in: root),
              let index = locations.members.firstIndex(where: { $0.key == hookPath }) else { return source }
        let member = locations.members[index]
        // 分别删除语法 token，避免连带删除键、冒号和值之间的用户注释。
        var ranges = [member.keyRange, member.colon..<(member.colon + 1), member.value.range]
        if let comma = member.comma { ranges.append(comma..<(comma + 1)) }
        else if index > 0, let comma = locations.members[index - 1].comma { ranges.append(comma..<(comma + 1)) }
        var bytes = Array(source.utf8)
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) { bytes.removeSubrange(range) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func isRegistered(in source: String, hookPath: String) -> Bool {
        var parser = Parser(source)
        guard let root = try? parser.root(), let locations = try? locations(in: root),
              let member = locations.members.first(where: { $0.key == hookPath }),
              case .boolean(true) = member.value.kind else { return false }
        return true
    }

    private static func locations(in root: Object) throws -> Object? {
        guard let member = root.members.first(where: { $0.key == setting }) else { return nil }
        guard case let .object(object) = member.value.kind,
              object.members.allSatisfy({ if case .boolean = $0.value.kind { return true }; return false }) else {
            throw ConfigurationError.invalidLocations
        }
        return object
    }

    private static func quoted(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func inserting(_ entry: String, into object: Object, source: String) throws -> String {
        var bytes = Array(source.utf8)
        var prefix = ""
        if bytes[object.range].contains(10) || bytes[object.range].contains(13) {
            let newline = source.contains("\r\n") ? "\r\n" : (source.contains("\n") ? "\n" : "\r")
            let keyOffset = object.members.first?.keyRange.lowerBound
            let indentation = keyOffset.map { lineIndent(at: $0, bytes: bytes) }
                ?? (lineIndent(at: object.range.lowerBound, bytes: bytes) + "  ")
            prefix = newline + indentation
        }
        let insertion = prefix + entry + (object.members.isEmpty ? "" : ",")
        bytes.insert(contentsOf: insertion.utf8, at: object.range.lowerBound + 1)
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func lineIndent(at offset: Int, bytes: [UInt8]) -> String {
        var start = offset
        while start > 0, bytes[start - 1] != 10, bytes[start - 1] != 13 { start -= 1 }
        var end = start
        while end < offset, bytes[end] == 32 || bytes[end] == 9 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private struct Object {
        let range: Range<Int>
        let members: [Member]
    }

    private struct Member {
        let key: String
        let keyRange: Range<Int>
        let colon: Int
        let value: Value
        var comma: Int?
    }

    private struct Value {
        indirect enum Kind { case object(Object), boolean(Bool), other }
        let range: Range<Int>
        let kind: Kind
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        init(_ source: String) { bytes = Array(source.utf8) }

        mutating func root() throws -> Object {
            try trivia()
            guard peek == 123 else { throw ConfigurationError.rootMustBeObject }
            let value = try value(depth: 0)
            try trivia()
            guard position == bytes.count, case let .object(object) = value.kind else { throw invalid() }
            return object
        }

        private var peek: UInt8? { position < bytes.count ? bytes[position] : nil }
        private func invalid() -> ConfigurationError { .invalidJSONC(position) }

        private mutating func trivia() throws {
            while let byte = peek {
                if [9, 10, 13, 32].contains(byte) { position += 1; continue }
                guard byte == 47, position + 1 < bytes.count else { return }
                if bytes[position + 1] == 47 {
                    position += 2
                    while let byte = peek, byte != 10, byte != 13 { position += 1 }
                } else if bytes[position + 1] == 42 {
                    position += 2
                    while position + 1 < bytes.count, !(bytes[position] == 42 && bytes[position + 1] == 47) { position += 1 }
                    guard position + 1 < bytes.count else { throw invalid() }
                    position += 2
                } else { return }
            }
        }

        private mutating func value(depth: Int) throws -> Value {
            guard depth < 128 else { throw invalid() }
            try trivia()
            guard let byte = peek else { throw invalid() }
            let start = position
            let kind: Value.Kind
            switch byte {
            case 123:
                position += 1
                var members: [Member] = []
                var keys: Set<String> = []
                try trivia()
                while peek != 125 {
                    let keyStart = position
                    let key = try string()
                    let keyRange = keyStart..<position
                    guard keys.insert(key).inserted else { throw ConfigurationError.duplicateKey(key) }
                    try trivia()
                    guard peek == 58 else { throw invalid() }
                    let colon = position
                    position += 1
                    let child = try value(depth: depth + 1)
                    try trivia()
                    var member = Member(key: key, keyRange: keyRange, colon: colon, value: child)
                    if peek == 44 { member.comma = position; position += 1; try trivia() }
                    else if peek != 125 { throw invalid() }
                    members.append(member)
                }
                position += 1
                kind = .object(Object(range: start..<position, members: members))
            case 91:
                position += 1
                try trivia()
                while peek != 93 {
                    _ = try value(depth: depth + 1)
                    try trivia()
                    if peek == 44 { position += 1; try trivia() }
                    else if peek != 93 { throw invalid() }
                }
                position += 1
                kind = .other
            case 34: _ = try string(); kind = .other
            case 116: try literal("true"); kind = .boolean(true)
            case 102: try literal("false"); kind = .boolean(false)
            case 110: try literal("null"); kind = .other
            case 45, 48...57: try number(); kind = .other
            default: throw invalid()
            }
            return Value(range: start..<position, kind: kind)
        }

        private mutating func string() throws -> String {
            guard peek == 34 else { throw invalid() }
            let start = position
            position += 1
            while let byte = peek {
                position += 1
                if byte == 92 {
                    guard peek != nil else { throw invalid() }
                    position += 1
                } else if byte == 34 {
                    guard let decoded = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) else { throw invalid() }
                    return decoded
                } else if byte < 32 { throw invalid() }
            }
            throw invalid()
        }

        private mutating func literal(_ text: String) throws {
            let token = Array(text.utf8)
            guard position + token.count <= bytes.count,
                  bytes[position..<(position + token.count)].elementsEqual(token) else { throw invalid() }
            position += token.count
        }

        private mutating func number() throws {
            if peek == 45 { position += 1 }
            if peek == 48 { position += 1 }
            else { try digits() }
            if peek == 46 { position += 1; try digits() }
            if peek == 101 || peek == 69 {
                position += 1
                if peek == 43 || peek == 45 { position += 1 }
                try digits()
            }
        }

        private mutating func digits() throws {
            let start = position
            while let byte = peek, byte >= 48, byte <= 57 { position += 1 }
            guard position > start else { throw invalid() }
        }
    }
}
