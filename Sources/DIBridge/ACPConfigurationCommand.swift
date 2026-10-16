import Foundation
import Darwin
import DIShared

enum ACPConfigurationCommand {
    static func run(arguments: [String], bridgePath: String) -> Int32 {
        var arguments = arguments
        let unwrap = arguments.first == "--unwrap"
        if unwrap { arguments.removeFirst() }
        guard arguments.count == 4, arguments[0] == "--host", arguments[2] == "--source", isatty(STDIN_FILENO) == 0 else {
            fputs("用法：di-bridge acp-config [--unwrap] --host zed|jetbrains_ai --source 名称 < 单个Agent条目.json\n", stderr)
            return 64
        }
        do {
            _ = try ACPEventObserver(host: arguments[1], source: arguments[3])
            var data = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
                data.append(chunk)
                if data.count > 1_048_576 { throw ACPRunner.RunnerError.invalidArguments }
            }
            guard let entry = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bridge = AiderLauncher.executablePath(bridgePath, environment: ProcessInfo.processInfo.environment) else {
                throw ACPRunner.RunnerError.invalidArguments
            }
            let result = try unwrap
                ? ACPCustomAgentConfiguration.unwrapping(entry, host: arguments[1], source: arguments[3])
                : ACPCustomAgentConfiguration.wrapping(entry, host: arguments[1], source: arguments[3], bridgePath: bridge)
            var output = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            output.append(10)
            try FileHandle.standardOutput.write(contentsOf: output)
            return 0
        } catch {
            fputs("[XIsland] 无法变换该 ACP 条目；只接受明确的自定义 Agent JSON，未修改任何文件。\n", stderr)
            return 65
        }
    }
}
