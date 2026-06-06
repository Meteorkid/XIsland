import Darwin
import XCTest
@testable import XIsland

final class AppDelegateSingleInstanceTests: XCTestCase {
    func testSecondAcquireOnSameLockFileReturnsAlreadyRunning() {
        let path = NSTemporaryDirectory() + "xisland-lock-\(UUID().uuidString).lock"
        let first = SingleInstanceLock.acquire(lockFilePath: path)
        guard case .acquired(let fd) = first else {
            XCTFail("Expected first acquire to succeed")
            return
        }
        let second = SingleInstanceLock.acquire(lockFilePath: path)
        XCTAssertEqual(second, .alreadyRunning)
        close(fd)
        unlink(path)
    }

    func testAcquireFailsGracefullyForUnusablePath() {
        let path = "/unlikely/path/that/does/not/exist/xisland-\(UUID().uuidString).lock"
        let result = SingleInstanceLock.acquire(lockFilePath: path)
        XCTAssertEqual(result, .lockFileUnavailable)
    }
}
