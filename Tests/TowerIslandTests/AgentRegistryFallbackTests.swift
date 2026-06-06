import XCTest
@testable import XIsland

final class AgentRegistryFallbackTests: XCTestCase {
    func testEveryAgentTypeHasRegistryMeta() {
        for type in AgentType.allCases {
            XCTAssertFalse(type.displayName.isEmpty, "Missing displayName for \(type)")
            XCTAssertFalse(type.shortName.isEmpty, "Missing shortName for \(type)")
            XCTAssertFalse(type.iconSymbol.isEmpty, "Missing icon for \(type)")
        }
    }

    func testRegistryContainsKeyForEveryCase() {
        for type in AgentType.allCases {
            XCTAssertNotNil(AgentType.registry[type], "registry missing \(type)")
        }
    }
}
