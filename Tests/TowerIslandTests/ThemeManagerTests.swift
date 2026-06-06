import XCTest
import SwiftUI
@testable import XIsland

@MainActor
final class ThemeManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 使用独立 suite 避免污染 UserDefaults
        UserDefaults(suiteName: "ThemeManagerTests")?.removePersistentDomain(forName: "ThemeManagerTests")
    }

    // MARK: - ThemeManager tests

    func testDefaultModeIsDark() {
        let manager = ThemeManager()
        XCTAssertEqual(manager.mode, .dark)
    }

    func testToggleModeCycles() {
        let manager = ThemeManager()
        // dark -> light
        manager.toggleMode()
        XCTAssertEqual(manager.mode, .light)
        // light -> system
        manager.toggleMode()
        XCTAssertEqual(manager.mode, .system)
        // system -> dark
        manager.toggleMode()
        XCTAssertEqual(manager.mode, .dark)
    }

    func testResolvedSchemeDark() {
        let manager = ThemeManager()
        manager.mode = .dark
        XCTAssertEqual(manager.resolvedScheme, .dark)
    }

    func testResolvedSchemeLight() {
        let manager = ThemeManager()
        manager.mode = .light
        XCTAssertEqual(manager.resolvedScheme, .light)
    }

    func testResolvedSchemeSystem() {
        let manager = ThemeManager()
        manager.mode = .system
        // system 模式返回值取决于系统设置，只验证是有效的 ColorScheme
        let scheme = manager.resolvedScheme
        XCTAssertTrue(scheme == .dark || scheme == .light)
    }

    func testModePersists() {
        let manager = ThemeManager()
        manager.mode = .light
        // 创建新实例验证持久化
        let manager2 = ThemeManager()
        XCTAssertEqual(manager2.mode, .light)
    }

    // MARK: - IslandStyle backward compatibility

    func testIslandStyleBackwardCompat() {
        // 验证向后兼容的无参属性仍然可用
        let _: Color = IslandStyle.surface
        let _: Color = IslandStyle.cardRest
        let _: Color = IslandStyle.cardHover
        let _: Color = IslandStyle.insetFill
        let _: Color = IslandStyle.codeWell
        // 不崩溃即通过
    }

    func testIslandStyleParameterized() {
        let darkSurface = IslandStyle.surface(for: .dark)
        let lightSurface = IslandStyle.surface(for: .light)
        // 深色模式 surface 是黑色，浅色模式是白色，两者应不同
        XCTAssertNotEqual(darkSurface.description, lightSurface.description,
                          "Dark and light surface colors should differ")

        let darkCard = IslandStyle.cardRest(for: .dark)
        let lightCard = IslandStyle.cardRest(for: .light)
        XCTAssertNotEqual(darkCard.description, lightCard.description,
                          "Dark and light card rest colors should differ")
    }
}
