import Foundation
import SwiftData

enum CachePolicy {
    static let ttl: TimeInterval = 7 * 24 * 60 * 60
    /// Saved-position windows are refreshed independently from the ordinary
    /// session/message cache. Keeping a distinct expiry prevents a metadata
    /// refresh from making an old transcript snapshot look current.
    static let restorationTTL: TimeInterval = 7 * 24 * 60 * 60
    static let maxMessages = 5_000
    /// Keep one bounded recent window per session. A restored reading anchor
    /// must never turn the offline cache into a copy of the full transcript.
    static let maxMessagesPerSession = 200
    static let maxRestorationMessagesPerSession = 50
}

@Model
final class CachedSession {
    @Attribute(.unique) var cacheKey: String
    var serverURLString: String
    var sessionID: String
    var title: String?
    var workspace: String?
    var model: String?
    var modelProvider: String?
    var messageCount: Int?
    var createdAt: Double?
    var updatedAt: Double?
    var lastMessageAt: Double?
    var pinned: Bool?
    var archived: Bool?
    var projectId: String?
    var profile: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var estimatedCost: Double?
    var activeStreamId: String?
    var isStreaming: Bool?
    var isCliSession: Bool?
    var userMessageCount: Int?
    var hasPendingUserMessage: Bool?
    var pendingStartedAt: Double?
    var worktreePath: String?
    var sourceTag: String?
    var rawSource: String?
    var sessionSource: String?
    var sourceLabel: String?
    var parentSessionId: String?
    var relationshipType: String?
    var readOnly: Bool?
    var isReadOnly: Bool?
    var defaultHidden: Bool?
    /// nil identifies rows written before this marker existed, which always
    /// contained ordinary session metadata. false is used by the minimal row
    /// created when a restoration window is cached before the session list.
    var hasSessionMetadata: Bool?
    var restorationMessagesData: Data?
    var restorationMessageOffset: Int?
    var restorationAnchorRenderID: String?
    var restorationAnchorMessageID: String?
    var restorationCachedAt: Date?
    var restorationExpiresAt: Date?
    var cachedAt: Date
    var expiresAt: Date

    init(serverURLString: String, session: SessionSummary, cachedAt: Date = Date()) {
        let sessionID = session.sessionId ?? session.id
        self.cacheKey = Self.cacheKey(serverURLString: serverURLString, sessionID: sessionID)
        self.serverURLString = serverURLString
        self.sessionID = sessionID
        self.cachedAt = cachedAt
        self.expiresAt = cachedAt.addingTimeInterval(CachePolicy.ttl)
        self.hasSessionMetadata = true
        apply(session, cachedAt: cachedAt)
    }

    /// Creates only the identity needed to attach an independently-expiring
    /// restoration payload. It must not surface as a cached session-list item.
    init(serverURLString: String, sessionID: String, cachedAt: Date = Date()) {
        self.cacheKey = Self.cacheKey(
            serverURLString: serverURLString,
            sessionID: sessionID
        )
        self.serverURLString = serverURLString
        self.sessionID = sessionID
        self.cachedAt = cachedAt
        self.expiresAt = cachedAt
        self.hasSessionMetadata = false
    }

    static func cacheKey(serverURLString: String, sessionID: String) -> String {
        "\(serverURLString)|session|\(sessionID)"
    }

    func apply(_ session: SessionSummary, cachedAt: Date = Date()) {
        hasSessionMetadata = true
        title = session.title
        workspace = session.workspace
        model = session.model
        modelProvider = session.modelProvider
        messageCount = session.messageCount
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        lastMessageAt = session.lastMessageAt
        pinned = session.pinned
        archived = session.archived
        projectId = session.projectId
        profile = session.profile
        inputTokens = session.inputTokens
        outputTokens = session.outputTokens
        estimatedCost = session.estimatedCost
        activeStreamId = session.activeStreamId
        isStreaming = session.isStreaming
        isCliSession = session.isCliSession
        userMessageCount = session.userMessageCount
        hasPendingUserMessage = session.hasPendingUserMessage
        pendingStartedAt = session.pendingStartedAt
        worktreePath = session.worktreePath
        sourceTag = session.sourceTag
        rawSource = session.rawSource
        sessionSource = session.sessionSource
        sourceLabel = session.sourceLabel
        parentSessionId = session.parentSessionId
        relationshipType = session.relationshipType
        readOnly = session.readOnly
        isReadOnly = session.isReadOnly
        defaultHidden = session.defaultHidden
        self.cachedAt = cachedAt
        expiresAt = cachedAt.addingTimeInterval(CachePolicy.ttl)
    }
}
