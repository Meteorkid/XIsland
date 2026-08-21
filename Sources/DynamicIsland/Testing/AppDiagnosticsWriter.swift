import Foundation

/// 把 `AppDiagnosticsSnapshot` 落盘，供 UI 测试读取诊断结果。
///
/// 固定使用 `prettyPrinted` + `sortedKeys`，保证多次生成的内容逐字节稳定，
/// 便于测试断言与人工 diff；写入采用原子替换，避免读到半截文件。
struct AppDiagnosticsWriter {
    let outputURL: URL

    /// 共享的编码器：稳定排序 + 可读缩进。
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func write(_ snapshot: AppDiagnosticsSnapshot) throws {
        try ensureParentDirectoryExists()
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: outputURL, options: .atomic)
    }

    /// 预先创建输出文件所在的父目录（含中间层级）。
    private func ensureParentDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
