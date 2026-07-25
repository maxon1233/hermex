import XCTest
@testable import HermesMobile

final class ChatScrollPolicyTests: XCTestCase {
    func testExistingTranscriptUsesBottomAsItsInitialLayoutAnchor() {
        XCTAssertEqual(ChatScrollPolicy.initialTranscriptAnchor, .bottom)
    }

    func testTranscriptSizeChangesStayBottomAnchoredOnlyWhileFollowingLatest() {
        XCTAssertEqual(
            ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: true),
            .bottom
        )
        XCTAssertNil(ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: false))
    }

    func testInitialAsyncWorkWaitsForNavigationAppearanceCompletion() {
        XCTAssertFalse(ChatInitialAppearancePolicy.shouldBeginAsyncWork(hasCompletedAppearance: false))
        XCTAssertTrue(ChatInitialAppearancePolicy.shouldBeginAsyncWork(hasCompletedAppearance: true))
    }

    func testBottomThresholdLoosensWhileStreaming() {
        XCTAssertEqual(
            ChatScrollPolicy.bottomThreshold(isStreaming: false),
            ChatScrollPolicy.bottomDetectionThreshold
        )
        XCTAssertEqual(
            ChatScrollPolicy.bottomThreshold(isStreaming: true),
            ChatScrollPolicy.streamingBottomDetectionThreshold
        )
        XCTAssertGreaterThan(
            ChatScrollPolicy.bottomThreshold(isStreaming: true),
            ChatScrollPolicy.bottomThreshold(isStreaming: false)
        )
    }

    func testIsNearBottomUsesIdleThresholdWhenNotStreaming() {
        XCTAssertTrue(ChatScrollPolicy.isNearBottom(distanceFromBottom: 80, isStreaming: false))
        XCTAssertFalse(ChatScrollPolicy.isNearBottom(distanceFromBottom: 81, isStreaming: false))
    }

    func testIsNearBottomUsesLooserThresholdWhileStreaming() {
        // 120pt is past the idle threshold but still "near bottom" while streaming.
        XCTAssertFalse(ChatScrollPolicy.isNearBottom(distanceFromBottom: 120, isStreaming: false))
        XCTAssertTrue(ChatScrollPolicy.isNearBottom(distanceFromBottom: 120, isStreaming: true))
        XCTAssertFalse(ChatScrollPolicy.isNearBottom(distanceFromBottom: 161, isStreaming: true))
    }

    func testShouldEnterReadingOlderRequiresHysteresisPastThreshold() {
        let threshold = ChatScrollPolicy.bottomThreshold(isStreaming: false)
        let hysteresis = ChatScrollPolicy.readingOlderHysteresis

        XCTAssertFalse(
            ChatScrollPolicy.shouldEnterReadingOlder(
                distanceFromBottom: threshold + hysteresis,
                isStreaming: false
            )
        )
        XCTAssertTrue(
            ChatScrollPolicy.shouldEnterReadingOlder(
                distanceFromBottom: threshold + hysteresis + 1,
                isStreaming: false
            )
        )
    }

    func testAutoScrollPausedWhileUserInteracting() {
        XCTAssertTrue(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: true,
                cooldownUntil: nil
            )
        )
    }

    func testAutoScrollPausedDuringCooldownWindow() {
        let now = Date()
        let future = now.addingTimeInterval(0.1)

        XCTAssertTrue(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: false,
                cooldownUntil: future,
                now: now
            )
        )
    }

    func testAutoScrollResumesAfterCooldownExpires() {
        let now = Date()
        let past = now.addingTimeInterval(-0.1)

        XCTAssertFalse(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: false,
                cooldownUntil: past,
                now: now
            )
        )
    }

    func testAutoScrollNotPausedWithoutInteractionOrCooldown() {
        XCTAssertFalse(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: false,
                cooldownUntil: nil
            )
        )
    }

    func testCooldownDeadlineIsUserScrollCooldownInFuture() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let deadline = ChatScrollPolicy.cooldownDeadline(after: base)

        XCTAssertEqual(
            deadline.timeIntervalSince(base),
            ChatScrollPolicy.userScrollCooldown,
            accuracy: 0.0001
        )
    }

    func testRapidViewportSamplesStayInMemoryUntilOneExactFlush() {
        var writes: [ChatTranscriptScrollPosition] = []
        let recorder = ChatTranscriptScrollPositionRecorder(
            initialPosition: nil,
            writer: { writes.append($0) }
        )

        let positions = (0..<120).map { index in
            ChatTranscriptScrollPosition(
                renderID: "transcript:\(index)",
                messageID: "message-\(index)",
                offsetFromRowTop: Double(index) + 0.375
            )
        }
        positions.forEach(recorder.record)

        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(recorder.latestPosition, positions.last)
        XCTAssertTrue(recorder.flush())
        XCTAssertEqual(writes, [positions.last!])
        XCTAssertFalse(recorder.flush())
        XCTAssertEqual(writes.count, 1)
    }

    func testLifecycleFlushAlwaysUsesLatestViewportAfterEarlierCommit() {
        let initialPosition = ChatTranscriptScrollPosition(
            renderID: "transcript:4",
            messageID: "message-4",
            offsetFromRowTop: 18.25
        )
        let settledPosition = ChatTranscriptScrollPosition(
            renderID: "transcript:12",
            messageID: "message-12",
            offsetFromRowTop: 143.5
        )
        let leavingPosition = ChatTranscriptScrollPosition(
            renderID: "transcript:18",
            messageID: "message-18",
            offsetFromRowTop: 87.875
        )
        var writes: [ChatTranscriptScrollPosition] = []
        let recorder = ChatTranscriptScrollPositionRecorder(
            initialPosition: initialPosition,
            writer: { writes.append($0) }
        )

        recorder.record(settledPosition)
        XCTAssertTrue(recorder.flush())
        recorder.record(leavingPosition)

        XCTAssertEqual(writes, [settledPosition])
        XCTAssertTrue(recorder.flush())
        XCTAssertEqual(writes, [settledPosition, leavingPosition])
        XCTAssertEqual(recorder.latestPosition, leavingPosition)
    }

    func testUnchangedRestoredViewportDoesNotRewritePersistence() {
        let restoredPosition = ChatTranscriptScrollPosition(
            renderID: "transcript:8",
            messageID: "message-8",
            offsetFromRowTop: 63
        )
        var writes: [ChatTranscriptScrollPosition] = []
        let recorder = ChatTranscriptScrollPositionRecorder(
            initialPosition: restoredPosition,
            writer: { writes.append($0) }
        )

        recorder.record(restoredPosition)

        XCTAssertFalse(recorder.flush())
        XCTAssertTrue(writes.isEmpty)
    }

    func testTranscriptScrollPersistenceUsesIndependentServerAndSessionKeys() throws {
        let suiteName = "ChatScrollPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstServer = try XCTUnwrap(URL(string: "https://first.example"))
        let secondServer = try XCTUnwrap(URL(string: "https://second.example"))
        let firstPosition = ChatTranscriptScrollPosition(
            renderID: "transcript:12",
            messageID: "message-12",
            offsetFromRowTop: 148.5
        )
        let secondPosition = ChatTranscriptScrollPosition(
            renderID: "transcript:34",
            offsetFromRowTop: 27
        )
        let thirdPosition = ChatTranscriptScrollPosition(
            renderID: "transcript:56",
            offsetFromRowTop: -8
        )

        ChatTranscriptScrollPersistence.save(
            firstPosition,
            for: firstServer,
            sessionID: "session-1",
            defaults: defaults
        )
        ChatTranscriptScrollPersistence.save(
            secondPosition,
            for: firstServer,
            sessionID: "session-2",
            defaults: defaults
        )
        ChatTranscriptScrollPersistence.save(
            thirdPosition,
            for: secondServer,
            sessionID: "session-1",
            defaults: defaults
        )

        XCTAssertEqual(
            ChatTranscriptScrollPersistence.load(
                for: firstServer,
                sessionID: "session-1",
                defaults: defaults
            ),
            firstPosition
        )
        XCTAssertEqual(
            ChatTranscriptScrollPersistence.load(
                for: firstServer,
                sessionID: "session-2",
                defaults: defaults
            ),
            secondPosition
        )
        XCTAssertEqual(
            ChatTranscriptScrollPersistence.load(
                for: secondServer,
                sessionID: "session-1",
                defaults: defaults
            ),
            thirdPosition
        )
    }

    func testTranscriptScrollPersistenceLatestPositionReplacesPreviousVisit() throws {
        let suiteName = "ChatScrollPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let server = try XCTUnwrap(URL(string: "https://example.com"))
        let previousPosition = ChatTranscriptScrollPosition(
            renderID: "transcript:12",
            offsetFromRowTop: 64
        )
        let latestPosition = ChatTranscriptScrollPosition(
            renderID: "transcript:28",
            messageID: "message-28",
            offsetFromRowTop: 311.5
        )
        ChatTranscriptScrollPersistence.save(
            previousPosition,
            for: server,
            sessionID: "session-1",
            defaults: defaults
        )
        ChatTranscriptScrollPersistence.save(
            latestPosition,
            for: server,
            sessionID: "session-1",
            defaults: defaults
        )

        XCTAssertEqual(
            ChatTranscriptScrollPersistence.load(
                for: server,
                sessionID: "session-1",
                defaults: defaults
            ),
            latestPosition
        )
    }

    func testTranscriptScrollPersistenceDoesNotStoreMissingPosition() throws {
        let suiteName = "ChatScrollPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let server = try XCTUnwrap(URL(string: "https://example.com"))
        ChatTranscriptScrollPersistence.save(
            nil,
            for: server,
            sessionID: "session-1",
            defaults: defaults
        )

        XCTAssertNil(
            ChatTranscriptScrollPersistence.load(
                for: server,
                sessionID: "session-1",
                defaults: defaults
            )
        )
    }

    func testTranscriptScrollPersistenceMigratesLegacyRowOnlyValue() throws {
        let suiteName = "ChatScrollPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let server = try XCTUnwrap(URL(string: "https://example.com"))
        defaults.set(
            "transcript:12",
            forKey: ChatTranscriptScrollPersistence.key(
                for: server,
                sessionID: "session-1"
            )
        )

        XCTAssertEqual(
            ChatTranscriptScrollPersistence.load(
                for: server,
                sessionID: "session-1",
                defaults: defaults
            ),
            ChatTranscriptScrollPosition(
                renderID: "transcript:12",
                offsetFromRowTop: 0
            )
        )
    }

    func testReadingPositionUsesFirstRowIntersectingViewportTop() {
        let position = ChatTranscriptReadingPositionResolver.resolve(
            frames: [
                ChatTranscriptRowContentFrame(
                    renderID: "transcript:11",
                    minY: 0,
                    maxY: 480
                ),
                ChatTranscriptRowContentFrame(
                    renderID: "transcript:12",
                    messageID: "message-12",
                    minY: 500,
                    maxY: 1_220
                ),
                ChatTranscriptRowContentFrame(
                    renderID: "transcript:13",
                    minY: 1_240,
                    maxY: 1_420
                )
            ],
            visibleContentOffsetY: 620
        )

        XCTAssertEqual(
            position,
            ChatTranscriptScrollPosition(
                renderID: "transcript:12",
                messageID: "message-12",
                offsetFromRowTop: 120
            )
        )
    }

    func testReadingPositionResolutionDoesNotDependOnFrameOrder() {
        let position = ChatTranscriptReadingPositionResolver.resolve(
            frames: [
                ChatTranscriptRowContentFrame(
                    renderID: "transcript:13",
                    minY: 1_240,
                    maxY: 1_420
                ),
                ChatTranscriptRowContentFrame(
                    renderID: "transcript:11",
                    minY: 0,
                    maxY: 480
                ),
                ChatTranscriptRowContentFrame(
                    renderID: "transcript:12",
                    messageID: "message-12",
                    minY: 500,
                    maxY: 1_220
                ),
            ],
            visibleContentOffsetY: 620
        )

        XCTAssertEqual(
            position,
            ChatTranscriptScrollPosition(
                renderID: "transcript:12",
                messageID: "message-12",
                offsetFromRowTop: 120
            )
        )
    }

    func testTranscriptMessageIdentityFingerprintsRowsWhenServerIDIsMissing() {
        let first = ChatMessage(
            role: "assistant",
            content: "Same persisted response",
            timestamp: 123,
            messageId: nil
        )
        let equivalent = ChatMessage(
            role: "assistant",
            content: "Same persisted response",
            timestamp: 123,
            messageId: nil
        )
        let changed = ChatMessage(
            role: "assistant",
            content: "Different response",
            timestamp: 123,
            messageId: nil
        )

        let identity = ChatTranscriptMessageIdentity.resolve(for: first)
        XCTAssertTrue(identity.hasPrefix("fingerprint:"))
        XCTAssertEqual(
            identity,
            ChatTranscriptMessageIdentity.resolve(for: equivalent)
        )
        XCTAssertNotEqual(
            identity,
            ChatTranscriptMessageIdentity.resolve(for: changed)
        )
    }

    func testTranscriptMessageIdentityPrefersServerID() {
        let message = ChatMessage(
            role: "assistant",
            content: "Response",
            timestamp: 123,
            messageId: " stable-message "
        )

        XCTAssertEqual(
            ChatTranscriptMessageIdentity.resolve(for: message),
            "stable-message"
        )
    }

    func testReadingPositionPreservesGapAboveFirstVisibleRow() {
        let position = ChatTranscriptReadingPositionResolver.resolve(
            frames: [
                ChatTranscriptRowContentFrame(
                    renderID: "transcript:12",
                    minY: 18,
                    maxY: 240
                )
            ],
            visibleContentOffsetY: 0
        )

        XCTAssertEqual(
            position,
            ChatTranscriptScrollPosition(
                renderID: "transcript:12",
                offsetFromRowTop: -18
            )
        )
    }

    func testReadingPositionPastFinalRowRetainsFinalAnchorAndExactOffset() {
        XCTAssertEqual(
            ChatTranscriptReadingPositionResolver.resolve(
                frames: [
                    ChatTranscriptRowContentFrame(
                        renderID: "transcript:12",
                        minY: 100,
                        maxY: 300
                    )
                ],
                visibleContentOffsetY: 475
            ),
            ChatTranscriptScrollPosition(
                renderID: "transcript:12",
                offsetFromRowTop: 375
            )
        )
    }

    func testRestorationTargetUsesStableMessageIDBeforeLegacyRenderID() {
        let position = ChatTranscriptScrollPosition(
            renderID: "transcript:12",
            messageID: "stable-message",
            offsetFromRowTop: 45
        )

        XCTAssertEqual(
            ChatTranscriptReadingPositionResolver.targetContentOffsetY(
                for: position,
                frames: [
                    ChatTranscriptRowContentFrame(
                        renderID: "transcript:12",
                        messageID: "different-message",
                        minY: 200,
                        maxY: 400
                    ),
                    ChatTranscriptRowContentFrame(
                        renderID: "transcript:9",
                        messageID: "stable-message",
                        minY: 800,
                        maxY: 1_100
                    )
                ]
            ),
            845
        )
    }

    func testRestorationDoesNotUseCollidingRenderIDWhenStableMessageIsMissing() {
        let position = ChatTranscriptScrollPosition(
            renderID: "transcript:12",
            messageID: "missing-stable-message",
            offsetFromRowTop: 45
        )

        XCTAssertNil(
            ChatTranscriptReadingPositionResolver.targetContentOffsetY(
                for: position,
                frames: [
                    ChatTranscriptRowContentFrame(
                        renderID: "transcript:12",
                        messageID: "different-message",
                        minY: 200,
                        maxY: 400
                    )
                ]
            )
        )
    }

    func testRestorationUsesRenderIDToDisambiguateDuplicateFingerprints() {
        let duplicateFingerprint = "fingerprint:duplicate"
        let position = ChatTranscriptScrollPosition(
            renderID: "transcript:42",
            messageID: duplicateFingerprint,
            offsetFromRowTop: 35
        )

        XCTAssertEqual(
            ChatTranscriptReadingPositionResolver.targetContentOffsetY(
                for: position,
                frames: [
                    ChatTranscriptRowContentFrame(
                        renderID: "transcript:9",
                        messageID: duplicateFingerprint,
                        minY: 200,
                        maxY: 320
                    ),
                    ChatTranscriptRowContentFrame(
                        renderID: "transcript:42",
                        messageID: duplicateFingerprint,
                        minY: 900,
                        maxY: 1_100
                    )
                ]
            ),
            935
        )
    }

    func testRestorationRejectsAmbiguousFingerprintWithoutIntendedRenderID() {
        let position = ChatTranscriptScrollPosition(
            renderID: "transcript:42",
            messageID: "fingerprint:duplicate",
            offsetFromRowTop: 35
        )

        XCTAssertNil(
            ChatTranscriptReadingPositionResolver.targetContentOffsetY(
                for: position,
                frames: [
                    ChatTranscriptRowContentFrame(
                        renderID: "transcript:8",
                        messageID: "fingerprint:duplicate",
                        minY: 100,
                        maxY: 200
                    ),
                    ChatTranscriptRowContentFrame(
                        renderID: "transcript:9",
                        messageID: "fingerprint:duplicate",
                        minY: 220,
                        maxY: 320
                    )
                ]
            )
        )
    }

    func testRestorationLoadsOlderPageInsteadOfUsingNewerFingerprintDuplicate() {
        let position = ChatTranscriptScrollPosition(
            renderID: "transcript:9",
            messageID: "fingerprint:duplicate",
            offsetFromRowTop: 35
        )

        XCTAssertNil(
            ChatTranscriptReadingPositionResolver.targetContentOffsetY(
                for: position,
                frames: [
                    ChatTranscriptRowContentFrame(
                        renderID: "transcript:42",
                        messageID: "fingerprint:duplicate",
                        minY: 220,
                        maxY: 320
                    )
                ]
            )
        )
    }

    func testRestorationTargetFallsBackToLegacyRenderID() {
        let position = ChatTranscriptScrollPosition(
            renderID: "transcript:12",
            offsetFromRowTop: -8
        )

        XCTAssertEqual(
            ChatTranscriptReadingPositionResolver.targetContentOffsetY(
                for: position,
                frames: [
                    ChatTranscriptRowContentFrame(
                        renderID: "transcript:12",
                        minY: 200,
                        maxY: 400
                    )
                ]
            ),
            192
        )
    }

    func testRestorationMigratesRawOffsetFromUnversionedJSON() throws {
        let legacyJSON = Data(
            """
            {
              "renderID": "transcript:12",
              "messageID": "message-12",
              "offsetFromRowTop": 45
            }
            """.utf8
        )
        let position = try JSONDecoder().decode(
            ChatTranscriptScrollPosition.self,
            from: legacyJSON
        )

        XCTAssertNil(position.coordinateSpaceVersion)
        XCTAssertEqual(
            ChatTranscriptReadingPositionResolver.targetContentOffsetY(
                for: position,
                frames: [
                    ChatTranscriptRowContentFrame(
                        renderID: "transcript:12",
                        messageID: "message-12",
                        minY: 200,
                        maxY: 400
                    )
                ],
                topContentInset: 116
            ),
            361
        )
    }

    func testRestorationClampUsesVisibleContentCoordinateSpace() {
        XCTAssertEqual(
            ChatTranscriptReadingPositionResolver.clampedVisibleContentOffsetY(
                -20,
                contentHeight: 1_000,
                visibleContainerHeight: 300
            ),
            0
        )
        XCTAssertEqual(
            ChatTranscriptReadingPositionResolver.clampedVisibleContentOffsetY(
                700,
                contentHeight: 1_000,
                visibleContainerHeight: 300
            ),
            700
        )
        XCTAssertEqual(
            ChatTranscriptReadingPositionResolver.clampedVisibleContentOffsetY(
                900,
                contentHeight: 1_000,
                visibleContainerHeight: 300
            ),
            700
        )
    }
}
