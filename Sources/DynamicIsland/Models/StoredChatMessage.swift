import Foundation
import SwiftData

@Model
final class StoredChatMessage {
    var messageId: UUID? = nil
    var timestamp: Date
    var role: String
    var content: String

    var session: StoredSession?

    init(from message: ChatMessage) {
        self.messageId = message.id
        self.timestamp = message.timestamp
        self.role = message.role.rawValue
        self.content = message.content
    }

    func update(from message: ChatMessage) {
        messageId = message.id
        timestamp = message.timestamp
        role = message.role.rawValue
        content = message.content
    }

    /// Internal initializer for SwiftData (all stored properties).
    init(timestamp: Date = Date(), role: String = "user", content: String = "") {
        self.timestamp = timestamp
        self.role = role
        self.content = content
    }
}
