import XCTest
import SwiftUI
@testable import XIsland

final class AgentMascotFamilyTests: XCTestCase {
    func testEveryClientHasAnExclusiveFamily() {
        let families = AgentType.allCases.map { AgentMascotFamily.forAgent($0) }
        XCTAssertEqual(Set(families).count, AgentType.allCases.count)
        XCTAssertFalse(families.contains(.unknown))
        XCTAssertEqual(Set(families), Set(AgentMascotFamily.allCases.filter { $0 != .unknown }))
    }

    func testRobotIsExclusiveToCodexAndUnknownIsExplicit() {
        XCTAssertEqual(AgentMascotFamily.forAgent(.codex), .robot)
        XCTAssertEqual(AgentType.allCases.filter { AgentMascotFamily.forAgent($0) == .robot }, [.codex])
        XCTAssertEqual(AgentMascotFamily.forAgent(nil), .unknown)
        XCTAssertEqual(AgentMascotFamily.forAgent(.hermes), .wingedEnvelope)
        XCTAssertEqual(AgentMascotFamily.robot.faceScale, 1)
        XCTAssertEqual(AgentMascotFamily.robot.faceOffset, .zero)
    }

    func testStableFamilyIDsAreNonemptyAndUnique() {
        let ids = AgentMascotFamily.allCases.map(\.id)
        XCTAssertTrue(ids.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(AgentMascotFamily.robot.id, "robot")
        XCTAssertEqual(AgentMascotFamily.unknown.id, "unknown")
    }

    func testSilhouettesRemainDistinctAtSmallSize() {
        let rect = CGRect(x: 0, y: 0, width: 20, height: 20)
        var fingerprints: [String: AgentMascotFamily] = [:]
        for family in AgentMascotFamily.allCases {
            let path = AgentMascotShape(family: family).path(in: rect)
            let fingerprint = (0..<400).map { index in
                path.contains(CGPoint(x: CGFloat(index % 20) + 0.5,
                                      y: CGFloat(index / 20) + 0.5)) ? "1" : "0"
            }.joined()
            XCTAssertTrue(fingerprint.contains("1"), "Empty silhouette: \(family)")
            XCTAssertNil(fingerprints[fingerprint], "Duplicate silhouette: \(family)")
            fingerprints[fingerprint] = family
        }
    }

    func testFaceAnchorsStayInsideEverySilhouette() {
        // 在实际最小尺寸上检查；1pt 贝塞尔路径的 contains 扁平化精度不足以验证图标。
        let dimension: CGFloat = 20
        let rect = CGRect(x: 0, y: 0, width: dimension, height: dimension)
        // 复用表情的眼睛外缘和嘴部外缘，避免角色特征挤占表情区域。
        let anchors: [(CGFloat, CGFloat)] = [(-0.27, -0.07), (0.27, -0.07),
                                             (-0.15, 0.23), (0.15, 0.23)]
        for family in AgentMascotFamily.allCases {
            let path = AgentMascotShape(family: family).path(in: rect)
            for anchor in anchors {
                let point = CGPoint(x: 0.5 + family.faceOffset.width + anchor.0 * family.faceScale,
                                    y: 0.5 + family.faceOffset.height + anchor.1 * family.faceScale)
                let renderedPoint = CGPoint(x: point.x * dimension, y: point.y * dimension)
                XCTAssertTrue(path.contains(renderedPoint), "Face falls outside \(family) at \(point)")
            }
        }
    }
}
