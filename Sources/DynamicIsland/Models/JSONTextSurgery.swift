import Foundation

/// 在 JSON / JSONC 文本上做最小改动：只替换**顶层**某个键的值，其余字节原样保留。
///
/// 为什么需要它：`JSONSerialization` 重写会按自己的规则重新序列化，
/// 注释、键序、缩进全部丢失。用户配置文件里的注释是他自己写的，不该被工具改掉。
///
/// 能力边界（刻意做窄）：
/// - 只处理顶层对象的键，不进入嵌套
/// - 只做"替换已有键的值"，新增键返回 nil 交给调用方全量重写
/// - 任何解析上的不确定都返回 nil，不猜
enum JSONTextSurgery {

    /// 文本里是否含 JSONC 注释（字符串之外）。
    static func containsComments(_ text: String) -> Bool {
        let chars = Array(text)
        var i = 0
        var inString = false
        var escaped = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"": inString = true; i += 1
            case "/" where i + 1 < chars.count && chars[i + 1] == "/": return true
            case "/" where i + 1 < chars.count && chars[i + 1] == "*": return true
            default: i += 1
            }
        }
        return false
    }

    /// 去掉注释，用于校验替换结果仍是合法 JSON。字符串内部的 `//` 不受影响。
    static func strippingComments(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        var inString = false
        var escaped = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count {
                if chars[i + 1] == "/" {
                    i += 2
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                if chars[i + 1] == "*" {
                    i += 2
                    while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                    i = min(i + 2, chars.count)
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// 把顶层 `key` 的值替换为 `rendered`。找不到该键或结构不符合预期时返回 nil。
    ///
    /// `rendered` 必须是合法的 JSON 值文本（由调用方序列化产生）。
    static func replaceTopLevelValue(in text: String, key: String,
                                     with rendered: String) -> String? {
        let chars = Array(text)
        var i = 0

        skipTrivia(chars, &i)
        guard i < chars.count, chars[i] == "{" else { return nil }
        i += 1

        while i < chars.count {
            skipTrivia(chars, &i)
            guard i < chars.count else { return nil }

            switch chars[i] {
            case "}":
                // 顶层对象已结束，键不存在。
                return nil
            case ",":
                i += 1
                continue
            case "\"":
                break
            default:
                return nil
            }

            guard let (name, afterKey) = readString(chars, from: i) else { return nil }
            var j = afterKey
            skipTrivia(chars, &j)
            guard j < chars.count, chars[j] == ":" else { return nil }
            j += 1
            skipTrivia(chars, &j)

            let valueStart = j
            guard let valueEnd = skipValue(chars, from: j) else { return nil }

            if name == key {
                var out = String(chars[0..<valueStart])
                out += rendered
                out += String(chars[valueEnd...])
                return out
            }
            i = valueEnd
        }
        return nil
    }

    // MARK: - 扫描

    private static func skipTrivia(_ chars: [Character], _ i: inout Int) {
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "/", i + 1 < chars.count {
                if chars[i + 1] == "/" {
                    i += 2
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                if chars[i + 1] == "*" {
                    i += 2
                    while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                    i = min(i + 2, chars.count)
                    continue
                }
            }
            return
        }
    }

    /// 读取一个 JSON 字符串字面量，返回解码后的内容与结束位置（右引号之后）。
    private static func readString(_ chars: [Character], from start: Int) -> (String, Int)? {
        guard start < chars.count, chars[start] == "\"" else { return nil }
        var i = start + 1
        var result = ""
        var escaped = false
        while i < chars.count {
            let c = chars[i]
            if escaped { result.append(c); escaped = false; i += 1; continue }
            if c == "\\" { escaped = true; i += 1; continue }
            if c == "\"" { return (result, i + 1) }
            result.append(c)
            i += 1
        }
        return nil
    }

    /// 跳过一个 JSON 值，返回其结束位置（不含）。
    private static func skipValue(_ chars: [Character], from start: Int) -> Int? {
        guard start < chars.count else { return nil }
        switch chars[start] {
        case "\"":
            return readString(chars, from: start)?.1
        case "{", "[":
            let (open, close): (Character, Character) = chars[start] == "{" ? ("{", "}") : ("[", "]")
            var depth = 0
            var i = start
            while i < chars.count {
                let c = chars[i]
                if c == "\"" {
                    guard let (_, next) = readString(chars, from: i) else { return nil }
                    i = next
                    continue
                }
                if c == "/" , i + 1 < chars.count,
                   chars[i + 1] == "/" || chars[i + 1] == "*" {
                    var k = i
                    skipTrivia(chars, &k)
                    i = k
                    continue
                }
                if c == open { depth += 1 }
                if c == close {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return nil
        default:
            // 数字、true/false/null：读到分隔符为止。
            var i = start
            while i < chars.count {
                let c = chars[i]
                if c == "," || c == "}" || c == "]" || c.isWhitespace { return i }
                i += 1
            }
            return i
        }
    }
}
