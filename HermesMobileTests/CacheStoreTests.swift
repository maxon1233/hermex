import SwiftData
import XCTest
@testable import HermesMobile

@MainActor
final class CacheStoreTests: XCTestCase {
    func testCacheSessionsWritesVisibleSessionsAndRemovesStaleEntries() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let secondCachedAt = Date(timeIntervalSince1970: 1_770_000_100)

        let firstResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "keep", "title": "Planning", "last_message_at": 1770000000, "archived": false},
            {"session_id": "stale", "title": "Old thread", "last_message_at": 1760000000, "archived": false},
            {"session_id": "archived", "title": "Archived thread", "archived": true},
            {"title": "Missing ID", "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(firstResponse.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: firstCachedAt
        )

        var cachedSessions = try fetchCachedSessions(in: context)
        XCTAssertEqual(cachedSessions.map(\.sessionID).sorted(), ["keep", "stale"])
        XCTAssertEqual(cachedSessions.first(where: { $0.sessionID == "keep" })?.expiresAt, firstCachedAt.addingTimeInterval(CachePolicy.ttl))

        let secondResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "keep", "title": "Updated planning", "last_message_at": 1770000100, "archived": false},
            {"session_id": "new", "title": "New thread", "last_message_at": 1770000200, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(secondResponse.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: secondCachedAt
        )

        cachedSessions = try fetchCachedSessions(in: context)
        XCTAssertEqual(cachedSessions.map(\.sessionID).sorted(), ["keep", "new"])

        let updatedSession = try XCTUnwrap(cachedSessions.first { $0.sessionID == "keep" })
        XCTAssertEqual(updatedSession.title, "Updated planning")
        XCTAssertEqual(updatedSession.lastMessageAt, 1_770_000_100)
        XCTAssertEqual(updatedSession.cachedAt, secondCachedAt)
        XCTAssertEqual(updatedSession.expiresAt, secondCachedAt.addingTimeInterval(CachePolicy.ttl))
    }

    func testCachedSessionsPreserveSubagentClassificationAndReadOnlySafety() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)
        let response = try decodeSessions("""
        {
          "sessions": [
            {
              "session_id": "subagent-child",
              "title": "Delegated research",
              "source_tag": "subagent",
              "raw_source": "subagent",
              "session_source": "other",
              "source_label": "Subagent",
              "parent_session_id": "parent-1",
              "relationship_type": "child_session",
              "read_only": true,
              "archived": false
            }
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(response.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let cached = try XCTUnwrap(
            CacheStore.cachedSessions(serverURL: serverURL, in: context, now: now).first
        )
        XCTAssertEqual(cached.rawSource, "subagent")
        XCTAssertEqual(cached.parentSessionId, "parent-1")
        XCTAssertEqual(cached.relationshipType, "child_session")
        XCTAssertTrue(cached.isDelegatedSubagentSession)
        XCTAssertTrue(cached.isSessionReadOnly)
        XCTAssertFalse(AutomatedSessionVisibility(showsCron: true, showsCli: true).shows(cached))
        XCTAssertTrue(AutomatedSessionVisibility.showAll.shows(cached))
    }

    func testCachedSessionsPreserveClaudeCodeClassificationAndVisibility() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let response = try decodeSessions("""
        {
          "sessions": [
            {
              "session_id": "claude-code",
              "title": "Imported transcript",
              "source_tag": "claude_code",
              "raw_source": "claude_code",
              "is_cli_session": true,
              "read_only": true,
              "archived": false
            },
            {
              "session_id": "ordinary-cli",
              "title": "Terminal chat",
              "source_tag": "cli",
              "is_cli_session": true,
              "archived": false
            }
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(response.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let cached = try CacheStore.cachedSessions(
            serverURL: serverURL,
            in: context,
            now: cachedAt.addingTimeInterval(60)
        )
        let hidden = AutomatedSessionVisibility(
            showsCron: true,
            showsCli: true,
            showsClaudeCode: false
        )

        XCTAssertTrue(try XCTUnwrap(cached.first { $0.sessionId == "claude-code" }).isClaudeCodeSession)
        XCTAssertEqual(cached.filter(hidden.shows).compactMap(\.sessionId), ["ordinary-cli"])
    }

    func testCacheMessagesWritesLoadedWindowAndRemovesStaleMessages() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let secondCachedAt = Date(timeIntervalSince1970: 1_770_000_100)
        let firstMessages = [
            ChatMessage(
                role: "user",
                content: "Hello",
                timestamp: 1_770_000_000,
                messageId: "m1"
            ),
            ChatMessage(
                role: "assistant",
                content: "Hi",
                timestamp: 1_770_000_001,
                messageId: "m2",
                reasoning: "Greet the user."
            )
        ]

        try CacheStore.cacheMessages(
            firstMessages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: firstCachedAt
        )

        var cachedMessages = try fetchCachedMessages(in: context)
        XCTAssertEqual(cachedMessages.compactMap(\.messageId).sorted(), ["m1", "m2"])
        XCTAssertEqual(cachedMessages.first(where: { $0.messageId == "m2" })?.reasoning, "Greet the user.")
        XCTAssertEqual(cachedMessages.first(where: { $0.messageId == "m1" })?.expiresAt, firstCachedAt.addingTimeInterval(CachePolicy.ttl))

        let secondMessages = [
            ChatMessage(
                role: "assistant",
                content: "Updated hi",
                timestamp: 1_770_000_002,
                messageId: "m2",
                reasoning: "Updated reasoning."
            ),
            ChatMessage(
                role: "user",
                content: "Next",
                timestamp: 1_770_000_003,
                messageId: "m3"
            )
        ]

        try CacheStore.cacheMessages(
            secondMessages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: secondCachedAt
        )

        cachedMessages = try fetchCachedMessages(in: context)
        XCTAssertEqual(cachedMessages.compactMap(\.messageId).sorted(), ["m2", "m3"])

        let updatedMessage = try XCTUnwrap(cachedMessages.first { $0.messageId == "m2" })
        XCTAssertEqual(updatedMessage.content, "Updated hi")
        XCTAssertEqual(updatedMessage.sortIndex, 0)
        XCTAssertEqual(updatedMessage.cachedAt, secondCachedAt)
        XCTAssertEqual(updatedMessage.expiresAt, secondCachedAt.addingTimeInterval(CachePolicy.ttl))
    }

    /// Without persisting the markers, a cache-first render brings the hidden
    /// wakeup and recovery-control turns back as ordinary bubbles.
    func testCachedMessageWindowPreservesServerControlMarkers() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let messages = [
            ChatMessage(role: "user", content: "Kick off the build", timestamp: 1_770_000_000, messageId: "m1"),
            ChatMessage(
                role: "user",
                content: "[IMPORTANT: Background process 4f2 completed]",
                timestamp: 1_770_000_001,
                messageId: "m2",
                source: "process_wakeup"
            ),
            ChatMessage(
                role: "user",
                content: "[System: Continue exactly where you left off.]",
                timestamp: 1_770_000_002,
                messageId: "m3",
                isRecoveryControl: true
            )
        ]

        try CacheStore.cacheMessages(
            messages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        let window = try CacheStore.cachedMessageWindow(
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            now: cachedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(window.messages, messages)
        XCTAssertEqual(
            ChatViewModel.transcriptMessages(from: window.messages).map(\.message.messageId),
            ["m1"]
        )
    }

    func testCachedMessageWindowPreservesAbsoluteMessageOffset() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let messages = [
            ChatMessage(
                role: "user",
                content: "Recent question",
                timestamp: 1_770_000_000,
                messageId: nil
            ),
            ChatMessage(
                role: "assistant",
                content: "Recent answer",
                timestamp: 1_770_000_001,
                messageId: nil
            ),
        ]

        try CacheStore.cacheMessages(
            messages,
            serverURL: serverURL,
            sessionID: "large-session",
            messageOffset: 269,
            in: context,
            cachedAt: cachedAt
        )

        let window = try CacheStore.cachedMessageWindow(
            serverURL: serverURL,
            sessionID: "large-session",
            in: context,
            now: cachedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(window.messages, messages)
        XCTAssertEqual(window.messageOffset, 269)
        XCTAssertEqual(
            try fetchCachedMessages(in: context).map(\.sortIndex).sorted(),
            [269, 270]
        )
        XCTAssertEqual(
            Set(try fetchCachedMessages(in: context).compactMap(\.messageOffset)),
            [269]
        )
    }

    func testCachedMessageWindowInfersOffsetForLegacyZeroBasedCache() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let session = SessionSummary(
            sessionId: "legacy-large-session",
            title: "Legacy large session",
            messageCount: 271
        )
        let messages = [
            ChatMessage(
                role: "user",
                content: "Recent question",
                timestamp: 1_770_000_000,
                messageId: nil
            ),
            ChatMessage(
                role: "assistant",
                content: "Recent answer",
                timestamp: 1_770_000_001,
                messageId: nil
            ),
        ]

        try CacheStore.cacheSession(
            session,
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )
        try CacheStore.cacheMessages(
            messages,
            serverURL: serverURL,
            sessionID: "legacy-large-session",
            in: context,
            cachedAt: cachedAt
        )
        for cachedMessage in try fetchCachedMessages(in: context) {
            cachedMessage.messageOffset = nil
        }
        try context.save()

        let window = try CacheStore.cachedMessageWindow(
            serverURL: serverURL,
            sessionID: "legacy-large-session",
            in: context,
            now: cachedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(window.messages, messages)
        XCTAssertEqual(window.messageOffset, 269)
    }

    func testRestorationCacheKeepsLatestWindowSeparateAndSurvivesMetadataApply() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let sessionID = "restoration-before-metadata"
        let latestMessages = [
            ChatMessage(
                role: "user",
                content: "Latest question",
                timestamp: 2_000,
                messageId: "latest-user"
            ),
            ChatMessage(
                role: "assistant",
                content: "Latest answer",
                timestamp: 2_001,
                messageId: "latest-assistant"
            ),
        ]
        let historicalMessages = (0..<80).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Historical message \(index)",
                timestamp: Double(1_000 + index),
                messageId: "historical-\(index)",
                reasoning: index == 11 ? "Saved reasoning" : nil
            )
        }
        let position = ChatTranscriptScrollPosition(
            renderID: "transcript:1011",
            messageID: "historical-11",
            offsetFromRowTop: 120
        )

        try CacheStore.cacheMessages(
            latestMessages,
            serverURL: serverURL,
            sessionID: sessionID,
            messageOffset: 1_980,
            in: context,
            cachedAt: cachedAt
        )
        try CacheStore.cacheRestorationMessageWindow(
            historicalMessages,
            serverURL: serverURL,
            sessionID: sessionID,
            messageOffset: 1_000,
            position: position,
            in: context,
            cachedAt: cachedAt
        )

        let latestWindow = try CacheStore.cachedMessageWindow(
            serverURL: serverURL,
            sessionID: sessionID,
            in: context,
            now: cachedAt.addingTimeInterval(1)
        )
        let restorationWindow = try XCTUnwrap(
            CacheStore.cachedRestorationMessageWindow(
                serverURL: serverURL,
                sessionID: sessionID,
                position: position,
                in: context,
                now: cachedAt.addingTimeInterval(1)
            )
        )

        XCTAssertEqual(latestWindow.messages, latestMessages)
        XCTAssertEqual(latestWindow.messageOffset, 1_980)
        XCTAssertEqual(try fetchCachedMessages(in: context).count, 2)
        XCTAssertEqual(
            restorationWindow.messages.count,
            CachePolicy.maxRestorationMessagesPerSession
        )
        XCTAssertEqual(restorationWindow.messageOffset, 1_000)
        XCTAssertEqual(
            restorationWindow.messages.first?.messageId,
            "historical-0"
        )
        XCTAssertEqual(
            restorationWindow.messages.last?.messageId,
            "historical-49"
        )
        XCTAssertEqual(
            restorationWindow.messages.first {
                $0.messageId == "historical-11"
            }?.reasoning,
            "Saved reasoning"
        )
        XCTAssertTrue(
            try CacheStore.cachedSessions(
                serverURL: serverURL,
                in: context,
                now: cachedAt.addingTimeInterval(1)
            ).isEmpty
        )

        try CacheStore.cacheSession(
            SessionSummary(
                sessionId: sessionID,
                title: "Metadata arrived later",
                messageCount: 2_002
            ),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt.addingTimeInterval(10)
        )

        let restoredAfterApply = try XCTUnwrap(
            CacheStore.cachedRestorationMessageWindow(
                serverURL: serverURL,
                sessionID: sessionID,
                position: position,
                in: context,
                now: cachedAt.addingTimeInterval(20)
            )
        )
        XCTAssertEqual(restoredAfterApply.messages, restorationWindow.messages)
        XCTAssertEqual(restoredAfterApply.knownMessageCount, 2_002)
        XCTAssertEqual(
            try CacheStore.cachedSessions(
                serverURL: serverURL,
                in: context,
                now: cachedAt.addingTimeInterval(20)
            ).map(\.title),
            ["Metadata arrived later"]
        )
    }

    func testRestorationCacheRequiresExactSavedAnchorIdentity() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let sessionID = "exact-restoration-anchor"
        let messages = [
            ChatMessage(
                role: "assistant",
                content: "Saved row",
                timestamp: 1_000,
                messageId: "saved-message"
            ),
        ]
        let savedPosition = ChatTranscriptScrollPosition(
            renderID: "transcript:42",
            messageID: "saved-message",
            offsetFromRowTop: 80
        )

        try CacheStore.cacheRestorationMessageWindow(
            messages,
            serverURL: serverURL,
            sessionID: sessionID,
            messageOffset: 42,
            position: savedPosition,
            in: context,
            cachedAt: cachedAt
        )

        XCTAssertNotNil(
            try CacheStore.cachedRestorationMessageWindow(
                serverURL: serverURL,
                sessionID: sessionID,
                position: savedPosition,
                in: context,
                now: cachedAt.addingTimeInterval(1)
            )
        )
        XCTAssertNil(
            try CacheStore.cachedRestorationMessageWindow(
                serverURL: serverURL,
                sessionID: sessionID,
                position: ChatTranscriptScrollPosition(
                    renderID: "transcript:43",
                    messageID: "saved-message",
                    offsetFromRowTop: 80
                ),
                in: context,
                now: cachedAt.addingTimeInterval(1)
            )
        )
        XCTAssertNil(
            try CacheStore.cachedRestorationMessageWindow(
                serverURL: serverURL,
                sessionID: sessionID,
                position: ChatTranscriptScrollPosition(
                    renderID: "transcript:42",
                    messageID: "other-message",
                    offsetFromRowTop: 80
                ),
                in: context,
                now: cachedAt.addingTimeInterval(1)
            )
        )
    }

    func testFilteredSessionListRefreshPreservesLiveRestorationWindow()
        throws
    {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let sessionID = "deep-linked-session"
        let position = ChatTranscriptScrollPosition(
            renderID: "transcript:42",
            messageID: "saved-message",
            offsetFromRowTop: 80
        )
        try CacheStore.cacheSession(
            SessionSummary(
                sessionId: sessionID,
                title: "Filtered metadata"
            ),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )
        try CacheStore.cacheRestorationMessageWindow(
            [
                ChatMessage(
                    role: "assistant",
                    content: "Saved row",
                    timestamp: 42,
                    messageId: "saved-message"
                ),
            ],
            serverURL: serverURL,
            sessionID: sessionID,
            messageOffset: 42,
            position: position,
            in: context,
            cachedAt: cachedAt
        )

        try CacheStore.cacheSessions(
            [],
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt.addingTimeInterval(60)
        )

        XCTAssertTrue(
            try CacheStore.cachedSessions(
                serverURL: serverURL,
                in: context,
                now: cachedAt.addingTimeInterval(61)
            ).isEmpty
        )
        XCTAssertNotNil(
            try CacheStore.cachedRestorationMessageWindow(
                serverURL: serverURL,
                sessionID: sessionID,
                position: position,
                in: context,
                now: cachedAt.addingTimeInterval(61)
            )
        )
    }

    func testRestorationCacheExpiresIndependentlyFromRefreshedSessionMetadata() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let sessionID = "expired-restoration-window"
        let position = ChatTranscriptScrollPosition(
            renderID: "transcript:10",
            messageID: "historical-10",
            offsetFromRowTop: 20
        )

        try CacheStore.cacheRestorationMessageWindow(
            [
                ChatMessage(
                    role: "assistant",
                    content: "Historical answer",
                    timestamp: 10,
                    messageId: "historical-10"
                ),
            ],
            serverURL: serverURL,
            sessionID: sessionID,
            messageOffset: 10,
            position: position,
            in: context,
            cachedAt: cachedAt
        )
        try CacheStore.cacheSession(
            SessionSummary(
                sessionId: sessionID,
                title: "Still-current metadata"
            ),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt.addingTimeInterval(
                CachePolicy.restorationTTL - 60
            )
        )

        let afterRestorationExpiry = cachedAt.addingTimeInterval(
            CachePolicy.restorationTTL + 1
        )
        XCTAssertNil(
            try CacheStore.cachedRestorationMessageWindow(
                serverURL: serverURL,
                sessionID: sessionID,
                position: position,
                in: context,
                now: afterRestorationExpiry
            )
        )
        XCTAssertEqual(
            try CacheStore.cachedSessions(
                serverURL: serverURL,
                in: context,
                now: afterRestorationExpiry
            ).map(\.title),
            ["Still-current metadata"]
        )

        try CacheStore.cacheMessages(
            [],
            serverURL: serverURL,
            sessionID: sessionID,
            in: context,
            cachedAt: afterRestorationExpiry
        )
        let cachedSession = try XCTUnwrap(
            fetchCachedSessions(in: context).first {
                $0.sessionID == sessionID
            }
        )
        XCTAssertNil(cachedSession.restorationMessagesData)
        XCTAssertNil(cachedSession.restorationMessageOffset)
        XCTAssertNil(cachedSession.restorationAnchorRenderID)
        XCTAssertNil(cachedSession.restorationAnchorMessageID)
        XCTAssertNil(cachedSession.restorationCachedAt)
        XCTAssertNil(cachedSession.restorationExpiresAt)
    }

    func testCacheMessagesBoundsProductionScaleSessionToRecentWindow() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let messages = (0..<2_091).map { index in
            ChatMessage(
                role: index.isMultiple(of: 4) ? "user" : "assistant",
                content: "Synthetic large-session message \(index)",
                timestamp: Double(index),
                messageId: "message-\(index)"
            )
        }

        try CacheStore.cacheMessages(
            messages,
            serverURL: serverURL,
            sessionID: "production-scale",
            in: context,
            cachedAt: cachedAt
        )

        let persistedMessages = try fetchCachedMessages(in: context)
            .filter { $0.sessionID == "production-scale" }
        let window = try CacheStore.cachedMessageWindow(
            serverURL: serverURL,
            sessionID: "production-scale",
            in: context,
            now: cachedAt.addingTimeInterval(60)
        )
        let expectedFirstIndex =
            messages.count - CachePolicy.maxMessagesPerSession

        XCTAssertEqual(
            persistedMessages.count,
            CachePolicy.maxMessagesPerSession
        )
        XCTAssertEqual(
            window.messages.count,
            CachePolicy.maxMessagesPerSession
        )
        XCTAssertEqual(
            window.messages.first?.messageId,
            "message-\(expectedFirstIndex)"
        )
        XCTAssertEqual(window.messages.last?.messageId, "message-2090")
        XCTAssertEqual(window.messageOffset, expectedFirstIndex)
        XCTAssertEqual(
            Set(persistedMessages.compactMap(\.messageOffset)),
            [expectedFirstIndex]
        )
    }

    func testCachedMessageWindowBoundsOversizedLegacyStoreBeforeRendering() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)

        for index in 0..<2_091 {
            context.insert(
                CachedMessage(
                    serverURLString: serverURL.absoluteString,
                    sessionID: "legacy-production-scale",
                    message: ChatMessage(
                        role: "assistant",
                        content: "Legacy cached message \(index)",
                        timestamp: Double(index),
                        messageId: "legacy-\(index)"
                    ),
                    sortIndex: index,
                    messageOffset: 0,
                    cachedAt: cachedAt
                )
            )
        }
        try context.save()

        let window = try CacheStore.cachedMessageWindow(
            serverURL: serverURL,
            sessionID: "legacy-production-scale",
            in: context,
            now: cachedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(
            window.messages.count,
            CachePolicy.maxMessagesPerSession
        )
        XCTAssertEqual(window.messages.first?.messageId, "legacy-1891")
        XCTAssertEqual(window.messages.last?.messageId, "legacy-2090")
        XCTAssertEqual(window.messageOffset, 1_891)
    }

    func testCacheMessagesBulkReplacesOversizedLegacySession() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let legacyCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let replacementCachedAt = legacyCachedAt.addingTimeInterval(60)
        let sessionID = "legacy-bulk-replacement"

        for index in 0..<2_091 {
            context.insert(
                CachedMessage(
                    serverURLString: serverURL.absoluteString,
                    sessionID: sessionID,
                    message: ChatMessage(
                        role: "assistant",
                        content: "Legacy \(index)",
                        timestamp: Double(index),
                        messageId: "legacy-\(index)"
                    ),
                    sortIndex: index,
                    messageOffset: 0,
                    cachedAt: legacyCachedAt
                )
            )
        }
        try context.save()

        let replacementMessages = [
            ChatMessage(
                role: "user",
                content: "Current question",
                timestamp: 2_091,
                messageId: "current-user"
            ),
            ChatMessage(
                role: "assistant",
                content: "Current answer",
                timestamp: 2_092,
                messageId: "current-assistant"
            ),
        ]
        try CacheStore.cacheMessages(
            replacementMessages,
            serverURL: serverURL,
            sessionID: sessionID,
            messageOffset: 2_091,
            in: context,
            cachedAt: replacementCachedAt
        )

        let persistedMessages = try fetchCachedMessages(in: context)
            .filter { $0.sessionID == sessionID }
        let window = try CacheStore.cachedMessageWindow(
            serverURL: serverURL,
            sessionID: sessionID,
            in: context,
            now: replacementCachedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(
            persistedMessages.compactMap(\.messageId).sorted(),
            ["current-assistant", "current-user"]
        )
        XCTAssertEqual(window.messages, replacementMessages)
        XCTAssertEqual(window.messageOffset, 2_091)
    }

    func testCacheWriteDeletesProductionScaleExpiredRowsDuringMaintenance() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let expiredCachedAt = now
            .addingTimeInterval(-CachePolicy.ttl - 60)

        for index in 0..<2_091 {
            context.insert(
                CachedMessage(
                    serverURLString: serverURL.absoluteString,
                    sessionID: "expired-production-scale",
                    message: ChatMessage(
                        role: "assistant",
                        content: "Expired cached message \(index)",
                        timestamp: Double(index),
                        messageId: "expired-\(index)"
                    ),
                    sortIndex: index,
                    messageOffset: 0,
                    cachedAt: expiredCachedAt
                )
            )
        }
        try context.save()

        XCTAssertEqual(try fetchCachedMessages(in: context).count, 2_091)

        try CacheStore.cacheMessages(
            [
                ChatMessage(
                    role: "user",
                    content: "Fresh cached message",
                    timestamp: now.timeIntervalSince1970,
                    messageId: "fresh"
                ),
            ],
            serverURL: serverURL,
            sessionID: "fresh-session",
            in: context,
            cachedAt: now
        )

        let persistedMessages = try fetchCachedMessages(in: context)
        XCTAssertEqual(
            persistedMessages.compactMap(\.messageId),
            ["fresh"]
        )
        XCTAssertFalse(
            persistedMessages.contains {
                $0.sessionID == "expired-production-scale"
            }
        )
    }

    func testCachedMessageWindowFiltersExpiredRowsBeforeApplyingFetchLimit() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let sessionID = "mixed-expiry"
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let validCachedAt = now
            .addingTimeInterval(-CachePolicy.ttl + 60)
        let expiredCachedAt = now
            .addingTimeInterval(-CachePolicy.ttl - 60)

        for index in 0..<3 {
            context.insert(
                CachedMessage(
                    serverURLString: serverURL.absoluteString,
                    sessionID: sessionID,
                    message: ChatMessage(
                        role: "assistant",
                        content: "Valid cached message \(index)",
                        timestamp: Double(index),
                        messageId: "valid-\(index)"
                    ),
                    sortIndex: index,
                    messageOffset: 0,
                    cachedAt: validCachedAt
                )
            )
        }

        for index in 0..<CachePolicy.maxMessagesPerSession {
            let sortIndex = 1_000 + index
            context.insert(
                CachedMessage(
                    serverURLString: serverURL.absoluteString,
                    sessionID: sessionID,
                    message: ChatMessage(
                        role: "assistant",
                        content: "Expired cached message \(index)",
                        timestamp: Double(sortIndex),
                        messageId: "expired-\(index)"
                    ),
                    sortIndex: sortIndex,
                    messageOffset: 1_000,
                    cachedAt: expiredCachedAt
                )
            )
        }
        try context.save()

        let window = try CacheStore.cachedMessageWindow(
            serverURL: serverURL,
            sessionID: sessionID,
            in: context,
            now: now
        )

        XCTAssertEqual(
            window.messages.compactMap(\.messageId),
            ["valid-0", "valid-1", "valid-2"]
        )
        XCTAssertEqual(window.messageOffset, 0)
    }

    func testCacheSessionUpsertsOneSessionWithoutRemovingExistingSessions() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let secondCachedAt = Date(timeIntervalSince1970: 1_770_000_100)

        let existingResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "existing", "title": "Existing", "last_message_at": 1770000000, "archived": false}
          ]
        }
        """)
        try CacheStore.cacheSessions(
            try XCTUnwrap(existingResponse.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: firstCachedAt
        )

        let forkResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "fork", "title": "Existing (fork)", "last_message_at": 1770000100, "archived": false}
          ]
        }
        """)
        let fork = try XCTUnwrap(forkResponse.sessions?.first)

        try CacheStore.cacheSession(
            fork,
            serverURL: serverURL,
            in: context,
            cachedAt: secondCachedAt
        )

        let cachedSessions = try fetchCachedSessions(in: context)
        XCTAssertEqual(cachedSessions.map(\.sessionID).sorted(), ["existing", "fork"])

        let forkedSession = try XCTUnwrap(cachedSessions.first { $0.sessionID == "fork" })
        XCTAssertEqual(forkedSession.title, "Existing (fork)")
        XCTAssertEqual(forkedSession.cachedAt, secondCachedAt)
    }

    func testCachedSessionsReturnsOnlyUnexpiredVisibleSessionsForServer() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let otherServerURL = URL(string: "https://other.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        let response = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "fresh", "title": "Fresh thread", "last_message_at": 1770000000, "archived": false},
            {"session_id": "archived", "title": "Archived thread", "archived": true}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(response.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let otherResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "other", "title": "Other server", "last_message_at": 1770000100, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(otherResponse.sessions),
            serverURL: otherServerURL,
            in: context,
            cachedAt: cachedAt
        )

        let cachedSessions = try CacheStore.cachedSessions(serverURL: serverURL, in: context, now: now)

        XCTAssertEqual(cachedSessions.map(\.sessionId), ["fresh"])
        XCTAssertEqual(cachedSessions.first?.title, "Fresh thread")
    }

    func testCachedSessionsIgnoresExpiredSessions() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let expiredNow = cachedAt.addingTimeInterval(CachePolicy.ttl + 1)
        let response = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "expired", "title": "Expired thread", "last_message_at": 1770000000, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(response.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let cachedSessions = try CacheStore.cachedSessions(serverURL: serverURL, in: context, now: expiredNow)

        XCTAssertTrue(cachedSessions.isEmpty)
    }

    func testCachedMessagesReturnsUnexpiredMessagesInStoredOrderForSession() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)
        let messages = [
            ChatMessage(
                role: "assistant",
                content: "Second",
                timestamp: 1_770_000_002,
                messageId: "m2",
                reasoning: "Cached reasoning."
            ),
            ChatMessage(
                role: "user",
                content: "First",
                timestamp: 1_770_000_001,
                messageId: "m1"
            )
        ]

        try CacheStore.cacheMessages(
            messages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        try CacheStore.cacheMessages(
            [
                ChatMessage(
                    role: "user",
                    content: "Other session",
                    timestamp: 1_770_000_003,
                    messageId: "other"
                )
            ],
            serverURL: serverURL,
            sessionID: "other-session",
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try CacheStore.cachedMessages(
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            now: now
        )

        XCTAssertEqual(cachedMessages.map(\.messageId), ["m2", "m1"])
        XCTAssertEqual(cachedMessages.first?.reasoning, "Cached reasoning.")
    }

    func testCachedMessagesIgnoresExpiredMessages() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let expiredNow = cachedAt.addingTimeInterval(CachePolicy.ttl + 1)

        try CacheStore.cacheMessages(
            [
                ChatMessage(
                    role: "user",
                    content: "Expired",
                    timestamp: 1_770_000_001,
                    messageId: "expired"
                )
            ],
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try CacheStore.cachedMessages(
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            now: expiredNow
        )

        XCTAssertTrue(cachedMessages.isEmpty)
    }

    func testCacheMaintenanceDeletesExpiredSessionsAndMessagesOnWrite() throws {
        let context = try makeContext()
        let oldServerURL = URL(string: "https://old.example.test")!
        let triggerServerURL = URL(string: "https://trigger.example.test")!
        let oldCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let currentCachedAt = oldCachedAt.addingTimeInterval(CachePolicy.ttl + 1)

        let oldSessions = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "expired-session", "title": "Expired", "last_message_at": 1770000000, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(oldSessions.sessions),
            serverURL: oldServerURL,
            in: context,
            cachedAt: oldCachedAt
        )

        try CacheStore.cacheMessages(
            [
                ChatMessage(
                    role: "user",
                    content: "Expired message",
                    timestamp: 1_770_000_000,
                    messageId: "expired-message"
                )
            ],
            serverURL: oldServerURL,
            sessionID: "expired-session",
            in: context,
            cachedAt: oldCachedAt
        )

        let triggerSessions = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "fresh-session", "title": "Fresh", "last_message_at": 1770604801, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(triggerSessions.sessions),
            serverURL: triggerServerURL,
            in: context,
            cachedAt: currentCachedAt
        )

        XCTAssertEqual(try fetchCachedSessions(in: context).map(\.sessionID), ["fresh-session"])
        XCTAssertTrue(try fetchCachedMessages(in: context).isEmpty)
    }

    func testCacheMaintenanceEvictsOldestMessagesAboveLimit() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)

        for index in 0...CachePolicy.maxMessages {
            context.insert(
                CachedMessage(
                    serverURLString: serverURL.absoluteString,
                    sessionID: "abc123",
                    message: ChatMessage(
                        role: "user",
                        content: "Message \(index)",
                        timestamp: Double(index),
                        messageId: "message-\(index)"
                    ),
                    sortIndex: index,
                    cachedAt: cachedAt
                )
            )
        }

        let triggerSessions = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "abc123", "title": "Trigger", "last_message_at": 1770000000, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(triggerSessions.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try fetchCachedMessages(in: context)

        XCTAssertEqual(cachedMessages.count, CachePolicy.maxMessages)
        XCTAssertNil(cachedMessages.first { $0.messageId == "message-0" })
        XCTAssertNotNil(cachedMessages.first { $0.messageId == "message-1" })
        XCTAssertNotNil(cachedMessages.first { $0.messageId == "message-\(CachePolicy.maxMessages)" })
    }

    func testClearAllDeletesCachedSessionsAndMessages() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let response = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "abc123", "title": "Cached", "last_message_at": 1770000000, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(response.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        try CacheStore.cacheMessages(
            [
                ChatMessage(
                    role: "user",
                    content: "Cached message",
                    timestamp: 1_770_000_000,
                    messageId: "m1"
                )
            ],
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        try CacheStore.clearAll(in: context)

        XCTAssertTrue(try fetchCachedSessions(in: context).isEmpty)
        XCTAssertTrue(try fetchCachedMessages(in: context).isEmpty)
    }

    func testCacheMessagesRoundTripsAttachments() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        let messages = [
            ChatMessage(
                role: "user",
                content: "Here is a photo",
                timestamp: 1_770_000_000,
                messageId: "m1",
                attachments: [
                    MessageAttachment(
                        name: "photo.png",
                        path: "/uploads/photo.png",
                        mime: "image/png",
                        size: 12345,
                        isImage: true
                    )
                ]
            )
        ]

        try CacheStore.cacheMessages(
            messages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try CacheStore.cachedMessages(
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            now: now
        )

        XCTAssertEqual(cachedMessages.count, 1)
        let attachment = try XCTUnwrap(cachedMessages.first?.attachments?.first)
        XCTAssertEqual(attachment.name, "photo.png")
        XCTAssertEqual(attachment.path, "/uploads/photo.png")
        XCTAssertEqual(attachment.mime, "image/png")
        XCTAssertEqual(attachment.size, 12345)
        XCTAssertEqual(attachment.isImage, true)
    }

    func testCacheMessagesRoundTripsToolCallAndStructuredContentFields() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        let toolCalls: [JSONValue] = [
            .object([
                "id": .string("call-1"),
                "function": .object([
                    "name": .string("read_file"),
                    "arguments": .string("{\"path\": \"notes.txt\"}")
                ])
            ])
        ]
        let contentParts: [JSONValue] = [
            .object(["type": .string("text"), "text": .string("Reading the file")]),
            .object(["type": .string("tool_use"), "id": .string("call-1")])
        ]

        let messages = [
            ChatMessage(
                role: "assistant",
                content: "Reading the file",
                timestamp: 1_770_000_000,
                messageId: "m1",
                toolUseId: "call-1",
                toolCalls: toolCalls,
                contentParts: contentParts
            )
        ]

        try CacheStore.cacheMessages(
            messages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try CacheStore.cachedMessages(
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            now: now
        )

        XCTAssertEqual(cachedMessages.count, 1)
        let restored = try XCTUnwrap(cachedMessages.first)
        XCTAssertEqual(restored.toolUseId, "call-1")
        XCTAssertEqual(restored.toolCalls, toolCalls)
        XCTAssertEqual(restored.contentParts, contentParts)
    }

    // MARK: - Per-server isolation (#18)

    func testCachedMessagesAreScopedToTheirServerForTheSameSessionID() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        try CacheStore.cacheMessages(
            [ChatMessage(role: "user", content: "From A", timestamp: 1_770_000_000, messageId: "m1")],
            serverURL: serverA,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )
        try CacheStore.cacheMessages(
            [ChatMessage(role: "user", content: "From B", timestamp: 1_770_000_000, messageId: "m1")],
            serverURL: serverB,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )

        let aMessages = try CacheStore.cachedMessages(serverURL: serverA, sessionID: "shared", in: context, now: now)
        let bMessages = try CacheStore.cachedMessages(serverURL: serverB, sessionID: "shared", in: context, now: now)

        XCTAssertEqual(aMessages.map(\.content), ["From A"])
        XCTAssertEqual(bMessages.map(\.content), ["From B"])
    }

    func testCacheSessionsForOneServerDoesNotDeleteAnotherServersStaleSessions() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        try CacheStore.cacheSessions(
            try XCTUnwrap(decodeSessions("""
            {"sessions": [{"session_id": "a1", "title": "A one", "last_message_at": 1770000000, "archived": false}]}
            """).sessions),
            serverURL: serverA,
            in: context,
            cachedAt: cachedAt
        )
        try CacheStore.cacheSessions(
            try XCTUnwrap(decodeSessions("""
            {"sessions": [{"session_id": "b1", "title": "B one", "last_message_at": 1770000000, "archived": false}]}
            """).sessions),
            serverURL: serverB,
            in: context,
            cachedAt: cachedAt
        )

        // Re-cache server A with a different set so its stale-removal pass runs.
        // It must drop A's "a1" without touching server B's "b1".
        try CacheStore.cacheSessions(
            try XCTUnwrap(decodeSessions("""
            {"sessions": [{"session_id": "a2", "title": "A two", "last_message_at": 1770000100, "archived": false}]}
            """).sessions),
            serverURL: serverA,
            in: context,
            cachedAt: cachedAt
        )

        let aSessions = try CacheStore.cachedSessions(serverURL: serverA, in: context, now: now)
        let bSessions = try CacheStore.cachedSessions(serverURL: serverB, in: context, now: now)

        XCTAssertEqual(aSessions.map(\.sessionId), ["a2"])
        XCTAssertEqual(bSessions.map(\.sessionId), ["b1"])
    }

    func testCacheMessagesForOneServerDoesNotDeleteAnotherServersMessages() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        try CacheStore.cacheMessages(
            [ChatMessage(role: "user", content: "From A", timestamp: 1_770_000_000, messageId: "m1")],
            serverURL: serverA,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )
        try CacheStore.cacheMessages(
            [ChatMessage(role: "user", content: "From B", timestamp: 1_770_000_000, messageId: "m1")],
            serverURL: serverB,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )

        // Re-cache server A's session with no messages so its stale-removal pass
        // wipes A's window; server B's identically-keyed session must survive.
        try CacheStore.cacheMessages(
            [],
            serverURL: serverA,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )

        let aMessages = try CacheStore.cachedMessages(serverURL: serverA, sessionID: "shared", in: context, now: now)
        let bMessages = try CacheStore.cachedMessages(serverURL: serverB, sessionID: "shared", in: context, now: now)

        XCTAssertTrue(aMessages.isEmpty)
        XCTAssertEqual(bMessages.map(\.content), ["From B"])
    }

    func testClearCacheRemovesOnlyTheGivenServersData() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        for (server, title) in [(serverA, "A one"), (serverB, "B one")] {
            try CacheStore.cacheSessions(
                try XCTUnwrap(decodeSessions("""
                {"sessions": [{"session_id": "s1", "title": "\(title)", "last_message_at": 1770000000, "archived": false}]}
                """).sessions),
                serverURL: server,
                in: context,
                cachedAt: cachedAt
            )
            try CacheStore.cacheMessages(
                [ChatMessage(role: "user", content: title, timestamp: 1_770_000_000, messageId: "m1")],
                serverURL: server,
                sessionID: "s1",
                in: context,
                cachedAt: cachedAt
            )
        }

        try CacheStore.clearCache(for: serverA, in: context)

        XCTAssertTrue(try CacheStore.cachedSessions(serverURL: serverA, in: context, now: now).isEmpty)
        XCTAssertTrue(try CacheStore.cachedMessages(serverURL: serverA, sessionID: "s1", in: context, now: now).isEmpty)
        XCTAssertEqual(
            try CacheStore.cachedSessions(serverURL: serverB, in: context, now: now).map(\.sessionId),
            ["s1"]
        )
        XCTAssertEqual(
            try CacheStore.cachedMessages(serverURL: serverB, sessionID: "s1", in: context, now: now).map(\.content),
            ["B one"]
        )
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CachedSession.self,
            CachedMessage.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    private func decodeSessions(_ json: String) throws -> SessionsResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionsResponse.self, from: Data(json.utf8))
    }

    private func fetchCachedSessions(in context: ModelContext) throws -> [CachedSession] {
        try context.fetch(FetchDescriptor<CachedSession>())
    }

    private func fetchCachedMessages(in context: ModelContext) throws -> [CachedMessage] {
        try context.fetch(FetchDescriptor<CachedMessage>())
    }
}
