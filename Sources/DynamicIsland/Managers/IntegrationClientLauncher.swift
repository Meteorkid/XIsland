import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class IntegrationClientLauncher {
    enum FailureKind: Equatable {
        case applicationMissing
        case launchFailed
    }

    struct Failure: Equatable {
        let agent: AgentType
        let kind: FailureKind

        func message(language: String) -> String {
            let name = agent.displayName
            switch kind {
            case .applicationMissing:
                return language.hasPrefix("zh")
                    ? "未找到 \(name) 桌面应用。请检查是否已安装，或手动打开 \(name) 继续接入；仅使用命令行版本时请查看接入指南。"
                    : "The \(name) desktop app could not be found. Check that it is installed, or open \(name) manually to continue. See the setup guide if you use the command-line version."
            case .launchFailed:
                return language.hasPrefix("zh")
                    ? "未能打开 \(name)。请手动打开客户端；若仍无法打开，请检查安装后重试。"
                    : "Could not open \(name). Open the app manually. If it still cannot open, check its installation and try again."
            }
        }
    }

    private enum LaunchError: Error {
        case applicationNotReturned
    }

    private(set) var failure: Failure?
    private(set) var openingAgent: AgentType?
    private let openApplication: @MainActor (URL) async throws -> Void
    private var activeRequestID: UUID?

    init(openApplication: @escaping @MainActor (URL) async throws -> Void = { url in
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application != nil {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: LaunchError.applicationNotReturned)
                }
            }
        }
    }) {
        self.openApplication = openApplication
    }

    func open(_ agent: AgentType, at url: URL?) async -> Bool {
        guard openingAgent == nil else { return false }
        failure = nil
        guard let url else {
            failure = Failure(agent: agent, kind: .applicationMissing)
            return false
        }

        let requestID = UUID()
        activeRequestID = requestID
        openingAgent = agent
        defer {
            if activeRequestID == requestID {
                openingAgent = nil
                activeRequestID = nil
            }
        }
        do {
            try await openApplication(url)
            return activeRequestID == requestID
        } catch {
            guard activeRequestID == requestID else { return false }
            failure = Failure(agent: agent, kind: .launchFailed)
            return false
        }
    }

    func reset() {
        // 仅让旧请求失效；已交给系统的客户端启动不应被终止。
        activeRequestID = nil
        openingAgent = nil
        failure = nil
    }
}
