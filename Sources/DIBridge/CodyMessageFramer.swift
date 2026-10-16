import Foundation

/// Cody vscode-jsonrpc 的 Content-Length 字节帧；异常后停止观察，不猜测重新同步位置。
final class CodyMessageFramer {
    private(set) var stopped = false
    private var header = Data()
    private var body = Data()
    private var remaining: Int?
    private let maximumBody: Int
    private let maximumHeader = 8192

    init(maximumBody: Int = 2_097_152) { self.maximumBody = max(0, maximumBody) }

    func consume(_ data: Data, onFrame: (Data) -> Void) {
        guard !stopped else { return }
        var index = data.startIndex
        while index < data.endIndex {
            if let count = remaining {
                let size = min(count, data.distance(from: index, to: data.endIndex))
                let end = data.index(index, offsetBy: size)
                body.append(contentsOf: data[index..<end])
                index = end
                remaining = count - size
                if remaining == 0 {
                    let frame = body
                    body = Data()
                    remaining = nil
                    onFrame(frame)
                }
            } else {
                header.append(data[index])
                index = data.index(after: index)
                guard header.count <= maximumHeader else { stop(); return }
                if header.suffix(4).elementsEqual([13, 10, 13, 10]) {
                    guard let length = contentLength() else { stop(); return }
                    header = Data()
                    if length == 0 { onFrame(Data()) }
                    else { remaining = length }
                }
            }
        }
    }

    /// EOF 的半包不能作为有效消息交付。
    func finish() {
        if !header.isEmpty || remaining != nil { stop() }
    }

    private func contentLength() -> Int? {
        guard let text = String(data: header.dropLast(4), encoding: .ascii) else { return nil }
        var length: Int?
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                guard length == nil, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let parsed = Int(value), parsed <= maximumBody else { return nil }
                length = parsed
            }
        }
        return length
    }

    private func stop() {
        stopped = true
        header = Data()
        body = Data()
        remaining = nil
    }
}
