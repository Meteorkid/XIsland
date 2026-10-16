import XCTest
@testable import DIBridge

final class CodyMessageFramerTests: XCTestCase {
    private func frame(_ text: String) -> Data {
        Data("Content-Length: \(text.utf8.count)\r\n\r\n\(text)".utf8)
    }

    func testEveryByteSplitAndCoalescedUTF8Bodies() {
        let first = "{\"reply\":\"中文🪼\"}"
        let input = frame(first) + frame("{}")
        for split in 0...input.count {
            let decoder = CodyMessageFramer()
            var frames: [Data] = []
            decoder.consume(Data(input.prefix(split))) { frames.append($0) }
            decoder.consume(Data(input.dropFirst(split))) { frames.append($0) }
            decoder.finish()
            XCTAssertEqual(frames, [Data(first.utf8), Data("{}".utf8)])
            XCTAssertFalse(decoder.stopped)
        }
    }

    func testInvalidLengthStopsWithoutResynchronizing() {
        for header in ["Content-Length: -1", "Content-Length: 1.0", "Content-Length: 9999999999999999999999",
                       "Content-Length: 5", "Content-Length: 1\r\nContent-Length: 1", "Other: 1"] {
            let decoder = CodyMessageFramer(maximumBody: 4)
            var output: [Data] = []
            decoder.consume(Data((header + "\r\n\r\n").utf8) + frame("{}")) { output.append($0) }
            XCTAssertTrue(decoder.stopped, header)
            XCTAssertTrue(output.isEmpty, header)
            decoder.consume(frame("{}")) { output.append($0) }
            XCTAssertTrue(output.isEmpty)
        }
    }

    func testHeaderLimitAndTruncatedEOF() {
        for bytes in [Data(repeating: 65, count: 8193), Data("Content-Length: 3\r\n\r\n{".utf8), Data("Content-L".utf8)] {
            let decoder = CodyMessageFramer()
            var count = 0
            decoder.consume(bytes) { _ in count += 1 }
            decoder.finish()
            XCTAssertTrue(decoder.stopped)
            XCTAssertEqual(count, 0)
        }
    }

    func testAdditionalHeadersCaseAndZeroLength() {
        let decoder = CodyMessageFramer()
        var frames: [Data] = []
        decoder.consume(Data("content-length: 0\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n".utf8) + frame("{}")) { frames.append($0) }
        XCTAssertEqual(frames, [Data(), Data("{}".utf8)])
        XCTAssertFalse(decoder.stopped)
    }
}
