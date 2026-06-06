import Darwin
import Foundation

/// Encapsulates `flock` single-instance locking (used by app + tests).
enum SingleInstanceLock {
    enum AcquireResult: Equatable {
        /// Holds an open file descriptor; caller must keep it open for the lock lifetime.
        case acquired(fileDescriptor: Int32)
        /// Another running instance holds `LOCK_EX`.
        case alreadyRunning
        /// `open()` / lock file path is unusable — do not start a second socket server.
        case lockFileUnavailable
    }

    /// - Parameter lockFilePath: Absolute path to the lock file.
    static func acquire(lockFilePath: String) -> AcquireResult {
        let fd = open(lockFilePath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            return .lockFileUnavailable
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return .alreadyRunning
        }
        return .acquired(fileDescriptor: fd)
    }
}
