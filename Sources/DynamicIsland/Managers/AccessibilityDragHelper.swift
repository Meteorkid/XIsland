import AppKit
import SwiftUI

/// 让「拖进系统设置」只剩一步。
///
/// 系统设置一打开就会盖住主窗口，用户要么先挪窗、要么找不到拖拽源。
/// 这里在系统设置窗口旁边浮起一个小面板（非激活、置顶、跟随所有桌面），
/// 里面就是可拖拽的应用图标与提示语；拖到授权列表即可完成添加。
@MainActor
final class AccessibilityDragHelper {
    static let shared = AccessibilityDragHelper()

    private var panel: NSPanel?
    private var pendingTask: Task<Void, Never>?

    /// 打开辅助功能分页，等系统设置出窗口后把拖拽面板贴到它左侧。
    func present() {
        SystemPrivacySettings.openAccessibility()
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            // 系统设置冷启动可能要一两秒，多试几次再定位；找不到就放到屏幕右上角。
            for attempt in 0..<6 {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 500 : 350))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let frame = Self.systemSettingsFrame() {
                    self.show(near: frame)
                    return
                }
            }
            self?.show(near: nil)
        }
    }

    func close() {
        pendingTask?.cancel()
        pendingTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func show(near settingsFrame: CGRect?) {
        let host = NSHostingView(rootView: PermissionDragChip(
            target: L10n.permissionAccessibility,
            onDragEnded: { [weak self] in self?.close() },
            onClose: { [weak self] in self?.close() }
        ))
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        let size = CGSize(width: 560, height: max(96, min(170, fitted.height)))
        let frame = CGRect(origin: Self.origin(near: settingsFrame, size: size), size: size)

        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
            // 关闭整窗拖动：否则按在条目上会被系统当成拖窗口，应用文件反而拖不出去。
            panel.isMovableByWindowBackground = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        // 每次重建内容，面板尺寸跟着内容贴合。
        panel.contentView = host
        panel.setContentSize(size)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    // MARK: - 定位

    /// 系统设置主窗口的位置（CGWindowList 是左上原点，这里换算成 Cocoa 的左下原点）。
    static func systemSettingsFrame() -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let names: Set<String> = ["System Settings", "系统设置"]
        var best: CGRect?
        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String, names.contains(owner),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 420, rect.height >= 320 else { continue }
            if best == nil || rect.width * rect.height > best!.width * best!.height { best = rect }
        }
        guard let rect = best else { return nil }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func origin(near settingsFrame: CGRect?, size: CGSize) -> CGPoint {
        let screen = (settingsFrame.flatMap { frame in
            NSScreen.screens.first { $0.frame.intersects(frame) }
        } ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        guard let settingsFrame else {
            return CGPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 120)
        }
        // 横向条放在系统设置下方居中，提示语指向“上方列表”；下方放不下时改放上方。
        let x = min(max(screen.minX + 12, settingsFrame.midX - size.width / 2),
                    screen.maxX - size.width - 12)
        let below = settingsFrame.minY - size.height - 12
        if below >= screen.minY + 12 {
            return CGPoint(x: x, y: below)
        }
        return CGPoint(x: x, y: min(settingsFrame.maxY + 12, screen.maxY - size.height - 12))
    }
}

/// 浮动在系统设置旁边的拖拽条：一行说明 + 一条可拖动的应用条目。
struct PermissionDragChip: View {
    let target: String
    let onDragEnded: () -> Void
    let onClose: () -> Void

    private var appName: String { Bundle.main.bundleURL.lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.blue)
            Text(String(format: L10n.permissionDragBannerHint, appName))
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.permissionDragFallbackHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.permissionDragClose)
            }

            DraggableAppBar(bundleURL: Bundle.main.bundleURL,
                            title: String(format: L10n.permissionDragBarTitle, appName),
                            height: 44,
                            onDragEnded: onDragEnded)
                .frame(height: 44)
        }
        .padding(14)
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}

/// 可拖拽的应用图标：拖出来就是 `.app` 文件本身（`public.file-url`）。
struct DraggableAppIcon: NSViewRepresentable {
    var bundleURL: URL = Bundle.main.bundleURL
    var side: CGFloat = 52
    var onDragEnded: (() -> Void)?

    func makeNSView(context: Context) -> AppIconDragView {
        let view = AppIconDragView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.bundleURL = bundleURL
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: AppIconDragView, context: Context) {
        nsView.bundleURL = bundleURL
        nsView.onDragEnded = onDragEnded
        if nsView.frame.size != NSSize(width: side, height: side) {
            nsView.setFrameSize(NSSize(width: side, height: side))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AppIconDragView, context: Context) -> CGSize? {
        CGSize(width: side, height: side)
    }
}

final class AppIconDragView: NSView, NSDraggingSource {
    var bundleURL: URL = Bundle.main.bundleURL {
        didSet { needsDisplay = true }
    }

    var onDragEnded: (() -> Void)?

    private var mouseDownEvent: NSEvent?
    private var hasStartedDrag = false

    private var displayIcon: NSImage {
        bundleURL.pathExtension == "app"
            ? NSWorkspace.shared.icon(forFile: bundleURL.path)
            : NSApp.applicationIconImage
    }

    override func draw(_ dirtyRect: NSRect) {
        displayIcon.draw(in: bounds)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    /// 非激活面板必须接受首次点击，否则第一次按下只会激活窗口，看起来像「拖不动」。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        hasStartedDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !hasStartedDrag, let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard (dx * dx + dy * dy).squareRoot() > 3 else { return }
        hasStartedDrag = true

        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: displayIcon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        hasStartedDrag = false
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        hasStartedDrag = false
        // 只有真正被接收才收起浮窗；拖到空白处取消时保留，方便再试一次。
        if operation != [] { onDragEnded?() }
    }
}

/// 整条可拖的应用条目：自定义 NSView 持有拖拽会话，避免被窗口背景拖动抢走事件。
struct DraggableAppBar: NSViewRepresentable {
    var bundleURL: URL = Bundle.main.bundleURL
    var title: String
    var height: CGFloat = 44
    var onDragEnded: (() -> Void)?

    func makeNSView(context: Context) -> AppDragBarView {
        let view = AppDragBarView(frame: NSRect(x: 0, y: 0, width: 400, height: height))
        view.bundleURL = bundleURL
        view.title = title
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: AppDragBarView, context: Context) {
        nsView.bundleURL = bundleURL
        nsView.title = title
        nsView.onDragEnded = onDragEnded
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AppDragBarView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: height)
    }
}

final class AppDragBarView: NSView, NSDraggingSource {
    var bundleURL: URL = Bundle.main.bundleURL {
        didSet { needsDisplay = true }
    }
    var title: String = "" {
        didSet { needsDisplay = true }
    }
    var onDragEnded: (() -> Void)?

    private var mouseDownEvent: NSEvent?
    private var hasStartedDrag = false
    private var isHovered = false
    private var trackingAreaRef: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(isHovered ? 0.12 : 0.08).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 1
        path.stroke()

        let side: CGFloat = 26
        let iconRect = NSRect(x: 12, y: (bounds.height - side) / 2, width: side, height: side)
        NSWorkspace.shared.icon(forFile: bundleURL.path).draw(in: iconRect)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let text = title as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: iconRect.maxX + 10, y: bounds.midY - textSize.height / 2),
                  withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        hasStartedDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !hasStartedDrag, let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard (dx * dx + dy * dy).squareRoot() > 3 else { return }
        hasStartedDrag = true

        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: bundleURL.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        hasStartedDrag = false
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        hasStartedDrag = false
        if operation != [] { onDragEnded?() }
    }
}
