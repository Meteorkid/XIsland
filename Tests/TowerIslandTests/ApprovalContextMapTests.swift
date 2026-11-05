import XCTest
import DIShared
@testable import XIsland

/// 审批上下文地图的解析与聚合回归：
/// - 文件操作归类、apply_patch 标记、路径键兼容与保守降级；
/// - 任务/计划/变更/待审批四层节点与去重合并规则；
/// - 折叠摘要文案。
@MainActor
final class ApprovalContextMapTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppPreferences.defaults.set("en", forKey: "appLanguage")
    }

    override func tearDown() {
        AppPreferences.defaults.removeObject(forKey: "appLanguage")
        super.tearDown()
    }

    private func makeSession(prompt: String = "整理审批上下文") -> AgentSession {
        AgentSession(id: "map-session", agentType: .claudeCode, prompt: prompt)
    }

    private func appendFileEvent(_ session: AgentSession, tool: String, path: String) {
        session.appendEvent(ToolEvent(tool: tool, input: "{\"file_path\":\"\(path)\"}", isComplete: true))
    }

    // MARK: - FileOperationParser

    func testWriteToolMapsToCreatedFile() {
        let operations = FileOperationParser.operations(
            tool: "Write",
            input: #"{"file_path":"/tmp/new.swift","content":"let x = 1"}"#
        )
        XCTAssertEqual(operations, [.init(path: "/tmp/new.swift", kind: .created)])
    }

    func testEditToolVariantsMapToModified() {
        for tool in ["Edit", "MultiEdit", "str_replace", "edit_file", "apply_patch"] {
            let operations = FileOperationParser.operations(tool: tool, input: #"{"file_path":"/tmp/a.swift"}"#)
            XCTAssertEqual(operations, [.init(path: "/tmp/a.swift", kind: .modified)], tool)
        }
    }

    func testDeleteToolVariantsMapToDeleted() {
        for tool in ["Delete", "remove_file", "rm"] {
            let operations = FileOperationParser.operations(tool: tool, input: #"{"path":"/tmp/old.swift"}"#)
            XCTAssertEqual(operations, [.init(path: "/tmp/old.swift", kind: .deleted)], tool)
        }
    }

    func testApplyPatchMarkersClassifyEachFile() throws {
        let patch = """
        *** Begin Patch
        *** Add File: /tmp/new.txt
        +hi
        *** Update File: /tmp/edit.txt
        @@
        *** Delete File: /tmp/old.txt
        *** End Patch
        """
        let expected: [FileOperationParser.Operation] = [
            .init(path: "/tmp/new.txt", kind: .created),
            .init(path: "/tmp/edit.txt", kind: .modified),
            .init(path: "/tmp/old.txt", kind: .deleted),
        ]

        // 原始补丁文本
        XCTAssertEqual(FileOperationParser.operations(tool: "apply_patch", input: patch), expected)

        // JSON 包装（换行在 JSON 中被转义）
        let data = try JSONSerialization.data(withJSONObject: ["input": patch])
        let wrapped = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(FileOperationParser.operations(tool: "apply_patch", input: wrapped), expected)
    }

    func testUnknownToolOrMissingPathYieldsNoOperations() {
        XCTAssertTrue(FileOperationParser.operations(tool: "Bash", input: #"{"command":"rm -rf /tmp/x"}"#).isEmpty)
        XCTAssertTrue(FileOperationParser.operations(tool: "Write", input: #"{"content":"x"}"#).isEmpty)
        XCTAssertTrue(FileOperationParser.operations(tool: "", input: "{}").isEmpty)
        XCTAssertTrue(FileOperationParser.operations(tool: "Read", input: #"{"file_path":"/tmp/a"}"#).isEmpty)
    }

    func testPathKeyVariantsAndNonJSONFallback() {
        XCTAssertEqual(FileOperationParser.firstPath(in: #"{"path":"/tmp/a"}"#), "/tmp/a")
        XCTAssertEqual(FileOperationParser.firstPath(in: #"{"filePath":"/tmp/b"}"#), "/tmp/b")
        XCTAssertEqual(FileOperationParser.firstPath(in: #"{"notebook_path":"/tmp/c.ipynb"}"#), "/tmp/c.ipynb")
        XCTAssertNil(FileOperationParser.firstPath(in: "{}"))
        XCTAssertNil(FileOperationParser.firstPath(in: nil))
        // 非 JSON（截断）载荷走保守键值扫描
        XCTAssertEqual(FileOperationParser.firstPath(in: "{\"file_path\":\"/tmp/d\""), "/tmp/d")
    }

    // MARK: - MarkdownHeadingParser

    func testHeadingParserExtractsLevelsAndStripsFormatting() {
        let markdown = """
        # 目标
        ## 步骤 **一**
        ### `细节`
        #### 太深
        ##
        ## 步骤二
        """
        XCTAssertEqual(MarkdownHeadingParser.headings(in: markdown), [
            .init(title: "目标", depth: 1),
            .init(title: "步骤 一", depth: 2),
            .init(title: "细节", depth: 3),
            .init(title: "步骤二", depth: 2),
        ])
    }

    func testHeadingParserRespectsLimitAndEmptyInput() {
        let markdown = (1...8).map { "# H\($0)" }.joined(separator: "\n")
        XCTAssertEqual(MarkdownHeadingParser.headings(in: markdown).count, ApprovalContextMapBuilder.maxPlanNodes)
        XCTAssertTrue(MarkdownHeadingParser.headings(in: nil).isEmpty)
        XCTAssertTrue(MarkdownHeadingParser.headings(in: "").isEmpty)
        XCTAssertTrue(MarkdownHeadingParser.headings(in: "没有标题").isEmpty)
    }

    // MARK: - ApprovalContextMapBuilder

    func testTaskNodePrefersLatestUserMessageThenPrompt() {
        let session = makeSession(prompt: "初始目标")
        XCTAssertEqual(ApprovalContextMapBuilder.taskNode(for: session)?.title, "初始目标")

        session.appendChatMessage(ChatMessage(timestamp: Date(), role: .assistant, content: "回复"))
        XCTAssertEqual(ApprovalContextMapBuilder.taskNode(for: session)?.title, "初始目标")

        session.appendChatMessage(ChatMessage(timestamp: Date(), role: .user, content: "最新一轮"))
        XCTAssertEqual(ApprovalContextMapBuilder.taskNode(for: session)?.title, "最新一轮")

        let empty = AgentSession(id: "empty", agentType: .codex)
        XCTAssertNil(ApprovalContextMapBuilder.taskNode(for: empty))
    }

    func testPlanNodesPreferPendingPlanReviewOverLatestReply() {
        let session = makeSession()
        session.agentResponse = "# 回复结构\n## 小节"
        XCTAssertEqual(ApprovalContextMapBuilder.planNodes(for: session).map(\.title), ["回复结构", "小节"])

        session.pendingPlanReview = PendingPlanReview(
            requestingAgent: .claudeCode,
            markdown: "# 待审计划\n## 第一步",
            respond: { _, _ in }
        )
        XCTAssertEqual(ApprovalContextMapBuilder.planNodes(for: session).map(\.title), ["待审计划", "第一步"])
    }

    func testChangesDeduplicateMergeAndKeepFirstAppearanceOrder() {
        let session = makeSession()
        appendFileEvent(session, tool: "Write", path: "/tmp/a.swift")
        appendFileEvent(session, tool: "Edit", path: "/tmp/a.swift")
        appendFileEvent(session, tool: "Edit", path: "/tmp/b.swift")
        appendFileEvent(session, tool: "Write", path: "/tmp/c.swift")
        appendFileEvent(session, tool: "Delete", path: "/tmp/c.swift")

        XCTAssertEqual(ApprovalContextMapBuilder.changeNodes(for: session), [
            .init(path: "/tmp/a.swift", kind: .created),
            .init(path: "/tmp/b.swift", kind: .modified),
            .init(path: "/tmp/c.swift", kind: .deleted),
        ])
    }

    func testMergeRules() {
        XCTAssertEqual(ApprovalContextMapBuilder.mergedKind(previous: .created, next: .modified), .created)
        XCTAssertEqual(ApprovalContextMapBuilder.mergedKind(previous: .modified, next: .deleted), .deleted)
        XCTAssertEqual(ApprovalContextMapBuilder.mergedKind(previous: .deleted, next: .modified), .modified)
        XCTAssertEqual(ApprovalContextMapBuilder.mergedKind(previous: .deleted, next: .created), .created)
        XCTAssertEqual(ApprovalContextMapBuilder.mergedKind(previous: nil, next: .modified), .modified)
    }

    func testPendingNodeSelectionAndPlanFallbackTitle() throws {
        let session = makeSession()
        session.pendingPermission = PendingPermission(
            requestingAgent: .claudeCode,
            tool: "Bash",
            description: "运行测试",
            diff: nil,
            filePath: "/tmp/x",
            respond: { _ in }
        )
        let defaultMap = ApprovalContextMapBuilder.build(session: session)
        XCTAssertEqual(defaultMap.pending?.kind, .permission)
        XCTAssertEqual(defaultMap.pending?.title, "Bash")
        XCTAssertEqual(defaultMap.pending?.detail, "/tmp/x")

        session.pendingPlanReview = PendingPlanReview(
            requestingAgent: .claudeCode,
            markdown: "# 计划标题",
            respond: { _, _ in }
        )
        let planMap = ApprovalContextMapBuilder.build(session: session, pendingKind: .planReview)
        XCTAssertEqual(planMap.pending?.kind, .planReview)
        XCTAssertEqual(planMap.pending?.title, "计划标题")

        session.pendingPlanReview = PendingPlanReview(
            requestingAgent: .claudeCode,
            markdown: "正文没有标题",
            respond: { _, _ in }
        )
        let fallbackMap = ApprovalContextMapBuilder.build(session: session, pendingKind: .planReview)
        let fallbackPending = try XCTUnwrap(fallbackMap.pending)
        XCTAssertEqual(fallbackPending.title, "")
        XCTAssertEqual(ApprovalContextMapView.pendingTitle(for: fallbackPending), L10n.review)
    }

    func testCountsAndSummaryText() {
        let session = makeSession()
        appendFileEvent(session, tool: "Write", path: "/tmp/1")
        appendFileEvent(session, tool: "Write", path: "/tmp/2")
        appendFileEvent(session, tool: "Write", path: "/tmp/3")
        appendFileEvent(session, tool: "Edit", path: "/tmp/4")
        appendFileEvent(session, tool: "Edit", path: "/tmp/5")
        appendFileEvent(session, tool: "Delete", path: "/tmp/6")

        let map = ApprovalContextMapBuilder.build(session: session)
        XCTAssertEqual(map.createdCount, 3)
        XCTAssertEqual(map.modifiedCount, 2)
        XCTAssertEqual(map.deletedCount, 1)
        XCTAssertEqual(ApprovalContextMapView.summaryText(for: map), "3 new · 2 modified · 1 deleted")
        XCTAssertEqual(ApprovalContextMapView.summaryText(for: .empty), "No file changes")
    }

    func testSummaryOmitsZeroCounts() {
        let session = makeSession()
        appendFileEvent(session, tool: "Edit", path: "/tmp/only")
        XCTAssertEqual(ApprovalContextMapView.summaryText(for: ApprovalContextMapBuilder.build(session: session)),
                       "1 modified")
    }

    // MARK: - 开关

    func testReasonFromPermissionDescription() {
        let session = makeSession()
        session.pendingPermission = PendingPermission(
            requestingAgent: .claudeCode,
            tool: "Bash",
            description: "运行测试并修复失败用例",
            diff: nil,
            filePath: nil,
            respond: { _ in }
        )
        XCTAssertEqual(
            ApprovalContextMapBuilder.build(session: session, pendingKind: .permission).reason,
            "运行测试并修复失败用例"
        )
    }

    func testReasonFromPlanFirstParagraphSkipsHeadingsAndCode() {
        let session = makeSession()
        session.pendingPlanReview = PendingPlanReview(
            requestingAgent: .claudeCode,
            markdown: "# 实现计划\n\n```\ncode\n```\n\n- 先补负例，再修时间轴。\n- 其他细节",
            respond: { _, _ in }
        )
        XCTAssertEqual(
            ApprovalContextMapBuilder.build(session: session, pendingKind: .planReview).reason,
            "先补负例，再修时间轴。"
        )
    }

    func testReasonCapsLongText() {
        let session = makeSession()
        session.pendingPermission = PendingPermission(
            requestingAgent: .claudeCode,
            tool: "Bash",
            description: String(repeating: "很长的原因", count: 60),
            diff: nil,
            filePath: nil,
            respond: { _ in }
        )
        let reason = ApprovalContextMapBuilder.build(session: session, pendingKind: .permission).reason
        XCTAssertEqual(reason?.count, 141)
        XCTAssertTrue(reason?.hasSuffix("…") == true)
    }

    func testReasonNilWhenNothingToExtract() {
        let session = makeSession()
        session.pendingPermission = PendingPermission(
            requestingAgent: .claudeCode,
            tool: "Bash",
            description: "   ",
            diff: nil,
            filePath: nil,
            respond: { _ in }
        )
        XCTAssertNil(ApprovalContextMapBuilder.build(session: session, pendingKind: .permission).reason)
        XCTAssertNil(ApprovalContextMapBuilder.build(session: makeSession(), pendingKind: .permission).reason)
    }

    func testReasonFromPlanWithoutParagraphIsNil() {
        let session = makeSession()
        session.pendingPlanReview = PendingPlanReview(
            requestingAgent: .claudeCode,
            markdown: "# 只有标题\n## 二级标题",
            respond: { _, _ in }
        )
        XCTAssertNil(ApprovalContextMapBuilder.build(session: session, pendingKind: .planReview).reason)
    }

    func testFilteredChangesByKind() {
        let session = makeSession()
        appendFileEvent(session, tool: "Write", path: "/tmp/a")
        appendFileEvent(session, tool: "Edit", path: "/tmp/b")
        appendFileEvent(session, tool: "Delete", path: "/tmp/c")
        let changes = ApprovalContextMapBuilder.changeNodes(for: session)
        XCTAssertEqual(ApprovalContextMapView.filteredChanges(changes, filter: nil).count, 3)
        XCTAssertEqual(ApprovalContextMapView.filteredChanges(changes, filter: .created).map(\.path), ["/tmp/a"])
        XCTAssertEqual(ApprovalContextMapView.filteredChanges(changes, filter: .modified).map(\.path), ["/tmp/b"])
        XCTAssertEqual(ApprovalContextMapView.filteredChanges(changes, filter: .deleted).map(\.path), ["/tmp/c"])
        XCTAssertEqual(ApprovalContextMapView.kindKey(.created), "created")
    }

    // MARK: - P2: 快照、差异与批注

    func testSnapshotRoundTrip() throws {
        let snapshot = ApprovalContextMapSnapshot(
            map: ApprovalContextMap(
                task: .init(title: "旧任务"),
                plan: [.init(title: "数据模型", depth: 1), .init(title: "旧流程", depth: 2)],
                changes: [
                    .init(path: "/tmp/a", kind: .modified),
                    .init(path: "/tmp/b", kind: .created),
                ],
                pending: nil,
                reason: nil
            ),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ApprovalContextMapSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testDeltaDetectsFileAndPlanChanges() {
        let previous = ApprovalContextMapSnapshot(map: ApprovalContextMap(
            task: .init(title: "旧任务"),
            plan: [.init(title: "A", depth: 1), .init(title: "B", depth: 1)],
            changes: [
                .init(path: "/tmp/a", kind: .modified),
                .init(path: "/tmp/b", kind: .created),
            ],
            pending: nil,
            reason: nil
        ))
        let current = ApprovalContextMapSnapshot(map: ApprovalContextMap(
            task: .init(title: "新任务"),
            plan: [.init(title: "B", depth: 1), .init(title: "C", depth: 1)],
            changes: [
                .init(path: "/tmp/a", kind: .deleted),
                .init(path: "/tmp/c", kind: .created),
            ],
            pending: nil,
            reason: nil
        ))
        let delta = ApprovalContextMapDelta.between(previous: previous, current: current)
        XCTAssertEqual(delta.addedFiles, ["/tmp/c"])
        XCTAssertEqual(delta.removedFiles, ["/tmp/b"])
        XCTAssertEqual(delta.kindChangedFiles, [.init(path: "/tmp/a", from: .modified, to: .deleted)])
        XCTAssertEqual(delta.addedPlanTitles, ["C"])
        XCTAssertEqual(delta.removedPlanTitles, ["A"])
        XCTAssertFalse(delta.isEmpty)
    }

    func testDeltaIsEmptyWhenSnapshotsMatch() {
        let map = ApprovalContextMap(
            task: .init(title: "同一任务"),
            plan: [.init(title: "步骤", depth: 1)],
            changes: [.init(path: "/tmp/a", kind: .created)],
            pending: nil,
            reason: nil
        )
        let snapshot = ApprovalContextMapSnapshot(map: map)
        XCTAssertTrue(ApprovalContextMapDelta.between(previous: snapshot, current: snapshot).isEmpty)
    }

    func testDeltaSummaryCounts() {
        let delta = ApprovalContextMapDelta(
            addedFiles: ["/a", "/b"],
            removedFiles: ["/c"],
            kindChangedFiles: [.init(path: "/d", from: .modified, to: .deleted)],
            addedPlanTitles: ["P"],
            removedPlanTitles: ["Q"]
        )
        XCTAssertEqual(ApprovalContextMapView.deltaSummary(delta), "+2 · −1 · ~1 · Plan +1 −1")
    }

    func testDefaultExpandedSectionsOnlyPending() {
        XCTAssertEqual(ApprovalContextMapView.defaultExpandedSections, [.pending])
        XCTAssertEqual(ApprovalContextMapView.sectionKey(.task), "task")
        XCTAssertEqual(ApprovalContextMapView.sectionKey(.plan), "plan")
        XCTAssertEqual(ApprovalContextMapView.sectionKey(.changes), "changes")
        XCTAssertEqual(ApprovalContextMapView.sectionKey(.pending), "pending")
    }

    func testGroupSummaries() {
        let task = ApprovalContextMap.TaskNode(title: "整理审批上下文")
        XCTAssertEqual(ApprovalContextMapView.taskSummary(task), "整理审批上下文")

        let plan = [
            ApprovalContextMap.PlanNode(title: "数据模型", depth: 1),
            ApprovalContextMap.PlanNode(title: "视图接入", depth: 2),
        ]
        XCTAssertEqual(ApprovalContextMapView.planSummary(plan), "2 items · 数据模型")

        let changes = [
            ApprovalContextMap.ChangeNode(path: "/tmp/a", kind: .created),
            ApprovalContextMap.ChangeNode(path: "/tmp/b", kind: .modified),
            ApprovalContextMap.ChangeNode(path: "/tmp/c", kind: .deleted),
        ]
        XCTAssertEqual(ApprovalContextMapView.changeSummary(changes), "3 files")

        let pending = ApprovalContextMap.PendingNode(kind: .permission, title: "Bash", detail: nil)
        XCTAssertEqual(ApprovalContextMapView.pendingSummary(pending), "Bash")
    }

    func testSnapshotStoreAppendLoadAndTrim() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-map-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ApprovalContextMapSnapshotStore(
            url: directory.appendingPathComponent("history.json"),
            limitPerSession: 2
        )
        XCTAssertNil(store.latest(sessionID: "s"))
        func snapshot(_ title: String, at seconds: TimeInterval) -> ApprovalContextMapSnapshot {
            ApprovalContextMapSnapshot(
                map: ApprovalContextMap(task: .init(title: title), plan: [], changes: [], pending: nil, reason: nil),
                capturedAt: Date(timeIntervalSince1970: seconds)
            )
        }
        store.append(snapshot("one", at: 1), sessionID: "s")
        store.append(snapshot("two", at: 2), sessionID: "s")
        store.append(snapshot("three", at: 3), sessionID: "s")
        XCTAssertEqual(store.history(sessionID: "s").map(\.taskTitle), ["two", "three"])
        XCTAssertEqual(store.latest(sessionID: "s")?.taskTitle, "three")
        XCTAssertTrue(store.history(sessionID: "other").isEmpty)
    }

    func testSessionManagerRecordsSnapshotOnCompletionOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-map-record-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ApprovalContextMapSnapshotStore(url: directory.appendingPathComponent("history.json"))
        let manager = SessionManager()
        manager.approvalMapSnapshotStore = store

        var start = DIMessage(type: .sessionStart, sessionId: "record-session")
        start.agentType = "codex"
        start.prompt = "记录地图快照"
        manager.handleMessage(start)
        manager.sessions.first?.appendEvent(ToolEvent(tool: "Write", input: #"{"file_path":"/tmp/x"}"#, isComplete: true))

        var end = DIMessage(type: .sessionEnd, sessionId: "record-session")
        end.agentType = "codex"
        end.observedState = "completed"
        manager.handleMessage(end)

        XCTAssertEqual(store.history(sessionID: "record-session").count, 1)
        let snapshot = try XCTUnwrap(store.latest(sessionID: "record-session"))
        XCTAssertEqual(snapshot.taskTitle, "记录地图快照")
        XCTAssertEqual(snapshot.changes.map(\.path), ["/tmp/x"])
        XCTAssertEqual(snapshot.changes.first?.kind, .created)

        manager.handleMessage(end)
        XCTAssertEqual(store.history(sessionID: "record-session").count, 1)
    }

    func testDefaultSnapshotStoreIsDisabledUnderTests() {
        XCTAssertTrue(AppPreferences.isIsolated)
        XCTAssertNil(ApprovalContextMapSnapshotStore.defaultStore())
    }

    func testAnnotationMessageFormatsQuestionAndCommand() {
        let question = ApprovalContextMapView.annotationMessage(
            kind: .question, nodeLabel: "File", title: "/tmp/a.swift", text: "这个文件为什么改？"
        )
        XCTAssertTrue(question.contains("File · /tmp/a.swift"))
        XCTAssertTrue(question.contains("这个文件为什么改？"))

        let command = ApprovalContextMapView.annotationMessage(
            kind: .command, nodeLabel: "File", title: "/tmp/a.swift", text: "拆成两个文件"
        )
        XCTAssertNotEqual(question, command)
        XCTAssertTrue(command.lowercased().contains("adjust"))
        XCTAssertTrue(command.contains("拆成两个文件"))
    }

    func testSettingsDefaultEnabledAndPersistOptOut() throws {
        let suite = "dev.xisland.tests.approval-map-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(ApprovalContextMapSettings.isEnabled(defaults: defaults))
        defaults.set(false, forKey: ApprovalContextMapSettings.enabledKey)
        XCTAssertFalse(ApprovalContextMapSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: ApprovalContextMapSettings.enabledKey)
        XCTAssertTrue(ApprovalContextMapSettings.isEnabled(defaults: defaults))
    }

    func testShouldShowRespectsToggleAndContent() {
        let session = makeSession()
        let map = ApprovalContextMapBuilder.build(session: session)
        XCTAssertTrue(map.hasContent)
        XCTAssertTrue(ApprovalContextMapView.shouldShow(map: map, enabled: true))
        XCTAssertFalse(ApprovalContextMapView.shouldShow(map: map, enabled: false))
        XCTAssertFalse(ApprovalContextMapView.shouldShow(map: .empty, enabled: true))
    }
}
