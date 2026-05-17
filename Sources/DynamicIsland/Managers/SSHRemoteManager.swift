import Foundation
import DIShared

// MARK: - Input Validation

enum SSHValidationError: LocalizedError {
    case invalidHost(String)
    case invalidUser(String)
    case invalidPath(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidHost(let host):
            return "Invalid SSH host: \(host). Only alphanumeric, dots, hyphens, and underscores allowed."
        case .invalidUser(let user):
            return "Invalid SSH user: \(user). Only alphanumeric, dots, hyphens, and underscores allowed."
        case .invalidPath(let label, let path):
            return "Invalid \(label): \(path). Only alphanumeric, dots, slashes, hyphens, underscores, tildes, and colons allowed."
        }
    }
}

private enum SSHInputValidator {
    private static let hostPattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9._-]+$")
    private static let userPattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9._-]+$")
    private static let pathPattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9._/~:-]+$")

    private static func matches(_ string: String, regex: NSRegularExpression) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return regex.firstMatch(in: string, range: range) != nil
    }

    static func validateHost(_ host: String) throws -> String {
        guard matches(host, regex: hostPattern) else {
            throw SSHValidationError.invalidHost(host)
        }
        return host
    }

    static func validateUser(_ user: String) throws -> String {
        guard matches(user, regex: userPattern) else {
            throw SSHValidationError.invalidUser(user)
        }
        return user
    }

    static func validatePort(_ port: UInt16) -> UInt16 { port }

    static func validatePath(_ path: String, label: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
            .replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
        guard matches(expanded, regex: pathPattern) else {
            throw SSHValidationError.invalidPath(label, expanded)
        }
        return expanded
    }
}

/// Represents one remote server where AI agents may run.
struct SSHRemoteServer: Identifiable, Codable, Sendable {
    let id: UUID
    var label: String
    var host: String
    var port: Int
    var user: String
    var identityFile: String?
    /// Path to di-bridge on this remote (default: ~/.xisland/bin/di-bridge)
    var remoteBridgePath: String
    /// Local socket path that tunnels to the remote bridge
    var localTunnelSocket: String
    var connected: Bool

    init(id: UUID = UUID(), label: String, host: String, port: Int = 22, user: String,
         identityFile: String? = nil, remoteBridgePath: String = "$HOME/.xisland/bin/di-bridge") {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
        self.remoteBridgePath = remoteBridgePath

        let safeLabel = label.replacingOccurrences(of: " ", with: "_")
        let sockName = "di-remote-\(id.uuidString.prefix(8))-\(safeLabel).sock"
        self.localTunnelSocket = "\(DISocketConfig.socketDir)/\(sockName)"

        self.connected = false
    }
}

/// Manages remote SSH servers so agents running on them can be monitored locally.
@Observable
final class SSHRemoteManager {
    var servers: [SSHRemoteServer] = []
    var isDeploying = false
    private var savedPath: String { "\(DISocketConfig.socketDir)/remote-servers.json" }

    init() {
        load()
    }

    // MARK: - Persistence

