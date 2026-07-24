import XCTest
@testable import HermesMobile

final class SessionNavigationStateTests: XCTestCase {
    func testSelectingSessionUpdatesDestinationAndRestorationID() {
        let session = SessionSummary(sessionId: "session-1", title: "One")
        var state = SessionNavigationState()

        state.select(session)

        XCTAssertEqual(state.destination, .session(session))
        XCTAssertEqual(state.selectedSessionID, "session-1")
        XCTAssertEqual(state.lastSelectedSessionID, "session-1")
    }

    func testRestoreSelectsStoredSessionWhenItStillExists() {
        let first = SessionSummary(sessionId: "session-1", title: "One")
        let second = SessionSummary(sessionId: "session-2", title: "Two")
        var state = SessionNavigationState(lastSelectedSessionID: "session-2")

        state.restoreIfNeeded(from: [first, second])

        XCTAssertEqual(state.destination, .session(second))
        XCTAssertEqual(state.lastSelectedSessionID, "session-2")
    }

    func testRestoreClearsStoredSelectionWhenSessionNoLongerExists() {
        var state = SessionNavigationState(lastSelectedSessionID: "missing")

        state.restoreIfNeeded(from: [SessionSummary(sessionId: "session-1")])

        XCTAssertNil(state.destination)
        XCTAssertNil(state.lastSelectedSessionID)
    }

    func testRestorePreservesStoredSelectionWhenSessionListIsNotAuthoritative() {
        var state = SessionNavigationState(lastSelectedSessionID: "session-1")

        state.restoreIfNeeded(from: [], clearsMissingSelection: false)

        XCTAssertNil(state.destination)
        XCTAssertEqual(state.lastSelectedSessionID, "session-1")
    }

    func testExplicitNewChatRouteOverridesStoredSelection() {
        let route = PendingNewChatRoute(initialDraft: "Shared draft")
        var state = SessionNavigationState(lastSelectedSessionID: "session-1")
        state.select(route)

        state.restoreIfNeeded(from: [SessionSummary(sessionId: "session-1")])

        XCTAssertEqual(state.destination, .newChat(route))
        XCTAssertEqual(state.lastSelectedSessionID, "session-1")
    }

    func testExplicitSessionRouteOverridesStoredSelection() {
        let stored = SessionSummary(sessionId: "stored")
        let deepLinked = SessionSummary(sessionId: "deep-linked")
        var state = SessionNavigationState(lastSelectedSessionID: "stored")
        state.select(deepLinked)

        state.restoreIfNeeded(from: [stored])

        XCTAssertEqual(state.destination, .session(deepLinked))
        XCTAssertEqual(state.lastSelectedSessionID, "deep-linked")
    }

    func testCreatedSessionRemainsSelectedWhileNewChatRouteOwnsItsDraft() {
        let route = PendingNewChatRoute(initialDraft: "Shared draft")
        let created = SessionSummary(sessionId: "created-session")
        var state = SessionNavigationState()
        state.select(route)
        XCTAssertTrue(state.isCreatingNewChat)

        state.remember(created)

        XCTAssertEqual(state.destination, .newChat(route))
        XCTAssertEqual(state.selectedSessionID, "created-session")
        XCTAssertEqual(state.lastSelectedSessionID, "created-session")
        XCTAssertFalse(state.isCreatingNewChat)
    }

    func testSelectingAnotherNewChatRouteStartsFreshCreationState() {
        let firstRoute = PendingNewChatRoute()
        let secondRoute = PendingNewChatRoute()
        var state = SessionNavigationState()
        state.select(firstRoute)
        state.remember(SessionSummary(sessionId: "created-session"))

        state.select(secondRoute)

        XCTAssertEqual(state.destination, .newChat(secondRoute))
        XCTAssertNil(state.selectedSessionID)
        XCTAssertTrue(state.isCreatingNewChat)
    }

    func testRemovingSelectedSessionClearsDestinationAndRestorationID() {
        let session = SessionSummary(sessionId: "session-1")
        var state = SessionNavigationState()
        state.select(session)

        state.remove(sessionID: "session-1")

        XCTAssertNil(state.destination)
        XCTAssertNil(state.lastSelectedSessionID)
    }

    func testRemovingRememberedSessionPreservesDifferentVisibleDestination() {
        var state = SessionNavigationState(lastSelectedSessionID: "session-1")
        state.select(SessionListUtilityDestination.tasks)

        state.remove(sessionID: "session-1")

        XCTAssertEqual(state.destination, .utility(.tasks))
        XCTAssertNil(state.lastSelectedSessionID)
    }

