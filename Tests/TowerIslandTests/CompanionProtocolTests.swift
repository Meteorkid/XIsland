import XCTest
@testable import CompanionShared

/// 伴端协议：容错解码、优先级、摘要预算、命令携带 sessionId。
final class CompanionProtocolTests: XCTestCase {

    // MARK: 容错解码

    func testUnknownPhaseFallsBackToIdleInsteadOfThrowing() throws {
        // 较新的 Mac 端可能送来本版本没见过的阶段值。
        // 抛错会让整份快照解码失败——在 watchOS 上表现为每次启动都崩。
        let json = Data(#"{"id":"s1","agent":"Claude","title":"t","project":"p","phase":"teleporting","updatedAt":"2026-11-04T00:00:00Z"}"#.utf8)
        let session = try CompanionCodec.decoder().decode(CompanionSession.self, from: json)
        XCTAssertEqual(session.phase, .idle)
    }

    func testKnownPhaseDecodesNormally() throws {
        let json = Data(#"{"id":"s1","agent":"Claude","title":"t","project":"p","phase":"waitingApproval","updatedAt":"2026-11-04T00:00:00Z"}"#.utf8)
        let session = try CompanionCodec.decoder().decode(CompanionSession.self, from: json)
        XCTAssertEqual(session.phase, .waitingApproval)
    }

    // MARK: 排序

    func testPendingSessionsSortFirstAndByRecencyWithinPhase() {
        let old = session("old", phase: .waitingApproval, at: 100)
        let new = session("new", phase: .waitingApproval, at: 200)
        let busy = session("busy", phase: .running, at: 300)
        let idle = session("idle", phase: .idle, at: 400)

        let snapshot = CompanionSnapshot(sequence: 1, generatedAt: Date(), sessions: [idle, busy, old, new])
        XCTAssertEqual(snapshot.ordered.map(\.id), ["new", "old", "busy", "idle"])
        XCTAssertEqual(snapshot.pendingCount, 2)
    }

    func testApprovalOutranksQuestion() {
        let question = session("q", phase: .waitingQuestion, at: 900)
        let approval = session("a", phase: .waitingApproval, at: 100)
        let snapshot = CompanionSnapshot(sequence: 1, generatedAt: Date(), sessions: [question, approval])
        XCTAssertEqual(snapshot.ordered.first?.id, "a")
    }

    // MARK: 摘要

    func testDigestKeepsOnlyTheMostUrgentSession() {
        let snapshot = CompanionSnapshot(
            sequence: 7,
            generatedAt: Date(),
            sessions: [session("busy", phase: .running, at: 100),
                       session("wait", phase: .waitingApproval, at: 50)]
        )
        let digest = CompanionDigest(snapshot: snapshot)
        XCTAssertEqual(digest.focus?.id, "wait")
        XCTAssertEqual(digest.totalCount, 2)
        XCTAssertEqual(digest.pendingCount, 1)
        XCTAssertEqual(digest.sequence, 7)
    }

    func testEmptySnapshotProducesDigestWithoutFocus() {
        let digest = CompanionDigest(snapshot: CompanionSnapshot(sequence: 1, generatedAt: Date(), sessions: []))
        XCTAssertNil(digest.focus)
        XCTAssertEqual(digest.totalCount, 0)
    }

    func testDigestStaysWithinBluetoothBudget() throws {
        // 蓝牙通道单包有限，摘要必须远小于它。
        let long = session(String(repeating: "x", count: 36), phase: .waitingApproval, at: 100)
        let digest = CompanionDigest(snapshot: CompanionSnapshot(sequence: 42, generatedAt: Date(), sessions: [long]))
        let data = try CompanionCodec.encode(digest)
        XCTAssertLessThanOrEqual(data.count, CompanionCodec.digestByteBudget)
    }

    // MARK: 命令

    func testCommandRoundTripsThroughJSON() throws {
        let commands: [CompanionCommand] = [
            .requestState,
            .approve(sessionId: "abc"),
            .deny(sessionId: "def"),
            .answer(sessionId: "ghi", text: "用方案 B")
        ]
        for command in commands {
            let data = try CompanionCodec.encode(command)
            let decoded = try CompanionCodec.decodeCommand(data)
            XCTAssertEqual(decoded, command)
        }
    }

    func testOnlyDecisionCommandsCountAsDecidingForTheUser() {
        XCTAssertFalse(CompanionCommand.requestState.decidesForTheUser)
        XCTAssertTrue(CompanionCommand.approve(sessionId: "a").decidesForTheUser)
        XCTAssertTrue(CompanionCommand.deny(sessionId: "a").decidesForTheUser)
        XCTAssertTrue(CompanionCommand.answer(sessionId: "a", text: "x").decidesForTheUser)
    }

    func testDecisionCommandsCarrySessionId() {
        // 缺 sessionId 就可能批准到队首那条，而不是用户看到的那条。
        XCTAssertNil(CompanionCommand.requestState.sessionId)
        XCTAssertEqual(CompanionCommand.approve(sessionId: "s9").sessionId, "s9")
        XCTAssertEqual(CompanionCommand.answer(sessionId: "s8", text: "x").sessionId, "s8")
    }

    // MARK: 能力位

    func testAllowsDecisionsDefaultsToFalseWhenFieldAbsent() throws {
        // 旧版 Mac 不带该字段。默认必须收紧，否则任何连上来的设备都能自行审批。
        let json = Data(#"{"protocolVersion":1,"sequence":3,"generatedAt":"2026-11-04T00:00:00Z","sessions":[]}"#.utf8)
        let snapshot = try CompanionCodec.decodeSnapshot(json)
        XCTAssertFalse(snapshot.allowsDecisions)
    }

    func testAllowsDecisionsSurvivesRoundTrip() throws {
        let snapshot = CompanionSnapshot(sequence: 1, generatedAt: Date(),
                                         sessions: [], allowsDecisions: true)
        let decoded = try CompanionCodec.decodeSnapshot(CompanionCodec.encode(snapshot))
        XCTAssertTrue(decoded.allowsDecisions)
    }

    func testDigestInheritsCapabilityFromSnapshot() {
        let snapshot = CompanionSnapshot(
            sequence: 5, generatedAt: Date(),
            sessions: [session("a", phase: .waitingApproval, at: 10)],
            allowsDecisions: true
        )
        let digest = CompanionDigest(snapshot: snapshot)
        XCTAssertTrue(digest.allowsDecisions, "摘要必须带上能力位，否则手表无法决定是否显示按钮")
    }

    func testDigestWithoutFieldAlsoDefaultsToFalse() throws {
        let json = Data(#"{"protocolVersion":1,"sequence":1,"totalCount":0,"pendingCount":0}"#.utf8)
        let digest = try CompanionCodec.decodeDigest(json)
        XCTAssertFalse(digest.allowsDecisions)
        XCTAssertNil(digest.focus)
    }

    // MARK: 双通道序号

    func testDigestAndSnapshotShareOneSequenceNumber() {
        // 摘要是"同一时刻状态的精简视图"，不是独立的一次发布。
        // 若各自递增，伴端两个通道的游标会错位。
        let snapshot = CompanionSnapshot(sequence: 42, generatedAt: Date(),
                                         sessions: [session("a", phase: .running, at: 1)])
        let digest = CompanionDigest(snapshot: snapshot)
        XCTAssertEqual(digest.sequence, snapshot.sequence,
                       "摘要必须复用快照序号，否则伴端会把快照当旧包丢弃")
    }

    func testIndependentChannelCursorsBothAdvance() {
        // 模拟 iOS 端的分通道判定：同一序号在两条通道上都应被接受。
        var snapshotCursor: UInt64 = 0
        var digestCursor: UInt64 = 0

        func accept(_ value: UInt64, snapshotChannel: Bool) -> Bool {
            if snapshotChannel {
                guard value > snapshotCursor else { return false }
                snapshotCursor = value
            } else {
                guard value > digestCursor else { return false }
                digestCursor = value
            }
            return true
        }

        let snapshot = CompanionSnapshot(sequence: 7, generatedAt: Date(), sessions: [])
        let digest = CompanionDigest(snapshot: snapshot)

        XCTAssertTrue(accept(digest.sequence, snapshotChannel: false))
        // 关键：快照紧接着到达，序号相同。若共用一个游标这里会失败。
        XCTAssertTrue(accept(snapshot.sequence, snapshotChannel: true),
                      "摘要推高游标后，同序号的快照仍必须被接受")
    }

    // MARK: 对端名截断

    func testPeerNameTruncatesByBytesNotCharacters() {
        // MCPeerID 上限是 63 字节。一个汉字 3 字节，22 个汉字即越界——
        // 用 prefix(63)（按字符）拦不住，会导致不可捕获的异常。
        let longChinese = String(repeating: "测", count: 40)
        XCTAssertGreaterThan(longChinese.utf8.count, CompanionPeerName.maximumBytes)

        let sanitized = CompanionPeerName.sanitized(longChinese)
        XCTAssertLessThanOrEqual(sanitized.utf8.count, CompanionPeerName.maximumBytes)
        XCTAssertFalse(sanitized.isEmpty)
        // 不应切出半个字符：结果必须仍是合法字符串。
        XCTAssertEqual(sanitized, String(sanitized))
    }

    func testPeerNameKeepsShortNamesIntact() {
        XCTAssertEqual(CompanionPeerName.sanitized("XIsland MacBook"), "XIsland MacBook")
        XCTAssertEqual(CompanionPeerName.sanitized("XIsland 刘鑫宇的 Mac"), "XIsland 刘鑫宇的 Mac")
    }

    func testPeerNameFallsBackWhenEmpty() {
        XCTAssertEqual(CompanionPeerName.sanitized("   ", fallback: "iPhone"), "iPhone")
        XCTAssertEqual(CompanionPeerName.sanitized("", fallback: "Mac"), "Mac")
    }

    func testPeerNameTruncationStaysOnGraphemeBoundary() {
        // 混入 emoji（4 字节）验证不会切坏字素簇。
        let mixed = String(repeating: "a", count: 60) + "😀😀😀"
        let sanitized = CompanionPeerName.sanitized(mixed)
        XCTAssertLessThanOrEqual(sanitized.utf8.count, CompanionPeerName.maximumBytes)
        // 60 个 a 用掉 60 字节，只剩 3 字节，放不下 4 字节的 emoji。
        XCTAssertEqual(sanitized, String(repeating: "a", count: 60))
    }

    // MARK: 序列号

    func testSequenceIsMonotonic() {
        var sequence = CompanionSequence()
        XCTAssertEqual(sequence.next(), 1)
        XCTAssertEqual(sequence.next(), 2)
        XCTAssertEqual(sequence.current, 2)
    }

    // MARK: Helpers

    private func session(_ id: String, phase: CompanionPhase, at seconds: TimeInterval) -> CompanionSession {
        CompanionSession(id: id, agent: "Claude Code", title: "task \(id)", project: "proj",
                         phase: phase, updatedAt: Date(timeIntervalSince1970: seconds))
    }
}
