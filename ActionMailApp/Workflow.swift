import Foundation

public enum WorkflowState: String, Codable, CaseIterable, Identifiable, Sendable {
    case action = "Action"
    case waiting = "Waiting"
    case readLater = "Read Later"
    case done = "Done"

    public var id: Self { self }

    /// Apple Mail flag indices: red 0, orange 1, green 3, blue 4.
    public var mailFlagIndex: Int {
        switch self {
        case .action: 0
        case .waiting: 1
        case .readLater: 4
        case .done: 3
        }
    }
}

public struct MessageSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let subject: String
    public let sender: String
    public let receivedAt: Date
    public let headers: [String: [String]]

    public init(
        id: String,
        subject: String,
        sender: String,
        receivedAt: Date,
        headers: [String: [String]] = [:]
    ) {
        self.id = id
        self.subject = subject
        self.sender = sender
        self.receivedAt = receivedAt
        self.headers = headers
    }

    public var referencedMessageIDs: Set<String> {
        let values = headers.firstValue(for: "In-Reply-To") + headers.firstValue(for: "References")
        return Set(values.flatMap(Self.messageIDs(in:)))
    }

    private static func messageIDs(in value: String) -> [String] {
        value.matches(of: /<([^>]+)>/).map { String($0.1) }
    }
}

public struct WaitingThread: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let outboundMessageID: String
    public let subject: String
    public let recipient: String
    public let sentAt: Date
    public var state: WorkflowState
    public var threadMessageIDs: Set<String>
    public var completedAt: Date?
    public var isArchived: Bool

    public init(
        id: UUID = UUID(),
        outboundMessageID: String,
        subject: String,
        recipient: String,
        sentAt: Date,
        state: WorkflowState = .waiting,
        threadMessageIDs: Set<String> = [],
        completedAt: Date? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.outboundMessageID = outboundMessageID
        self.subject = subject
        self.recipient = recipient
        self.sentAt = sentAt
        self.state = state
        self.threadMessageIDs = threadMessageIDs.union([outboundMessageID])
        self.completedAt = completedAt
        self.isArchived = isArchived
    }

    private enum CodingKeys: String, CodingKey {
        case id, outboundMessageID, subject, recipient, sentAt, state
        case threadMessageIDs, completedAt, isArchived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        outboundMessageID = try container.decode(String.self, forKey: .outboundMessageID)
        subject = try container.decode(String.self, forKey: .subject)
        recipient = try container.decode(String.self, forKey: .recipient)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        state = try container.decode(WorkflowState.self, forKey: .state)
        threadMessageIDs = try container.decode(Set<String>.self, forKey: .threadMessageIDs)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(outboundMessageID, forKey: .outboundMessageID)
        try container.encode(subject, forKey: .subject)
        try container.encode(recipient, forKey: .recipient)
        try container.encode(sentAt, forKey: .sentAt)
        try container.encode(state, forKey: .state)
        try container.encode(threadMessageIDs, forKey: .threadMessageIDs)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(isArchived, forKey: .isArchived)
    }
}

public enum WorkflowDecision: Equatable, Sendable {
    case noChange
    case markAction(waitingThreadID: UUID)
}

public struct WorkflowEngine: Sendable {
    public init() {}

    public func classifyIncoming(
        _ message: MessageSnapshot,
        waitingThreads: [WaitingThread]
    ) -> WorkflowDecision {
        guard let match = waitingThreads.first(where: {
            $0.state == .waiting && message.referencedMessageIDs.contains($0.outboundMessageID)
        }) else {
            return .noChange
        }
        return .markAction(waitingThreadID: match.id)
    }
}

private extension Dictionary where Key == String, Value == [String] {
    func firstValue(for header: String) -> [String] {
        first { $0.key.caseInsensitiveCompare(header) == .orderedSame }?.value ?? []
    }
}
