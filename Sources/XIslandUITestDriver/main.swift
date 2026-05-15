import Foundation

do {
    let configuration = try UITestDriverConfiguration.make(arguments: Array(CommandLine.arguments.dropFirst()))
    let selection = try UITestRunSelection.make(arguments: configuration.scenarioArguments)

    try AXUIHelpers.requireAccessibilityTrust()

    let runner = UITestScenarioRunner(
        appBundlePath: configuration.appBundlePath,
        timeout: configuration.timeout
    )

    for scenario in selection.scenarios {
        print("==> Running \(scenario.name)")
        try runner.run(scenario)
        print("PASS \(scenario.name)")
    }
} catch {
    fputs("XIslandUITestDriver failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
