import Foundation
import Darwin
import DIShared

enum KiroConfigurationCommand {
    static func run(arguments: [String], bridgePath: String) -> Int32 {
        guard isatty(STDIN_FILENO) == 0 else {
            usage()
            return 64
        }
        do {
            var data = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= 1_048_576 else { throw KiroHookConfiguration.ConfigurationError.invalidDocument }
            }
            guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bridge = AiderLauncher.executablePath(bridgePath, environment: ProcessInfo.processInfo.environment) else {
                throw KiroHookConfiguration.ConfigurationError.invalidDocument
            }
            let output = try transform(document, arguments: arguments, bridgePath: bridge)
            var encoded = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            encoded.append(10)
            try FileHandle.standardOutput.write(contentsOf: encoded)
            return 0
        } catch {
            fputs("[XIsland] Kiro V3 配置导出失败；只接受明确版本及有效独立 Hook JSON，未修改任何文件。\n", stderr)
            usage()
            return 65
        }
    }

    static func transform(_ document: [String: Any], arguments: [String], bridgePath: String) throws -> [String: Any] {
        if arguments == ["--remove"] { return try KiroHookConfiguration.removing(from: document) }
        guard arguments.count == 4, arguments[0] == "--cli-version", arguments[2] == "--engine" else {
            throw KiroHookConfiguration.ConfigurationError.unsupportedRuntime
        }
        return try KiroHookConfiguration.merging(into: document, bridgePath: bridgePath,
            cliVersion: arguments[1], engine: arguments[3])
    }

    private static func usage() {
        fputs("用法：di-bridge kiro-config-v3 --cli-version 2.31.0 --engine v3 < hooks.json\n       di-bridge kiro-config-v3 --remove < hooks.json\n", stderr)
    }
}
