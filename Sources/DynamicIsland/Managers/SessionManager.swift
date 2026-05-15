import Foundation
import Observation
import AppKit
import DIShared

@Observable
@MainActor
final class SessionManager {
    var sessions: [AgentSession] = []
    var selectedSessionId: String?
    var audioEngine: AudioEngine?
    var currentIslandState: IslandState = .collapsed
    /// Incremented to force SwiftUI to re-evaluate `visibleSessions` after linger expires.
    var visibleSessionsVersion: Int = 0
    private var cleanupTimer: Timer?
    private var workspaceObserver: Any?

    /// Debounces the "Session complete" (`sessionEnd`) chime when assistant text arrives via `statusUpdate`
    /// (Notification hook) as well as `sessionEnd`, so streaming updates do not spam sounds.
    private var lastAssistantReplySoundAt: [String: TimeInterval] = [:]
    private let assistantReplySoundMinInterval: TimeInterval = 1.8

    /// Caches the last answer per session so that duplicate follow-up events from
    /// agents like OpenCode (same question, same options, fired within 2 seconds)
    /// are auto-replied without re-showing the question panel.
    private struct RecentAnswer {
        let answer: String
        let questionText: String
        let options: Set<String>
        let timestamp: Date
    }
    private var recentAnswers: [String: RecentAnswer] = [:]

    static let idleTimeout: TimeInterval = 120

    var completedLingerDuration: TimeInterval {
        let val = UserDefaults.standard.double(forKey: "completedLingerDuration")
        if val < 0 { return .infinity }
        return val > 0 ? val : 120
    }

    var activeSessions: [AgentSession] {
        sessions.filter { $0.status != .completed }
    }

    /// Among sessions shown in the expanded list (`visibleSessions`), the one that most recently received a message/activity (notch-obscured island leading icon).
    var latestMessagedVisibleSession: AgentSession? {
        visibleSessions.max(by: { $0.lastActivityTime < $1.lastActivityTime })
    }

    /// Active sessions + recently completed sessions that should still be visible in the pill.
    var visibleSessions: [AgentSession] {
        _ = visibleSessionsVersion
        let now = Date()
        return sessions.filter { session in
            if session.status != .completed { return true }
            guard let completedAt = session.completedAt else { return false }
            return now.timeIntervalSince(completedAt) < completedLingerDuration
        }
    }

