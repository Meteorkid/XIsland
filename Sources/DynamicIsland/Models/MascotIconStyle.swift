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
enum CustomMascotStore {
    private static var cached: NSImage?
    private static var cachedModification: Date?

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
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: fileURL, options: .atomic)
        cached = image
        cachedModification = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        cached = nil
        cachedModification = nil
    }
}
