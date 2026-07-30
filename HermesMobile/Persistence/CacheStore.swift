import Foundation
import SwiftData

struct CachedMessageWindow: Equatable {
    let messages: [ChatMessage]
    let messageOffset: Int
    let hasPersistedMessageOffset: Bool
    let knownMessageCount: Int?
}

enum CacheStore {
    @MainActor
    static func cachedSessions(
        serverURL: URL,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> [SessionSummary] {
        let serverURLString = serverURL.absoluteString
        let descriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { cachedSession in
                cachedSession.serverURLString == serverURLString
            }
        )

        return try context.fetch(descriptor)
            .filter {
                $0.hasSessionMetadata != false
                    && $0.archived != true
                    && $0.expiresAt > now
            }
            .map(SessionSummary.init(cachedSession:))
    }

    @MainActor
    static func cachedMessages(
        serverURL: URL,
        sessionID: String,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> [ChatMessage] {
        try cachedMessageWindow(
            serverURL: serverURL,
            sessionID: sessionID,
            in: context,
            now: now
        ).messages
    }

    @MainActor
    static func cachedMessageWindow(
        serverURL: URL,
        sessionID: String,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> CachedMessageWindow {
        let serverURLString = serverURL.absoluteString
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { cachedMessage in
                cachedMessage.serverURLString == serverURLString
                    && cachedMessage.sessionID == sessionID
                    && cachedMessage.expiresAt > now
            },
            sortBy: [
                SortDescriptor(\CachedMessage.sortIndex, order: .reverse)
            ]
        )
        descriptor.fetchLimit = CachePolicy.maxMessagesPerSession

        let cachedMessages = try context.fetch(descriptor)
            .sorted { $0.sortIndex < $1.sortIndex }
        guard !cachedMessages.isEmpty else {
            return CachedMessageWindow(
                messages: [],
                messageOffset: 0,
                hasPersistedMessageOffset: false,
                knownMessageCount: nil
            )
        }

        // New cache writes mark the window and persist absolute transcript
        // indexes in `sortIndex`. Older builds wrote every loaded page from zero,
        // so recover unmarked windows from the session's total message count.
        let storedOffset = max(0, cachedMessages.first?.sortIndex ?? 0)
        let sessionCacheKey = CachedSession.cacheKey(
            serverURLString: serverURLString,
            sessionID: sessionID
        )
        let cachedSessionMessageCount = try cachedSession(
            cacheKey: sessionCacheKey,
            in: context
        )?.messageCount
        let inferredLegacyOffset = cachedSessionMessageCount
            .map { max(0, $0 - cachedMessages.count) }
            ?? 0
        let hasPersistedMessageOffset = cachedMessages.first?.messageOffset != nil
        let messageOffset = hasPersistedMessageOffset
            ? storedOffset
            : max(storedOffset, inferredLegacyOffset)

        return CachedMessageWindow(
            messages: cachedMessages.map(ChatMessage.init(cachedMessage:)),
            messageOffset: messageOffset,
            hasPersistedMessageOffset: hasPersistedMessageOffset,
            knownMessageCount: cachedSessionMessageCount
        )
    }

    /// Returns the independently cached historical window only when it belongs
    /// to the exact saved row. A cache entry for a previous reading position
    /// must never be reused for a newer or otherwise ambiguous anchor.
    @MainActor
    static func cachedRestorationMessageWindow(
        serverURL: URL,
        sessionID: String,
        position: ChatTranscriptScrollPosition,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> CachedMessageWindow? {
        let serverURLString = serverURL.absoluteString
        let cacheKey = CachedSession.cacheKey(
            serverURLString: serverURLString,
            sessionID: sessionID
        )
        guard let cachedSession = try cachedSession(
            cacheKey: cacheKey,
            in: context
        ),
        cachedSession.restorationAnchorRenderID == position.renderID,
        cachedSession.restorationAnchorMessageID == position.messageID,
        let expiresAt = cachedSession.restorationExpiresAt,
        expiresAt > now,
        let messageOffset = cachedSession.restorationMessageOffset,
        let data = cachedSession.restorationMessagesData,
        let payloads = try? JSONDecoder().decode(
            [CachedRestorationMessagePayload].self,
            from: data
        ),
        let boundedWindow = boundedRestorationWindow(
            payloads.map(\.message),
            messageOffset: messageOffset,
            containing: position
        ) else {
            return nil
        }

        return CachedMessageWindow(
            messages: boundedWindow.messages,
            messageOffset: boundedWindow.messageOffset,
            hasPersistedMessageOffset: true,
            knownMessageCount: cachedSession.messageCount
        )
    }

    @MainActor
    static func cacheSessions(
        _ sessions: [SessionSummary],
        serverURL: URL,
        in context: ModelContext,
        cachedAt: Date = Date()
    ) throws {
        let serverURLString = serverURL.absoluteString
        let cacheableSessions = sessions.filter { $0.archived != true && $0.sessionId != nil }
        let freshKeys = Set(cacheableSessions.compactMap { session -> String? in
            guard let sessionID = session.sessionId else { return nil }
            return CachedSession.cacheKey(serverURLString: serverURLString, sessionID: sessionID)
        })

        for session in cacheableSessions {
            guard let sessionID = session.sessionId else { continue }
            let cacheKey = CachedSession.cacheKey(serverURLString: serverURLString, sessionID: sessionID)
            if let cachedSession = try cachedSession(cacheKey: cacheKey, in: context) {
                cachedSession.apply(session, cachedAt: cachedAt)
            } else {
                context.insert(CachedSession(serverURLString: serverURLString, session: session, cachedAt: cachedAt))
            }
        }

        let descriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { cachedSession in
                cachedSession.serverURLString == serverURLString
            }
        )
        let staleSessions = try context.fetch(descriptor).filter { !freshKeys.contains($0.cacheKey) }
        for staleSession in staleSessions {
            if let restorationExpiresAt =
                    staleSession.restorationExpiresAt,
               restorationExpiresAt > cachedAt {
                // The visible session list is filtered (for example delegated,
                // hidden-source, or deep-linked sessions). Retire stale list
                // metadata without deleting an independently live reading
                // position cache.
                staleSession.hasSessionMetadata = false
                staleSession.expiresAt = cachedAt
            } else {
                context.delete(staleSession)
            }
        }

        try performMaintenance(in: context, now: cachedAt)
        try context.save()
    }

    @MainActor
    static func cacheSession(
        _ session: SessionSummary,
        serverURL: URL,
        in context: ModelContext,
        cachedAt: Date = Date()
    ) throws {
        guard let sessionID = session.sessionId else { return }

        let serverURLString = serverURL.absoluteString
        let cacheKey = CachedSession.cacheKey(serverURLString: serverURLString, sessionID: sessionID)

        if session.archived == true {
            if let cachedSession = try cachedSession(cacheKey: cacheKey, in: context) {
                context.delete(cachedSession)
            }
        } else if let cachedSession = try cachedSession(cacheKey: cacheKey, in: context) {
            cachedSession.apply(session, cachedAt: cachedAt)
        } else {
            context.insert(CachedSession(serverURLString: serverURLString, session: session, cachedAt: cachedAt))
        }

        try performMaintenance(in: context, now: cachedAt)
        try context.save()
    }

    @MainActor
    static func cacheMessages(
        _ messages: [ChatMessage],
        serverURL: URL,
        sessionID: String,
        messageOffset: Int = 0,
        in context: ModelContext,
        cachedAt: Date = Date()
    ) throws {
        let serverURLString = serverURL.absoluteString
        let droppedMessageCount = max(
            0,
            messages.count - CachePolicy.maxMessagesPerSession
        )
        let cacheableMessages = Array(messages.dropFirst(droppedMessageCount))
        let resolvedMessageOffset = max(0, messageOffset)
            + droppedMessageCount

        let sessionPredicate = #Predicate<CachedMessage> { cachedMessage in
            cachedMessage.serverURLString == serverURLString
                && cachedMessage.sessionID == sessionID
        }
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: sessionPredicate
        )
        let existingMessageCount = try context.fetchCount(descriptor)
        let existingMessages: [CachedMessage]
        if existingMessageCount > CachePolicy.maxMessagesPerSession {
            // Oversized stores were created by the old restoration catch-up
            // loop. Delete that session in one store operation rather than
            // materializing and deleting thousands of models on the main actor.
            try context.delete(
                model: CachedMessage.self,
                where: sessionPredicate
            )
            existingMessages = []
        } else {
            existingMessages = try context.fetch(descriptor)
        }
        var existingMessagesByKey: [String: CachedMessage] = [:]
        existingMessagesByKey.reserveCapacity(existingMessages.count)
        for cachedMessage in existingMessages {
            existingMessagesByKey[cachedMessage.cacheKey] = cachedMessage
        }

