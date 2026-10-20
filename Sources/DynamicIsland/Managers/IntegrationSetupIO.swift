import Foundation

/// 同步文件 API 在独立执行器运行；取消一直传到实际执行文件工作的 Task。
enum IntegrationSetupIO {
    static func run<Result: Sendable>(_ operation: @escaping @Sendable () throws -> Result) async throws -> Result {
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let result = try operation()
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