    func save() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: URL(fileURLWithPath: savedPath))
    }

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: savedPath)),
              let list = try? JSONDecoder().decode([SSHRemoteServer].self, from: data)
        else { return }
        servers = list
    }

    // MARK: - Server management

    func addServer(label: String, host: String, port: Int = 22, user: String, identityFile: String? = nil) {
        let server = SSHRemoteServer(
            label: label, host: host, port: port, user: user, identityFile: identityFile
        )
        servers.append(server)
        save()
    }

    func removeServer(_ server: SSHRemoteServer) {
        // Kill any active tunnel first
        stopTunnel(for: server)
        servers.removeAll { $0.id == server.id }
        save()
    }

    // MARK: - Bridge deployment

    /// SCP the bundled di-bridge to the remote ~/.xisland/bin/
    func deployBridge(to server: SSHRemoteServer) async throws {
        isDeploying = true
        defer { isDeploying = false }

        let validatedHost = try SSHInputValidator.validateHost(server.host)
        let validatedUser = try SSHInputValidator.validateUser(server.user)
        let validatedPath = try SSHInputValidator.validatePath(server.remoteBridgePath, label: "remote bridge path")
        let remoteDir = (validatedPath as NSString).deletingLastPathComponent

        let localBridge = Bundle.main.bundlePath + "/Contents/MacOS/di-bridge"

        // SSH base args (shared by mkdir and chmod)
        var sshBaseArgs = ["-p", "\(server.port)"]
        if let idFile = server.identityFile {
            sshBaseArgs += ["-i", idFile]
        }
        let sshDest = "\(validatedUser)@\(validatedHost)"

        // Step 1: mkdir -p on remote
        try await runRemoteCommand(
            executable: "/usr/bin/ssh",
            args: sshBaseArgs + [sshDest, "mkdir -p \(remoteDir)"],
            label: "mkdir"
        )

        // Step 2: scp bridge binary
        var scpArgs = ["-P", "\(server.port)"]
        if let idFile = server.identityFile {
            scpArgs += ["-i", idFile]
        }
        scpArgs += [localBridge, "\(sshDest):\(validatedPath)"]
        try await runRemoteCommand(
            executable: "/usr/bin/scp",
            args: scpArgs,
            label: "scp"
        )

        // Step 3: chmod +x
        try await runRemoteCommand(
            executable: "/usr/bin/ssh",
            args: sshBaseArgs + [sshDest, "chmod +x \(validatedPath)"],
            label: "chmod"
        )

        // Mark as connected
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx].connected = true
            save()
        }
    }

    // MARK: - SSH Tunnel

    /// Start an SSH tunnel that forwards the remote di-bridge socket to a local socket.
    /// The remote di-bridge writes to its local socket; we tunnel that connection.
    ///
    /// When an agent runs on the remote server and the hook fires:
    ///   remote di-bridge → remote unix socket → SSH tunnel → local unix socket → SocketServer
    func startTunnel(for server: SSHRemoteServer) throws -> Process {
        let validatedHost = try SSHInputValidator.validateHost(server.host)
        let validatedUser = try SSHInputValidator.validateUser(server.user)

        // Remove stale socket
        try? FileManager.default.removeItem(atPath: server.localTunnelSocket)

        // SSH remote port forwarding: remote socket → local socket
        var args = ["-N", "-p", "\(server.port)"]
        if let idFile = server.identityFile {
            args += ["-i", idFile]
        }
        args += [
            "-L", "\(server.localTunnelSocket):\(DISocketConfig.socketPath)",
            "\(validatedUser)@\(validatedHost)"
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        try process.run()

        // Ensure the local socket directory exists and listen on the tunnel port
        try? FileManager.default.createDirectory(
            atPath: DISocketConfig.socketDir,
            withIntermediateDirectories: true
        )

        return process
    }

    func stopTunnel(for server: SSHRemoteServer) {
        // Validate host before using in pkill pattern to prevent injection
        guard let validatedHost = try? SSHInputValidator.validateHost(server.host) else { return }

        // Find and kill the SSH process for this server
        let marker = "\(DISocketConfig.socketPath):\(validatedHost)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", marker]
        try? process.run()
        process.waitUntilExit()

        // Clean up local tunnel socket
        try? FileManager.default.removeItem(atPath: server.localTunnelSocket)

        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx].connected = false
            save()
        }
    }

    /// Verify the SSH connection works and the bridge binary exists on the remote.
    func verifyConnection(for server: SSHRemoteServer) async throws -> String {
        let validatedHost = try SSHInputValidator.validateHost(server.host)
        let validatedUser = try SSHInputValidator.validateUser(server.user)
        let validatedPath = try SSHInputValidator.validatePath(server.remoteBridgePath, label: "remote bridge path")

        var args = ["-p", "\(server.port)"]
        if let idFile = server.identityFile {
            args += ["-i", idFile]
        }
        args += [
            "\(validatedUser)@\(validatedHost)",
            "test -x \(validatedPath) && echo OK || echo BRIDGE_NOT_FOUND"
        ]

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = args
            process.standardOutput = pipe

            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "SSHRemote",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "SSH connection failed"]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Toggle the tunnel for a server on/off.
    func toggleTunnel(for server: SSHRemoteServer) {
        if server.connected {
            stopTunnel(for: server)
        } else {
            Task {
                try? await deployBridge(to: server)
                _ = try? startTunnel(for: server)
            }
        }
    }

    /// Create the remote hook configuration on a server to point at the tunneled socket.
    /// This generates a one-liner that the user should add to their remote agent config.
    func remoteHookSetupCommand(for server: SSHRemoteServer) -> String {
        let validatedPath = (try? SSHInputValidator.validatePath(server.remoteBridgePath, label: "remote bridge path"))
            ?? server.remoteBridgePath
        let socketEnv = "export DI_SOCKET_PATH=\(DISocketConfig.socketPath)"
        let bridgeCmd = "\(validatedPath) --agent claude_code --hook"
        return """
        # On the remote server, add this to your ~/.profile or ~/.zshrc:
        \(socketEnv)
        # Then configure your agent hooks as usual; di-bridge will connect through the tunnel.
        # Example: \(bridgeCmd) session_start || true
        """
    }

    // MARK: - Private helpers

    /// Run a remote command via Process with direct arguments (no shell interpolation).
    private func runRemoteCommand(executable: String, args: [String], label: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: NSError(
                        domain: "SSHRemote",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "\(label) failed: \(output)"]
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