    func testUtilityDestinationRemainsSelectedAcrossLayoutReevaluation() {
        var state = SessionNavigationState()
        state.select(SessionListUtilityDestination.settings(nil))

        let reevaluatedState = state

        XCTAssertEqual(reevaluatedState.destination, .utility(.settings(nil)))
        XCTAssertNil(reevaluatedState.selectedSessionID)
    }

    func testReselectingRootDestinationAdvancesNavigationRevision() {
        var state = SessionNavigationState()
        state.select(SessionListUtilityDestination.skills)
        let firstRevision = state.rootRevision

        state.select(SessionListUtilityDestination.skills)

        XCTAssertEqual(state.destination, .utility(.skills))
        XCTAssertGreaterThan(state.rootRevision, firstRevision)
    }

    func testReadableContentWidthsKeepSecondaryAndWorkspaceSurfacesDistinct() {
        XCTAssertEqual(AdaptiveReadableContentWidth.secondaryDestination, 800)
        XCTAssertEqual(AdaptiveReadableContentWidth.workspace, 1_000)
        XCTAssertLessThan(
            AdaptiveReadableContentWidth.secondaryDestination,
            AdaptiveReadableContentWidth.workspace
        )
    }

    func testPersistenceUsesIndependentKeysPerServer() throws {
        let suiteName = "SessionNavigationStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstServer = try XCTUnwrap(URL(string: "https://first.example.com"))
        let secondServer = try XCTUnwrap(URL(string: "https://second.example.com"))

        SessionNavigationPersistence.save("first-session", for: firstServer, defaults: defaults)
        SessionNavigationPersistence.save("second-session", for: secondServer, defaults: defaults)

        XCTAssertEqual(
            SessionNavigationPersistence.load(for: firstServer, defaults: defaults),
            "first-session"
        )
        XCTAssertEqual(
            SessionNavigationPersistence.load(for: secondServer, defaults: defaults),
            "second-session"
        )
    }
}

final class ChatComposerDraftPersistenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let server = URL(string: "https://hermes.example.com")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ChatComposerDraftPersistenceTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func testDraftRoundTripsForSession() {
        ChatComposerDraftPersistence.save(
            "Remember this",
            for: "session-1",
            server: server,
            defaults: defaults
        )

        XCTAssertEqual(
            ChatComposerDraftPersistence.load(
                for: "session-1",
                server: server,
                defaults: defaults
            ),
            "Remember this"
        )
    }

    func testDraftsAreIsolatedBySessionAndServer() throws {
        let otherServer = try XCTUnwrap(URL(string: "https://other.example.com"))

        ChatComposerDraftPersistence.save(
            "First session",
            for: "session-1",
            server: server,
            defaults: defaults
        )
        ChatComposerDraftPersistence.save(
            "Second session",
            for: "session-2",
            server: server,
            defaults: defaults
        )
        ChatComposerDraftPersistence.save(
            "Other server",
            for: "session-1",
            server: otherServer,
            defaults: defaults
        )

        XCTAssertEqual(
            ChatComposerDraftPersistence.load(
                for: "session-1",
                server: server,
                defaults: defaults
            ),
            "First session"
        )
        XCTAssertEqual(
            ChatComposerDraftPersistence.load(
                for: "session-2",
                server: server,
                defaults: defaults
            ),
            "Second session"
        )
        XCTAssertEqual(
            ChatComposerDraftPersistence.load(
                for: "session-1",
                server: otherServer,
                defaults: defaults
            ),
            "Other server"
        )
    }

    func testSavingEmptyDraftClearsStoredDraft() {
        ChatComposerDraftPersistence.save(
            "Will be sent",
            for: "session-1",
            server: server,
            defaults: defaults
        )

        ChatComposerDraftPersistence.save(
            "",
            for: "session-1",
            server: server,
            defaults: defaults
        )

        XCTAssertNil(
            ChatComposerDraftPersistence.load(
                for: "session-1",
                server: server,
                defaults: defaults
            )
        )
    }

    func testExplicitIncomingDraftTakesPrecedenceOverStoredDraft() {
        ChatComposerDraftPersistence.save(
            "Stored draft",
            for: "session-1",
            server: server,
            defaults: defaults
        )

        XCTAssertEqual(
            ChatComposerDraftPersistence.initialDraft(
                "Shared text",
                for: "session-1",
                server: server,
                defaults: defaults
            ),
            "Shared text"
        )
        XCTAssertEqual(
            ChatComposerDraftPersistence.initialDraft(
                "",
                for: "session-1",
                server: server,
                defaults: defaults
            ),
            "Stored draft"
        )
    }

    func testMissingSessionIDDoesNotPersistDraft() {
        ChatComposerDraftPersistence.save(
            "No session",
            for: nil,
            server: server,
            defaults: defaults
        )

        XCTAssertNil(
            ChatComposerDraftPersistence.load(
                for: nil,
                server: server,
                defaults: defaults
            )
        )
    }
}
