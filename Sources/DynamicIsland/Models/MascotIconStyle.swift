import AppKit

/// 收起态/卡片上显示的图标来源。
enum MascotIconStyle: String, CaseIterable, Identifiable {
    /// 自绘吉祥物（默认）
    case mascot
    /// 对应客户端真实的应用图标
    case appLogo
    /// 用户选择的本地图片
    case custom

    var id: String { rawValue }
}

/// 自定义图标的落盘与缓存。
///
/// 图片统一转成 PNG 存在应用支持目录；读取带缓存，避免每次视图重绘都读磁盘。
extension Notification.Name {
    static let customMascotDidChange = Notification.Name("dev.xisland.customMascotDidChange")
}

enum CustomMascotError: LocalizedError {
    case invalidImage
    case imageTooLarge(width: Int, height: Int)
    case encodedImageTooLarge(bytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The image could not be encoded as PNG."
        case .imageTooLarge(let width, let height):
            return "Image is \(width)×\(height); maximum is 4096×4096."
        case .encodedImageTooLarge(let bytes):
            return "PNG is \(bytes) bytes; maximum is 8 MB."
        }
    }
}

enum CustomMascotStore {
    private static var cached: NSImage?
    private static var cachedModification: Date?
    static let maxPixelDimension = 4096
    static let maxEncodedBytes = 8 * 1024 * 1024

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("custom-mascot.png")
    }

    static var image: NSImage? {
        let url = fileURL
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached, cachedModification == modified { return cached }
        let loaded = NSImage(contentsOf: url)
        cached = loaded
        cachedModification = modified
        return loaded
    }

    static func save(_ image: NSImage) throws {
        // 先检查原始位图尺寸，避免在超大的 TIFF 编码阶段就耗尽内存。
        let oversized = image.representations.compactMap { $0 as? NSBitmapImageRep }.first {
            $0.pixelsWide > maxPixelDimension || $0.pixelsHigh > maxPixelDimension
        }
        if let oversized {
            throw CustomMascotError.imageTooLarge(width: oversized.pixelsWide, height: oversized.pixelsHigh)
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw CustomMascotError.invalidImage
        }
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0,
              rep.pixelsWide <= maxPixelDimension, rep.pixelsHigh <= maxPixelDimension else {
            throw CustomMascotError.imageTooLarge(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        guard data.count <= maxEncodedBytes else {
            throw CustomMascotError.encodedImageTooLarge(bytes: data.count)
        }
        try data.write(to: fileURL, options: .atomic)
        cached = image
        cachedModification = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        NotificationCenter.default.post(name: .customMascotDidChange, object: nil)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        cached = nil
        cachedModification = nil
        NotificationCenter.default.post(name: .customMascotDidChange, object: nil)
    }
}
