import AppKit

@MainActor
protocol LinkedIslandPreviewPresenting: AnyObject {
    var currentDistance: CGFloat { get }
    var viewportScreenFrame: CGRect { get }
    func update(distance: CGFloat)
    func settle(targetDistance: CGFloat, duration: TimeInterval, completion: @escaping @MainActor () -> Void)
    func fadeOut(duration: TimeInterval, completion: @escaping @MainActor () -> Void)
    func close()
}

extension LinkedIslandPreviewCanvas: LinkedIslandPreviewPresenting {}

/// 手势只由来源进程拥有；对端准备只读快照，真正显示仍走既有可见性确认。
@MainActor
final class LinkedIslandPreviewController {
    enum Phase: Equatable {
        case idle, preparing, unavailable, tracking, returning, settlingForward, committing, finishing
    }

    struct Environment {
        var requestTarget: (@escaping @MainActor (IslandPreviewSnapshot?) -> Void) -> (() -> Void)?
        var captureSource: () -> IslandPreviewSnapshot?
        var makeCanvas: (IslandPreviewSnapshot, IslandPreviewSnapshot) -> (any LinkedIslandPreviewPresenting)?
        var hideLiveContent: (Bool) -> Void
        var blockInteraction: (Bool) -> Void
        var switchToPeer: (SwipeDirection, Bool) -> Void
        var peerIsVisible: () -> Bool
        var didFinish: () -> Void
        var cancelCommit: () -> Void = {}
        var yieldToVisiblePeer: () -> Void = {}
        var sourceContextIsValid: (IslandPreviewSnapshot) -> Bool = { _ in true }
        var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    }

    private let environment: Environment
    private(set) var phase: Phase = .idle
    private var generation: UInt64 = 0
    private var cancelRequest: (() -> Void)?
    private var canvas: (any LinkedIslandPreviewPresenting)?
    private var sourceWidth: CGFloat = 0
    private var targetWidth: CGFloat = 0
    private var sourceContext: IslandPreviewSnapshot?
    private var gestureOrigin: CGFloat = 0
    private var lastTranslation: CGFloat = 0
    private var pendingCommit: SwipeDirection?
    private var finishNotified = true
    private var lastPeerVisibilityCheck: TimeInterval?

    init(environment: Environment) { self.environment = environment }

    var isActive: Bool { phase != .idle && phase != .unavailable }
    var hitFrame: CGRect? { canvas?.viewportScreenFrame }
    var ownsGesture: Bool {
        pendingCommit == nil && [.preparing, .unavailable, .tracking, .returning, .finishing].contains(phase)
    }

    func beginGesture() {
        if phase == .returning, let canvas {
            generation &+= 1
            gestureOrigin = canvas.currentDistance
            canvas.update(distance: gestureOrigin)
            lastTranslation = 0
            phase = .tracking
            return
        }
        if phase == .tracking, let canvas {
            gestureOrigin = canvas.currentDistance
            lastTranslation = 0
            return
        }
        if phase == .finishing { reset() }
        guard phase == .idle || phase == .unavailable else { return }
        reset()
        phase = .preparing
        finishNotified = false
        environment.blockInteraction(true)
        let token = generation
        cancelRequest = environment.requestTarget { [weak self] snapshot in
            self?.received(snapshot, generation: token)
        }
        if cancelRequest == nil, phase == .preparing { received(nil, generation: token) }
    }

    func update(translation: CGFloat) {
        guard translation.isFinite else { cancel(); return }
        if phase == .idle { beginGesture() }
        lastTranslation = translation
        if phase == .tracking, !hasValidContext { reset(); return }
        if phase == .tracking, !yieldIfPeerBecameVisible() {
            canvas?.update(distance: gestureOrigin + translation)
        }
    }

    func commit(direction: SwipeDirection) {
        switch phase {
        case .preparing:
            pendingCommit = direction
        case .tracking:
            guard hasValidContext else { reset(); return }
            if !yieldIfPeerBecameVisible(force: true) { finishForward(direction) }
        case .unavailable, .idle:
            reset(notify: false)
            environment.switchToPeer(direction, false)
        case .returning, .finishing, .settlingForward, .committing:
            break
        }
    }