    func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupStaleSessions()
                self?.checkProcessesAlive()
            }
        }
        observeAppTermination()
    }

    // MARK: - Desktop App Termination

    private func observeAppTermination() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier else { return }
            Task { @MainActor in
                self?.handleAppTerminated(bundleId: bundleId)
            }
        }
    }

    func handleAppTerminated(bundleId: String) {
        guard let agentType = AgentType.fromBundleId(bundleId) else { return }
        handleDeadAgents([agentType])
    }

    // MARK: - CLI Process Checking

    private func checkProcessesAlive() {
        let checks = cliProcessChecks()
        guard !checks.isEmpty else { return }

        Task.detached(priority: .utility) { [checks] in
            let deadAgents = checks.compactMap { check -> AgentType? in
                let (agentType, names) = check
                guard !Self.isAnyProcessRunning(names: names) else { return nil }
                return agentType
            }
            guard !deadAgents.isEmpty else { return }
            await MainActor.run {
                AppDelegate.shared?.sessionManager.handleDeadAgents(deadAgents)
            }
        }
    }

    @MainActor
    func checkProcessesAlive(processStatus: @escaping @Sendable ([String]) -> Bool) {
        let checks = cliProcessChecks()
        let deadAgents = checks.compactMap { check -> AgentType? in
            let (agentType, names) = check
            return processStatus(names) ? nil : agentType
        }
        handleDeadAgents(deadAgents)
    }

    private func cliProcessChecks() -> [(AgentType, [String])] {
        activeSessions
            .filter { !$0.agentType.isDesktopApp && !$0.agentType.processNames.isEmpty }
            .reduce(into: [(AgentType, [String])]()) { result, session in
                if !result.contains(where: { $0.0 == session.agentType }) {
                    result.append((session.agentType, session.agentType.processNames))
                }
            }
    }

    private func handleDeadAgents(_ deadAgents: [AgentType]) {
        guard !deadAgents.isEmpty else { return }

        for agentType in deadAgents {
            for session in activeSessions where session.agentType == agentType {
                markCompleted(session)
            }
        }

        reSelectIfCurrentCompleted()
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    /// If the currently selected session has been completed, pick the next active session.
    private func reSelectIfCurrentCompleted() {
        guard let sid = selectedSessionId,
              sessions.first(where: { $0.id == sid })?.status == .completed
        else { return }
        selectedSessionId = activeSessions.first?.id
    }

    private nonisolated static func isAnyProcessRunning(names: [String]) -> Bool {
        for name in names {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            task.arguments = ["-x", name]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 { return true }
            } catch {}
        }
        return false
    }

    func cleanupStaleSessions() {
        let now = Date()
        for session in activeSessions {
            if (session.status == .active || session.status == .idle),
               now.timeIntervalSince(session.lastActivityTime) > Self.idleTimeout {
                markCompleted(session)
            }
        }
        reSelectIfCurrentCompleted()
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    var selectedSession: AgentSession? {
        guard let id = selectedSessionId else { return activeSessions.first }
        return sessions.first { $0.id == id }
    }

    var hasInteraction: Bool {
        activeSessions.contains {
            $0.status == .waitingPermission || $0.status == .waitingAnswer || $0.status == .waitingPlanReview
        }
    }

    var prioritizedInteractionSession: AgentSession? {
        activeSessions.first {
            $0.status == .waitingPermission || $0.status == .waitingAnswer || $0.status == .waitingPlanReview
        }
    }

    var diagnosticsIslandState: String {
        NotchContentView
            .diagnosticsIslandState(for: self, currentState: currentIslandState)
            .diagnosticsValue
    }

    func handleMessage(_ message: DIMessage) {
        if shouldIgnoreMirroredSession(message) {
            return
        }

        switch message.type {
        case .sessionStart:
            startSession(message)
        case .sessionEnd:
            endSession(message)
        case .toolStart:
            handleToolStart(message)
        case .toolComplete:
            handleToolComplete(message)
        case .statusUpdate, .progress:
            handleStatus(message)
        case .subagentStart:
            handleSubagentStart(message)
        case .subagentEnd:
            handleSubagentEnd(message)
        case .contextCompact:
            handleContextCompact(message)
        case .recap:
            handleRecap(message)
        default:
            break
        }

        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    private func shouldIgnoreMirroredSession(_ message: DIMessage) -> Bool {
        guard let agentType = AgentType.from(message.agentType),
              agentType == .claudeCode,
              message.type == .sessionStart || message.type == .sessionEnd,
              let sessionSuffix = mirroredSessionSuffix(from: message.sessionId)
        else {
            return false
        }

        return sessions.contains { session in
            isCursorFamily(session.agentType) && mirroredSessionSuffix(from: session.id) == sessionSuffix
        }
    }

    private func isCursorFamily(_ agentType: AgentType) -> Bool {
        agentType == .cursor || agentType == .trae
    }

    private func mirroredSessionSuffix(from sessionId: String) -> String? {
        guard let separator = sessionId.firstIndex(of: "-") else {
            return nil
        }
        let suffix = String(sessionId[sessionId.index(after: separator)...])
        return suffix.isEmpty ? nil : suffix
    }

    private func resolvedAgentType(for message: DIMessage) -> AgentType {
        if let explicit = AgentType.from(message.agentType) {
            if explicit == .claudeCode, let mirrored = mirroredCursorFamilyAgent(for: message.sessionId) {
                return mirrored
            }
            return explicit
        }

        if let prefix = message.sessionId.split(separator: "-", maxSplits: 1).first,
           let inferred = AgentType.from(String(prefix)) {
            return inferred
        }

        if let mirrored = mirroredCursorFamilyAgent(for: message.sessionId) {
            return mirrored
        }

        if let terminal = message.terminal, let app = TerminalApp.detect(from: terminal) {
            switch app {
            case .cursor, .windsurf:
                return .cursor
            case .trae, .traeCn:
                return .trae
            case .codex:
                return .codex
            default:
                break
            }
        }

        if let existing = sessions.first(where: { $0.id == message.sessionId }) {
            return existing.agentType
        }

        return .claudeCode
    }

    private func mirroredCursorFamilyAgent(for sessionId: String) -> AgentType? {
        guard let sessionSuffix = mirroredSessionSuffix(from: sessionId) else {
            return nil
        }
        return sessions.first(where: {
            isCursorFamily($0.agentType) && mirroredSessionSuffix(from: $0.id) == sessionSuffix
        })?.agentType
    }

    private func isMirroredCursorMessage(_ message: DIMessage) -> Bool {
        guard let sessionSuffix = mirroredSessionSuffix(from: message.sessionId) else {
            return false
        }
        return sessions.contains { session in
            isCursorFamily(session.agentType) && mirroredSessionSuffix(from: session.id) == sessionSuffix
        }
    }

    /// Bridges often emit both `cursor-<uuid>` and `claude_code-<uuid>` for one run; keep a single island row.
    private func mergeAgentTypesForMirror(_ existing: AgentType, _ incoming: AgentType) -> AgentType {
        if existing == .cursor || incoming == .cursor { return .cursor }
        return existing
    }

    /// Returns another session whose id shares the same mirrored suffix (paired hooks).
    private func sessionMatchingMirroredSuffix(of sessionId: String) -> AgentSession? {
        guard let suffix = mirroredSessionSuffix(from: sessionId) else { return nil }
        return sessions.first { mirroredSessionSuffix(from: $0.id) == suffix && $0.id != sessionId }
    }

    func handlePermissionRequest(_ message: DIMessage, respond: @escaping @Sendable (Bool) -> Void) {
        let realAgent = resolvedAgentType(for: message)

        if realAgent == .openCode {
            let tool = (message.tool ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let desc = (message.permDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let path = (message.filePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let diff = (message.diff ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let isSafeFilesystemPermission = tool == "external_directory"
                || tool == "externaldirectory"
            let isPlaceholderPermission = (tool.isEmpty || tool == "unknown")
                && desc.isEmpty
                && path.isEmpty
                && diff.isEmpty
            if isPlaceholderPermission || isSafeFilesystemPermission {
                respond(true)
                return
            }
        }

        let session = findOrCreateSessionForInteraction(message)
        session.status = .waitingPermission
        session.pendingPermission = PendingPermission(
            requestingAgent: realAgent,
            tool: message.tool ?? "unknown",
            description: message.permDescription ?? "",
            diff: message.diff,
            filePath: message.filePath,
            respond: respond
        )
        selectedSessionId = session.id
        audioEngine?.play(.permissionRequest, session: session)
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    func handleQuestionRequest(_ message: DIMessage, respond: @escaping @Sendable (String) -> Void, cancel: (@Sendable () -> Void)? = nil) {
        let realAgent = resolvedAgentType(for: message)
        let text = message.questionText ?? ""
        let options = message.options ?? []
        // Skip stub events (e.g. OpenCode fires a placeholder "Question" with no options
        // before the real question arrives). Close the fd so the di-bridge exits cleanly.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && !(trimmed == "Question" && options.isEmpty) else {
            cancel?()
            return
        }
        let session = findOrCreateSessionForInteraction(message)

        // Deduplicate: if this session was answered recently (within 2s) and the
        // incoming question text matches (exact or contains — handles [N/M] prefix
        // variations from sequential flows), auto-reply with the cached answer so the
        // sequential flow can advance to the next question.
        if let recent = recentAnswers[session.id],
           !options.isEmpty,
           Date().timeIntervalSince(recent.timestamp) < 2.0,
           (trimmed == recent.questionText
            || trimmed.contains(recent.questionText)
            || recent.questionText.contains(trimmed)) {
            respond(recent.answer)
            return
        }

        // Close the previous question's fd when superseded by a newer event.
        session.pendingQuestion?.cancel?()
        session.status = .waitingAnswer
        session.pendingQuestion = PendingQuestion(
            requestingAgent: realAgent,
            text: text,
            options: options,
            respond: respond,
            cancel: cancel
        )
        selectedSessionId = session.id
        audioEngine?.play(.question, session: session)
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    func handlePlanReview(_ message: DIMessage, respond: @escaping @Sendable (Bool, String?) -> Void) {
        let realAgent = resolvedAgentType(for: message)
        let session = findOrCreateSessionForInteraction(message)
        session.status = .waitingPlanReview
        session.pendingPlanReview = PendingPlanReview(
            requestingAgent: realAgent,
            markdown: message.planMarkdown ?? "",
            respond: respond
        )
        selectedSessionId = session.id
        audioEngine?.play(.planReview, session: session)
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    func approvePermission(session: AgentSession) {
        session.pendingPermission?.respond(true)
        session.pendingPermission = nil
        session.status = .active
        audioEngine?.play(.approved, session: session)
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    func denyPermission(session: AgentSession) {
        session.pendingPermission?.respond(false)
        session.pendingPermission = nil
        session.status = .active
        audioEngine?.play(.denied, session: session)
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    func answerQuestion(session: AgentSession, answer: String) {
        // Cache for deduplication of follow-up duplicate events.
        if let pq = session.pendingQuestion {
            recentAnswers[session.id] = RecentAnswer(
                answer: answer,
                questionText: pq.text.trimmingCharacters(in: .whitespacesAndNewlines),
                options: Set(pq.options),
                timestamp: Date()
            )
        }
        session.pendingQuestion?.respond(answer)
        session.pendingQuestion = nil
        session.status = .active
        audioEngine?.play(.answered, session: session)
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    func respondToPlan(session: AgentSession, approved: Bool, feedback: String?) {
        session.pendingPlanReview?.respond(approved, feedback)
        session.pendingPlanReview = nil
        session.status = .active
        audioEngine?.play(approved ? .approved : .denied, session: session)
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    func dismissSession(_ session: AgentSession) {
        sessions.removeAll { $0.id == session.id }
        if selectedSessionId == session.id {
            selectedSessionId = activeSessions.first?.id
        }
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    // MARK: - Private

    private func startSession(_ message: DIMessage) {
        let agentType = resolvedAgentType(for: message)

        if let existing = sessions.first(where: { $0.id == message.sessionId }) {
            existing.lastActivityTime = Date()
            existing.status = .active
            existing.statusText = ""
            clearStaleInteraction(existing)
            if let t = message.terminal, !t.isEmpty { existing.terminal = t }
            if let w = message.workingDir, !w.isEmpty { existing.workingDirectory = w }
            if let p = message.prompt, !p.isEmpty {
                existing.prompt = p
                existing.chatHistory.append(ChatMessage(timestamp: Date(), role: .user, content: p))
                audioEngine?.play(.sessionStart, session: existing)
            }
            if let ts = message.termSessionId, !ts.isEmpty { existing.termSessionId = ts }
            if existing.windowNumber == nil {
                existing.windowNumber = TerminalJumpManager.captureFrontWindowNumber(
                    for: existing.agentType, terminal: existing.terminal)
            }
            updateTokenUsage(session: existing, message: message)
            selectedSessionId = existing.id
            return
        }

        if let twin = sessionMatchingMirroredSuffix(of: message.sessionId) {
            twin.lastActivityTime = Date()
            twin.status = .active
            twin.statusText = ""
            clearStaleInteraction(twin)
            if let t = message.terminal, !t.isEmpty { twin.terminal = t }
            if let w = message.workingDir, !w.isEmpty { twin.workingDirectory = w }
            if let p = message.prompt, !p.isEmpty {
                twin.prompt = p
                twin.chatHistory.append(ChatMessage(timestamp: Date(), role: .user, content: p))
                audioEngine?.play(.sessionStart, session: twin)
            }
            if let ts = message.termSessionId, !ts.isEmpty { twin.termSessionId = ts }
            if twin.windowNumber == nil {
                twin.windowNumber = TerminalJumpManager.captureFrontWindowNumber(
                    for: twin.agentType, terminal: twin.terminal)
            }
            updateTokenUsage(session: twin, message: message)
            selectedSessionId = twin.id
            return
        }

        let session = AgentSession(
            id: message.sessionId,
            agentType: agentType,
            terminal: message.terminal ?? "",
            workingDirectory: message.workingDir ?? "",
            prompt: message.prompt ?? ""
        )
        session.termSessionId = message.termSessionId
        session.windowNumber = TerminalJumpManager.captureFrontWindowNumber(
            for: agentType, terminal: session.terminal)
        sessions.append(session)
        if !session.prompt.isEmpty {
            session.chatHistory.append(ChatMessage(timestamp: Date(), role: .user, content: session.prompt))
        }
        updateTokenUsage(session: session, message: message)
        selectedSessionId = session.id
        audioEngine?.play(.sessionStart, session: session)
    }

    private func endSession(_ message: DIMessage) {
        let agentType = resolvedAgentType(for: message)

        guard let session = sessionForEndMessage(message) else { return }
        let alreadyCompleted = session.status == .completed
        updateTokenUsage(session: session, message: message)

        if let responseText = message.status, !responseText.isEmpty {
            session.agentResponse = responseText
            session.statusText = responseText
        }

        if !session.agentResponse.isEmpty {
            if let lastIdx = session.chatHistory.lastIndex(where: { $0.role == .assistant }) {
                session.chatHistory[lastIdx] = ChatMessage(
                    timestamp: Date(), role: .assistant, content: session.agentResponse
                )
            } else {
                session.chatHistory.append(
                    ChatMessage(timestamp: Date(), role: .assistant, content: session.agentResponse)
                )
            }
        }

        if !agentType.processNames.isEmpty {
            session.status = .idle
            session.currentTool = nil
            if session.statusText.isEmpty {
                session.statusText = "Done"
            }
            session.lastActivityTime = Date()
        } else {
            markCompleted(session)
        }
        if !alreadyCompleted {
            playAssistantReplySoundDebounced(sessionId: session.id)
        }

        if session.status == .completed, selectedSessionId == session.id {
            selectedSessionId = activeSessions.first?.id
        }
    }

    private func markCompleted(_ session: AgentSession) {
        session.status = .completed
        session.currentTool = nil
        session.completedAt = Date()
        scheduleLingerCleanup()
    }

    private func scheduleLingerCleanup() {
        let linger = completedLingerDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + linger + 0.1) { [weak self] in
            guard let self else { return }
            self.visibleSessionsVersion += 1
            self.cleanupLingeredSessions()
        }
    }

    func cleanupLingeredSessions() {
        let now = Date()
        sessions.removeAll { session in
            guard session.status == .completed, let completedAt = session.completedAt else { return false }
            return now.timeIntervalSince(completedAt) > completedLingerDuration + 5
        }
        if let selectedSessionId, !sessions.contains(where: { $0.id == selectedSessionId }) {
            self.selectedSessionId = activeSessions.first?.id
        }
        AppDelegate.shared?.refreshDiagnostics(islandState: diagnosticsIslandState)
    }

    private func handleToolStart(_ message: DIMessage) {
        let session = findOrCreateSession(message)
        clearStaleInteraction(session)
        let event = ToolEvent(tool: message.tool ?? "unknown", input: message.toolInput)
        session.events.append(event)
        session.currentTool = message.tool
        audioEngine?.play(.toolStart, session: session)
    }

    private func handleToolComplete(_ message: DIMessage) {
        let session = findOrCreateSession(message)
        clearStaleInteraction(session)
        if let idx = session.events.lastIndex(where: { $0.tool == (message.tool ?? "") && !$0.isComplete }) {
            session.events[idx].result = message.toolResult
            session.events[idx].linesAdded = message.linesAdded
            session.events[idx].linesRemoved = message.linesRemoved
            session.events[idx].isComplete = true
            session.events[idx].linesRead = ToolEvent.estimateLinesRead(from: message.toolResult)
            session.events[idx].testResults = ToolEvent.parseTestResults(from: message.toolResult)
        }
        session.currentTool = nil
        updateTokenUsage(session: session, message: message)
    }

    private func handleStatus(_ message: DIMessage) {
        let session = findOrCreateSession(message, reactivate: false)
        let text = message.status ?? ""
        session.statusText = text
        if !text.isEmpty {
            session.agentResponse = text
            if let lastIdx = session.chatHistory.lastIndex(where: { $0.role == .assistant }) {
                session.chatHistory[lastIdx] = ChatMessage(
                    timestamp: Date(), role: .assistant, content: text
                )
            } else {
                session.chatHistory.append(
                    ChatMessage(timestamp: Date(), role: .assistant, content: text)
                )
            }
        }

        let lower = text.lowercased()
        if lower.contains("compact") || lower.contains("context window") {
            audioEngine?.play(.contextCompacting, session: session)
        } else if lower.contains("error") || lower.contains("failed") || lower.contains("fatal") {
            session.status = .error
            audioEngine?.play(.error, session: session)
        } else if !text.isEmpty {
            // Assistant reply via Notification / progress — same chime as session end (user preference: "Session complete").
            playAssistantReplySoundDebounced(sessionId: session.id)
        }
        updateTokenUsage(session: session, message: message)
    }

    /// Resolves the session for `sessionEnd` when hooks use `cursor-*` vs `claude_code-*` ids for the same run.
    private func sessionForEndMessage(_ message: DIMessage) -> AgentSession? {
        if let s = sessions.first(where: { $0.id == message.sessionId }) {
            return s
        }
        return sessionMatchingMirroredSuffix(of: message.sessionId)
    }

    private func playAssistantReplySoundDebounced(sessionId: String) {
        let now = Date().timeIntervalSince1970
        let last = lastAssistantReplySoundAt[sessionId] ?? 0
        guard now - last >= assistantReplySoundMinInterval else { return }
        lastAssistantReplySoundAt[sessionId] = now
        audioEngine?.play(.sessionEnd)
    }

    private func handleSubagentStart(_ message: DIMessage) {
        let parentId = message.parentSessionId ?? message.sessionId
        let resolvedAgent = resolvedAgentType(for: message)
        let matchAgent: (AgentSession) -> Bool = { session in
            session.agentType == resolvedAgent
        }
        guard let parent = sessions.first(where: { $0.id == parentId && $0.status != .completed })
                ?? activeSessions.first(where: matchAgent) else { return }
        let subId = message.subagentId ?? UUID().uuidString
        if !parent.subagentIds.contains(subId) {
            parent.subagentIds.append(subId)
        }
        parent.lastActivityTime = Date()
        let event = ToolEvent(tool: "Subagent", input: message.prompt)
        parent.events.append(event)
    }

    private func handleSubagentEnd(_ message: DIMessage) {
        let parentId = message.parentSessionId ?? message.sessionId
        let resolvedAgent = resolvedAgentType(for: message)
        let matchAgent: (AgentSession) -> Bool = { session in
            session.agentType == resolvedAgent
        }
        guard let parent = sessions.first(where: { $0.id == parentId && $0.status != .completed })
                ?? activeSessions.first(where: matchAgent) else { return }
        if let subId = message.subagentId {
            parent.subagentIds.removeAll { $0 == subId }
        }
        parent.lastActivityTime = Date()
        updateTokenUsage(session: parent, message: message)
        if let idx = parent.events.lastIndex(where: { $0.tool == "Subagent" && !$0.isComplete }) {
            parent.events[idx].isComplete = true
            parent.events[idx].result = "Completed"
        }
    }

    private func handleContextCompact(_ message: DIMessage) {
        let session = findOrCreateSession(message)
        session.status = .compacting
        session.statusText = message.status ?? "Context compacting..."
        audioEngine?.play(.contextCompacting, session: session)
        updateTokenUsage(session: session, message: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if session.status == .compacting {
                session.status = .active
            }
        }
    }

    private func handleRecap(_ message: DIMessage) {
        let session = findOrCreateSession(message)
        session.recapText = message.recapText
    }

    /// If the agent sent new activity while we were still showing a pending interaction,
    /// the interaction was handled externally (e.g. user responded in the terminal).
    private func clearStaleInteraction(_ session: AgentSession) {
        switch session.status {
        case .waitingPermission:
            session.pendingPermission = nil
            session.status = .active
        case .waitingAnswer:
            session.pendingQuestion = nil
            session.status = .active
        case .waitingPlanReview:
            session.pendingPlanReview = nil
            session.status = .active
        default:
            break
        }
    }

    private func updateTokenUsage(session: AgentSession, message: DIMessage) {
        if let t = message.tokensIn { session.tokenUsage.inputTokens += t }
        if let t = message.tokensOut { session.tokenUsage.outputTokens += t }
        if let t = message.totalTokens { session.tokenUsage.totalTokens = t }
        if let c = message.costUSD { session.tokenUsage.estimatedCostUSD += c }
        if let m = message.model, !m.isEmpty { session.tokenUsage.model = m }
    }

    /// Interactive requests fold mirrored hook ids (`cursor-*` / `claude_code-*` same suffix) like `findOrCreateSession`.
    private func findOrCreateSessionForInteraction(_ message: DIMessage) -> AgentSession {
        let agentType = resolvedAgentType(for: message)

        if let existing = sessions.first(where: { $0.id == message.sessionId && $0.status != .completed }) {
            existing.lastActivityTime = Date()
            return existing
        }
        if let mirrored = mirroredCursorSession(for: message.sessionId) {
            mirrored.lastActivityTime = Date()
            return mirrored
        }

        if let twin = sessionMatchingMirroredSuffix(of: message.sessionId) {
            twin.lastActivityTime = Date()
            return twin
        }
        if let sameAgent = activeSessions.first(where: { $0.agentType == agentType }) {
            sameAgent.lastActivityTime = Date()
            return sameAgent
        }
        if let completed = sessions.first(where: { $0.id == message.sessionId }) {
            completed.lastActivityTime = Date()
            completed.status = .active
            return completed
        }
        let session = AgentSession(
            id: message.sessionId,
            agentType: agentType,
            terminal: message.terminal ?? "",
            workingDirectory: message.workingDir ?? "",
            prompt: message.prompt ?? ""
        )
        sessions.append(session)
        return session
    }

    private func findOrCreateSession(_ message: DIMessage, reactivate: Bool = true) -> AgentSession {
        let agentType = resolvedAgentType(for: message)

        if let existing = sessions.first(where: { $0.id == message.sessionId && $0.status != .completed }) {
            existing.lastActivityTime = Date()
            return existing
        }

        if let mirrored = mirroredCursorSession(for: message.sessionId) {
            mirrored.lastActivityTime = Date()
            if reactivate { mirrored.status = .active }
            return mirrored
        }

        if let completed = sessions.first(where: { $0.id == message.sessionId }) {
            completed.lastActivityTime = Date()
            if reactivate { completed.status = .active }
            return completed
        }

        if let twin = sessionMatchingMirroredSuffix(of: message.sessionId) {
            twin.lastActivityTime = Date()
            if twin.status == .completed, reactivate { twin.status = .active }
            return twin
        }

        let session = AgentSession(
            id: message.sessionId,
            agentType: agentType,
            terminal: message.terminal ?? "",
            workingDirectory: message.workingDir ?? "",
            prompt: message.prompt ?? ""
        )
        sessions.append(session)
        return session
    }

    private func mirroredCursorSession(for sessionId: String) -> AgentSession? {
        guard let suffix = mirroredSessionSuffix(from: sessionId) else { return nil }
        return sessions.first(where: {
            isCursorFamily($0.agentType) && $0.status != .completed && mirroredSessionSuffix(from: $0.id) == suffix
        })
    }
}
