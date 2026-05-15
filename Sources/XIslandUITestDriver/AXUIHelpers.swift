import ApplicationServices
import Foundation

enum UITestDriverError: LocalizedError {
    case accessibilityNotTrusted
    case timeout(String)
    case missingElement(String)
    case actionFailed(String)
    case launchFailed(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility access is required to run XIslandUITestDriver."
        case .timeout(let message), .missingElement(let message), .actionFailed(let message), .launchFailed(let message), .invalidArguments(let message):
            return message
        }
    }
}

enum AXUIHelpers {
    private static let shortPollInterval: TimeInterval = 0.1

    static func requireAccessibilityTrust() throws {
        guard AXIsProcessTrusted() else {
            throw UITestDriverError.accessibilityNotTrusted
        }
    }

    static func applicationElement(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    static func waitForWindow(
        ownedBy pid: pid_t,
        timeout: TimeInterval,
        where predicate: @escaping (WindowInfo) -> Bool,
        description: String
    ) throws -> WindowInfo {
        try waitUntil(timeout: timeout, description: description) {
            windowList(ownedBy: pid).first(where: predicate)
        }
    }

    static func windowList(ownedBy pid: pid_t) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windows.compactMap { dictionary in
            guard let ownerPID = dictionary[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let boundsDictionary = dictionary[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else {
                return nil
            }

            return WindowInfo(
                windowID: dictionary[kCGWindowNumber as String] as? CGWindowID ?? 0,
                layer: dictionary[kCGWindowLayer as String] as? Int ?? 0,
                bounds: bounds,
                name: dictionary[kCGWindowName as String] as? String,
                ownerName: dictionary[kCGWindowOwnerName as String] as? String
            )
        }
    }

    static func clickCenter(of window: WindowInfo) throws {
        try click(at: CGPoint(x: window.bounds.midX, y: window.bounds.midY))
    }

    static func click(at point: CGPoint) throws {
        guard let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw UITestDriverError.actionFailed("Failed to create mouse events")
        }

        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
    }

    static func sendCommandKey(_ character: Character) throws {
        guard let keyCode = keyCode(for: character) else {
            throw UITestDriverError.actionFailed("Unsupported keyboard shortcut character: \(character)")
        }
        try postKey(keyCode: keyCode, flags: .maskCommand)
    }

    static func waitForElement(
        in application: AXUIElement,
        identifier: String,
        timeout: TimeInterval
    ) throws -> AXUIElement {
        try waitUntil(timeout: timeout, description: "Timed out waiting for accessibility identifier \(identifier)") {
            findElement(in: application, identifier: identifier)
        }
    }

    static func press(_ element: AXUIElement, identifier: String) throws {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            throw UITestDriverError.actionFailed(
                "Failed to press accessibility element \(identifier): \(result.rawValue)"
            )
        }
    }

    static func findElement(in application: AXUIElement, identifier: String) -> AXUIElement? {
        for window in windows(of: application) {
            if matchesIdentifier(window, identifier: identifier) {
                return window
            }

            if let match = descendants(of: window).first(where: { matchesIdentifier($0, identifier: identifier) }) {
                return match
            }
        }

        return nil
    }

    static func windows(of application: AXUIElement) -> [AXUIElement] {
        if let windows = attribute(kAXWindowsAttribute, of: application) as? [AXUIElement], !windows.isEmpty {
            return windows
        }

        if let fallback = attribute(kAXChildrenAttribute, of: application) as? [AXUIElement] {
            return fallback
        }

        return []
    }

    static func stringValue(of element: AXUIElement, attribute name: String) -> String? {
        if let value = attribute(name, of: element) as? String {
            return value
        }

        if let value = attribute(name, of: element) as? NSAttributedString {
            return value.string
        }

        return nil
    }

    static func waitUntil<T>(
        timeout: TimeInterval,
        description: String,
        operation: () throws -> T?
    ) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let value = try operation() {
                return value
            }

            RunLoop.current.run(until: Date().addingTimeInterval(shortPollInterval))
        }

        throw UITestDriverError.timeout(description)
    }

    private static func matchesIdentifier(_ element: AXUIElement, identifier: String) -> Bool {
        stringValue(of: element, attribute: kAXIdentifierAttribute as String) == identifier
    }

    private static func descendants(of root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue = childElements(of: root)
        var visited: Set<CFHashCode> = []

        while !queue.isEmpty {
            let element = queue.removeFirst()
            let key = CFHash(element)
            guard visited.insert(key).inserted else { continue }
            result.append(element)
            queue.append(contentsOf: childElements(of: element))
        }

        return result
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        let attributes = [
            kAXChildrenAttribute as String,
            kAXContentsAttribute as String,
            kAXRowsAttribute as String,
            kAXVisibleChildrenAttribute as String,
        ]

        var children: [AXUIElement] = []

        for attributeName in attributes {
            if let value = attribute(attributeName, of: element) as? [AXUIElement] {
                children.append(contentsOf: value)
            } else if let value = attribute(attributeName, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() {
                let elementValue = unsafeBitCast(value, to: AXUIElement.self)
                children.append(elementValue)
            }
        }

        return children
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success else { return nil }
        return value as AnyObject?
    }

    private static func postKey(keyCode: CGKeyCode, flags: CGEventFlags) throws {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw UITestDriverError.actionFailed("Failed to create keyboard events")
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func keyCode(for character: Character) -> CGKeyCode? {
        switch character {
        case "1": return 18
        case "y", "Y": return 16
        default: return nil
        }
    }
}

struct WindowInfo {
    let windowID: CGWindowID
    let layer: Int
    let bounds: CGRect
    let name: String?
    let ownerName: String?
}
