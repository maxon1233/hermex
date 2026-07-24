import XCTest
@testable import HermesMobile

final class SessionNavigationStateTests: XCTestCase {
    func testFreshNavigationStateStartsOnSessionList() {
        let state = SessionNavigationState()

        XCTAssertNil(state.destination)
        XCTAssertNil(state.selectedSessionID)
    }

    func testSelectingSessionUpdatesDestination() {
        let session = SessionSummary(sessionId: "session-1", title: "One")
        var state = SessionNavigationState()

        state.select(session)

        XCTAssertEqual(state.destination, .session(session))
        XCTAssertEqual(state.selectedSessionID, "session-1")
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

    func testRemovingSelectedSessionClearsDestination() {
        let session = SessionSummary(sessionId: "session-1")
        var state = SessionNavigationState()
        state.select(session)

        state.remove(sessionID: "session-1")

        XCTAssertNil(state.destination)
    }

    func testRemovingUnselectedSessionPreservesVisibleDestination() {
        var state = SessionNavigationState()
        state.select(SessionListUtilityDestination.tasks)

        state.remove(sessionID: "session-1")

        XCTAssertEqual(state.destination, .utility(.tasks))
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

    func testRefreshPolicyReloadsAfterReturningFromExistingSession() {
        let session = SessionSummary(sessionId: "session-1")

        XCTAssertTrue(
            SessionListRefreshPolicy.shouldRefreshAfterNavigationChange(
                from: .session(session),
                to: nil
            )
        )
    }

    func testRefreshPolicyReloadsAfterReturningFromNewSession() {
        let route = PendingNewChatRoute()

        XCTAssertTrue(
            SessionListRefreshPolicy.shouldRefreshAfterNavigationChange(
                from: .newChat(route),
                to: nil
            )
        )
    }

    func testRefreshPolicyReloadsWhenSwitchingDetails() {
        let first = SessionSummary(sessionId: "session-1")
        let second = SessionSummary(sessionId: "session-2")

        XCTAssertTrue(
            SessionListRefreshPolicy.shouldRefreshAfterNavigationChange(
                from: .session(first),
                to: .session(second)
            )
        )
    }

    func testRefreshPolicySkipsInitialSelectionAndUnchangedDestination() {
        let session = SessionSummary(sessionId: "session-1")
        let destination = SessionNavigationDestination.session(session)

        XCTAssertFalse(
            SessionListRefreshPolicy.shouldRefreshAfterNavigationChange(
                from: nil,
                to: destination
            )
        )
        XCTAssertFalse(
            SessionListRefreshPolicy.shouldRefreshAfterNavigationChange(
                from: destination,
                to: destination
            )
        )
    }

    func testReadableContentWidthsKeepSecondaryAndWorkspaceSurfacesDistinct() {
        XCTAssertEqual(AdaptiveReadableContentWidth.secondaryDestination, 800)
        XCTAssertEqual(AdaptiveReadableContentWidth.workspace, 1_000)
        XCTAssertLessThan(
            AdaptiveReadableContentWidth.secondaryDestination,
            AdaptiveReadableContentWidth.workspace
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
