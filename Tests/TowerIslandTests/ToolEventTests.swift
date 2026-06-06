import XCTest
@testable import XIsland

final class ToolEventTests: XCTestCase {
    func testPytestParsesPassedWithoutFailedLine() throws {
        let out = "======================== 3 passed in 1.2s ========================"
        let tr = try XCTUnwrap(ToolEvent.parseTestResults(from: out))
        XCTAssertEqual(tr.passed, 3)
        XCTAssertEqual(tr.failed, 0)
        XCTAssertEqual(tr.skipped, 0)
        XCTAssertEqual(tr.total, 3)
    }

    func testPytestIncludesSkipped() throws {
        let out = "2 passed, 1 skipped in 0.5s"
        let tr = try XCTUnwrap(ToolEvent.parseTestResults(from: out))
        XCTAssertEqual(tr.passed, 2)
        XCTAssertEqual(tr.skipped, 1)
    }

    func testJestParsesFailedAndSkipped() throws {
        let out = """
        Tests:       4 failed, 2 skipped, 10 passed, 16 total
        """
        let tr = try XCTUnwrap(ToolEvent.parseTestResults(from: out))
        XCTAssertEqual(tr.passed, 10)
        XCTAssertEqual(tr.failed, 4)
        XCTAssertEqual(tr.skipped, 2)
        XCTAssertEqual(tr.total, 16)
    }

    func testGoPackageSummaryOkLine() throws {
        let out = "ok  \tgithub.com/foo/bar\t0.123s"
        let tr = try XCTUnwrap(ToolEvent.parseTestResults(from: out))
        XCTAssertEqual(tr.passed, 1)
        XCTAssertEqual(tr.failed, 0)
        XCTAssertEqual(tr.total, 1)
    }

    func testGoPackageSummaryFailLine() throws {
        let out = "FAIL\tgithub.com/foo/bar\t0.456s"
        let tr = try XCTUnwrap(ToolEvent.parseTestResults(from: out))
        XCTAssertEqual(tr.passed, 0)
        XCTAssertEqual(tr.failed, 1)
        XCTAssertEqual(tr.total, 1)
    }

    func testEstimateLinesReadCapsAtFiftyThousand() throws {
        let huge = String(repeating: "x\n", count: 60_000)
        let n = try XCTUnwrap(ToolEvent.estimateLinesRead(from: huge))
        XCTAssertEqual(n, 50_000)
    }

    func testEstimateLinesReadReturnsNilForEmpty() {
        XCTAssertNil(ToolEvent.estimateLinesRead(from: ""))
        XCTAssertNil(ToolEvent.estimateLinesRead(from: nil))
    }
}