        for (offset, message) in cacheableMessages.enumerated() {
            let absoluteSortIndex = resolvedMessageOffset + offset
            let cacheKey = CachedMessage.cacheKey(
                serverURLString: serverURLString,
                sessionID: sessionID,
                message: message,
                sortIndex: absoluteSortIndex
            )
            if let cachedMessage = existingMessagesByKey.removeValue(
                forKey: cacheKey
            ) {
                cachedMessage.apply(
                    message,
                    sortIndex: absoluteSortIndex,
                    messageOffset: resolvedMessageOffset,
                    cachedAt: cachedAt
                )
            } else {
                context.insert(CachedMessage(
                    serverURLString: serverURLString,
                    sessionID: sessionID,
                    message: message,
                    sortIndex: absoluteSortIndex,
                    messageOffset: resolvedMessageOffset,
                    cachedAt: cachedAt
                ))
            }
        }

        for staleMessage in existingMessagesByKey.values {
            context.delete(staleMessage)
        }

        try performMaintenance(in: context, now: cachedAt)
        try context.save()
    }

    /// Persists one small historical window alongside, but never in place of,
    /// the ordinary latest-message rows. The payload is centered around the
    /// requested anchor before encoding so oversized responses remain bounded.
    @MainActor
    static func cacheRestorationMessageWindow(
        _ messages: [ChatMessage],
        serverURL: URL,
        sessionID: String,
        messageOffset: Int,
        position: ChatTranscriptScrollPosition,
        in context: ModelContext,
        cachedAt: Date = Date()
    ) throws {
        guard let boundedWindow = boundedRestorationWindow(
            messages,
            messageOffset: messageOffset,
            containing: position
        ) else {
            return
        }

        let payloads = boundedWindow.messages.map(
            CachedRestorationMessagePayload.init(message:)
        )
        let data = try JSONEncoder().encode(payloads)
        let serverURLString = serverURL.absoluteString
        let cacheKey = CachedSession.cacheKey(
            serverURLString: serverURLString,
            sessionID: sessionID
        )
        let restorationSession: CachedSession
        if let existingSession = try cachedSession(
            cacheKey: cacheKey,
            in: context
        ) {
            restorationSession = existingSession
        } else {
            let newSession = CachedSession(
                serverURLString: serverURLString,
                sessionID: sessionID,
                cachedAt: cachedAt
            )
            context.insert(newSession)
            restorationSession = newSession
        }

        restorationSession.restorationMessagesData = data
        restorationSession.restorationMessageOffset =
            boundedWindow.messageOffset
        restorationSession.restorationAnchorRenderID = position.renderID
        restorationSession.restorationAnchorMessageID = position.messageID
        restorationSession.restorationCachedAt = cachedAt
        restorationSession.restorationExpiresAt = cachedAt.addingTimeInterval(
            CachePolicy.restorationTTL
        )

        // Reading-position commits happen immediately after scrolling settles.
        // Avoid a global cache-maintenance scan on that UI-sensitive path; all
        // reads enforce the restoration TTL, and ordinary cache refreshes still
        // perform physical cleanup.
        try context.save()
    }

    @MainActor
    static func clearAll(in context: ModelContext) throws {
        for cachedSession in try context.fetch(FetchDescriptor<CachedSession>()) {
            context.delete(cachedSession)
        }

        for cachedMessage in try context.fetch(FetchDescriptor<CachedMessage>()) {
            context.delete(cachedMessage)
        }

        try context.save()
    }

    /// Deletes only the cached sessions and messages belonging to `serverURL`,
    /// leaving every other configured server's offline data intact (#18). Backs
    /// the Settings "Clear Offline Cache" action (active server) and the purge
    /// of a server's cache when it is removed, so a removed/reset server never
    /// leaves orphaned rows behind.
    @MainActor
    static func clearCache(for serverURL: URL, in context: ModelContext) throws {
        let serverURLString = serverURL.absoluteString

        let sessionDescriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { cachedSession in
                cachedSession.serverURLString == serverURLString
            }
        )
        for cachedSession in try context.fetch(sessionDescriptor) {
            context.delete(cachedSession)
        }

        let messageDescriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { cachedMessage in
                cachedMessage.serverURLString == serverURLString
            }
        )
        for cachedMessage in try context.fetch(messageDescriptor) {
            context.delete(cachedMessage)
        }

        try context.save()
    }

    @MainActor
    private static func performMaintenance(in context: ModelContext, now: Date) throws {
        try clearExpiredRestorationWindows(in: context, now: now)
        try deleteExpiredSessions(in: context, now: now)
        try deleteExpiredMessages(in: context, now: now)
        try evictOldestMessagesIfNeeded(in: context)
    }

    @MainActor
    private static func clearExpiredRestorationWindows(
        in context: ModelContext,
        now: Date
    ) throws {
        let descriptor = FetchDescriptor<CachedSession>()
        let expiredWindows = try context.fetch(descriptor).filter {
            guard let expiresAt = $0.restorationExpiresAt else {
                return false
            }
            return expiresAt <= now
        }

        for cachedSession in expiredWindows {
            clearRestorationWindow(on: cachedSession)
        }
    }

    @MainActor
    private static func deleteExpiredSessions(in context: ModelContext, now: Date) throws {
        let descriptor = FetchDescriptor<CachedSession>()
        let expiredSessions = try context.fetch(descriptor).filter {
            $0.expiresAt <= now
                && ($0.restorationExpiresAt == nil
                    || $0.restorationExpiresAt! <= now)
        }
        for cachedSession in expiredSessions {
            context.delete(cachedSession)
        }
    }

    @MainActor
    private static func deleteExpiredMessages(in context: ModelContext, now: Date) throws {
        try context.delete(
            model: CachedMessage.self,
            where: #Predicate { cachedMessage in
                cachedMessage.expiresAt <= now
            }
        )
    }

    @MainActor
    private static func evictOldestMessagesIfNeeded(in context: ModelContext) throws {
        let totalCount = try context.fetchCount(
            FetchDescriptor<CachedMessage>()
        )
        let overflowCount = totalCount - CachePolicy.maxMessages
        guard overflowCount > 0 else { return }

        var descriptor = FetchDescriptor<CachedMessage>(
            sortBy: [
                SortDescriptor(\CachedMessage.cachedAt),
                SortDescriptor(\CachedMessage.timestamp),
                SortDescriptor(\CachedMessage.sortIndex),
            ]
        )
        descriptor.fetchLimit = overflowCount
        let messagesToEvict = try context.fetch(descriptor)

        for message in messagesToEvict {
            context.delete(message)
        }
    }

    @MainActor
    private static func cachedSession(cacheKey: String, in context: ModelContext) throws -> CachedSession? {
        var descriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { cachedSession in
                cachedSession.cacheKey == cacheKey
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @MainActor
    private static func cachedMessage(cacheKey: String, in context: ModelContext) throws -> CachedMessage? {
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { cachedMessage in
                cachedMessage.cacheKey == cacheKey
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    nonisolated private static func boundedRestorationWindow(
        _ messages: [ChatMessage],
        messageOffset: Int,
        containing position: ChatTranscriptScrollPosition
    ) -> (messages: [ChatMessage], messageOffset: Int)? {
        guard !messages.isEmpty else { return nil }

        let resolvedOffset = max(0, messageOffset)
        let visibleRows = messages.enumerated().compactMap {
            loadedIndex,
            message -> (loadedIndex: Int, identity: ChatTranscriptRowIdentity)?
            in
            guard message.role != "tool",
                  !TranscriptTurnClassifier.isToolResultOnlyMessage(message)
            else {
                return nil
            }

            return (
                loadedIndex,
                ChatTranscriptRowIdentity(
                    renderID: "transcript:\(resolvedOffset + loadedIndex)",
                    messageID: ChatTranscriptMessageIdentity.resolve(
                        for: message
                    )
                )
            )
        }
        guard let matchingVisibleIndex =
                ChatTranscriptReadingPositionResolver.matchingRowIndex(
                    for: position,
                    identities: visibleRows.map(\.identity)
                )
        else {
            return nil
        }

        let maximumCount =
            CachePolicy.maxRestorationMessagesPerSession
        guard messages.count > maximumCount else {
            return (messages, resolvedOffset)
        }

        let matchingLoadedIndex =
            visibleRows[matchingVisibleIndex].loadedIndex
        let maximumStartIndex = messages.count - maximumCount
        let preferredStartIndex = max(
            0,
            matchingLoadedIndex - (maximumCount / 2)
        )
        let startIndex = min(preferredStartIndex, maximumStartIndex)
        let endIndex = startIndex + maximumCount

        return (
            Array(messages[startIndex..<endIndex]),
            resolvedOffset + startIndex
        )
    }

    private static func clearRestorationWindow(
        on cachedSession: CachedSession
    ) {
        cachedSession.restorationMessagesData = nil
        cachedSession.restorationMessageOffset = nil
        cachedSession.restorationAnchorRenderID = nil
        cachedSession.restorationAnchorMessageID = nil
        cachedSession.restorationCachedAt = nil
        cachedSession.restorationExpiresAt = nil
    }
}

/// A stable Codable representation used only inside CachedSession's restoration
/// Data blob. ChatMessage intentionally remains decode-only at the API boundary.
private struct CachedRestorationMessagePayload: Codable {
    let role: String?
    let content: String?
    let timestamp: Double?
    let messageID: String?
    let name: String?
    let toolCallID: String?
    let toolUseID: String?
    let toolCalls: [JSONValue]?
    let contentParts: [JSONValue]?
    let reasoning: String?
    let attachments: [MessageAttachment]?
    /// Server control markers. Optional and decoded leniently, so blobs written
    /// before these existed still restore — they simply carry no marker.
    let source: String?
    let isRecoveryControl: Bool?

    init(message: ChatMessage) {
        role = message.role
        content = message.content
        timestamp = message.timestamp
        messageID = message.messageId
        name = message.name
        toolCallID = message.toolCallId
        toolUseID = message.toolUseId
        toolCalls = message.toolCalls
        contentParts = message.contentParts
        reasoning = message.reasoning
        attachments = message.attachments
        source = message.source
        isRecoveryControl = message.isRecoveryControl
    }

    var message: ChatMessage {
        ChatMessage(
            role: role,
            content: content,
            timestamp: timestamp,
            messageId: messageID,
            name: name,
            toolCallId: toolCallID,
            toolUseId: toolUseID,
            toolCalls: toolCalls,
            contentParts: contentParts,
            reasoning: reasoning,
            attachments: attachments,
            source: source,
            isRecoveryControl: isRecoveryControl
        )
    }
}

private extension SessionSummary {
    init(cachedSession: CachedSession) {
        sessionId = cachedSession.sessionID
        title = cachedSession.title
        workspace = cachedSession.workspace
        model = cachedSession.model
        modelProvider = cachedSession.modelProvider
        messageCount = cachedSession.messageCount
        createdAt = cachedSession.createdAt
        updatedAt = cachedSession.updatedAt
        lastMessageAt = cachedSession.lastMessageAt
        pinned = cachedSession.pinned
        archived = cachedSession.archived
        projectId = cachedSession.projectId
        profile = cachedSession.profile
        inputTokens = cachedSession.inputTokens
        outputTokens = cachedSession.outputTokens
        estimatedCost = cachedSession.estimatedCost
        activeStreamId = cachedSession.activeStreamId
        isStreaming = cachedSession.isStreaming
        isCliSession = cachedSession.isCliSession
        userMessageCount = cachedSession.userMessageCount
        hasPendingUserMessage = cachedSession.hasPendingUserMessage
        pendingStartedAt = cachedSession.pendingStartedAt
        worktreePath = cachedSession.worktreePath
        sourceTag = cachedSession.sourceTag
        rawSource = cachedSession.rawSource
        sessionSource = cachedSession.sessionSource
        sourceLabel = cachedSession.sourceLabel
        parentSessionId = cachedSession.parentSessionId
        relationshipType = cachedSession.relationshipType
        readOnly = cachedSession.readOnly
        isReadOnly = cachedSession.isReadOnly
        matchType = nil
    }
}

private extension ChatMessage {
    init(cachedMessage: CachedMessage) {
        let attachments: [MessageAttachment]?
        if let data = cachedMessage.attachmentsData {
            attachments = try? JSONDecoder().decode([MessageAttachment].self, from: data)
        } else {
            attachments = nil
        }
        let toolCalls: [JSONValue]?
        if let data = cachedMessage.toolCallsData {
            toolCalls = try? JSONDecoder().decode([JSONValue].self, from: data)
        } else {
            toolCalls = nil
        }
        let contentParts: [JSONValue]?
        if let data = cachedMessage.contentPartsData {
            contentParts = try? JSONDecoder().decode([JSONValue].self, from: data)
        } else {
            contentParts = nil
        }
        self.init(
            role: cachedMessage.role,
            content: cachedMessage.content,
            timestamp: cachedMessage.timestamp,
            messageId: cachedMessage.messageId,
            name: cachedMessage.name,
            toolCallId: cachedMessage.toolCallId,
            toolUseId: cachedMessage.toolUseId,
            toolCalls: toolCalls,
            contentParts: contentParts,
            reasoning: cachedMessage.reasoning,
            attachments: attachments,
            source: cachedMessage.source,
            isRecoveryControl: cachedMessage.isRecoveryControl
        )
    }
}