    func cancel() {
        guard phase != .idle, phase != .returning, phase != .finishing else { return }
        let wasCommitting = phase == .committing
        generation &+= 1
        cancelRequest?(); cancelRequest = nil
        pendingCommit = nil
        guard let canvas else { reset(); return }
        let token = generation
        phase = .returning
        if wasCommitting {
            environment.cancelCommit()
            environment.blockInteraction(true)
        }
        canvas.settle(targetDistance: 0, duration: 0.22) { [weak self, weak canvas] in
            guard let self, self.generation == token, self.phase == .returning, let canvas else { return }
            self.phase = .finishing
            // 画布在上层保持来源末帧，先恢复背后的真实内容，再渐隐交回。
            self.environment.hideLiveContent(false)
            canvas.fadeOut(duration: 0.08) { [weak self] in
                guard let self, self.generation == token else { return }
                self.reset()
            }
        }
    }

    /// 显式显示/展开等打断预览；隐藏路径必须在原生窗口退出屏幕后调用。
    func reset(afterWindowHidden: Bool = false, notify: Bool = true) {
        let wasCommitting = phase == .committing
        let transferring = afterWindowHidden && phase == .committing && environment.peerIsVisible()
        generation &+= 1
        cancelRequest?(); cancelRequest = nil
        pendingCommit = nil
        let previousCanvas = canvas
        canvas = nil
        phase = .idle
        lastPeerVisibilityCheck = nil
        if wasCommitting && !transferring { environment.cancelCommit() }
        sourceWidth = 0; targetWidth = 0; sourceContext = nil; gestureOrigin = 0; lastTranslation = 0
        environment.hideLiveContent(false)
        environment.blockInteraction(false)
        if transferring, let previousCanvas {
            previousCanvas.fadeOut(duration: 0.08) { previousCanvas.close() }
        } else { previousCanvas?.close() }
        finishAttempt(notify: notify)
    }

    private func finishAttempt(notify: Bool) {
        guard !finishNotified else { return }
        finishNotified = true
        if notify { environment.didFinish() }
    }

    private func received(_ target: IslandPreviewSnapshot?, generation token: UInt64) {
        guard generation == token, phase == .preparing else { return }
        cancelRequest = nil
        if target != nil, yieldIfPeerBecameVisible(force: true) { return }
        guard let target, let source = environment.captureSource(),
              source.outline.displayID == target.outline.displayID,
              environment.sourceContextIsValid(source),
              let canvas = environment.makeCanvas(source, target) else {
            phase = .unavailable
            environment.blockInteraction(false)
            if let direction = pendingCommit {
                pendingCommit = nil
                commit(direction: direction)
            } else { finishAttempt(notify: true) }
            return
        }
        self.canvas = canvas
        sourceContext = source
        sourceWidth = source.frame.width
        targetWidth = target.frame.width
        phase = .tracking
        // p=0 的画布与来源快照相同，目标窗口仍隐藏；不再搬动真实HostingView。
        canvas.update(distance: 0)
        environment.hideLiveContent(true)
        if let direction = pendingCommit {
            pendingCommit = nil
            finishForward(direction)
        } else { canvas.update(distance: gestureOrigin + lastTranslation) }
    }

    private var hasValidContext: Bool {
        sourceContext.map(environment.sourceContextIsValid) ?? false
    }

    private func yieldIfPeerBecameVisible(force: Bool = false) -> Bool {
        guard canvas != nil || phase == .preparing else { return false }
        let now = environment.uptime()
        if !force, let last = lastPeerVisibilityCheck, now.isFinite, now >= last, now - last < 0.1 { return false }
        lastPeerVisibilityCheck = now.isFinite ? now : nil
        guard environment.peerIsVisible() else { return false }
        generation &+= 1
        phase = .committing
        // 对端主动显示（例如优先交互）时让位，不能继续用快照覆盖它。
        environment.yieldToVisiblePeer()
        return true
    }

    private func finishForward(_ direction: SwipeDirection) {
        guard let canvas, phase == .tracking else { return }
        phase = .settlingForward
        let token = generation
        let destination = direction == .left ? -sourceWidth : targetWidth
        canvas.settle(targetDistance: destination, duration: 0.26) { [weak self] in
            guard let self, self.generation == token, self.phase == .settlingForward else { return }
            guard self.hasValidContext else { self.reset(); return }
            if self.yieldIfPeerBecameVisible(force: true) { return }
            self.phase = .committing
            // 真实窗口只接管已完成的画面，不能再播放第二次滑入/滑出。
            self.environment.switchToPeer(direction, true)
        }
    }
}
