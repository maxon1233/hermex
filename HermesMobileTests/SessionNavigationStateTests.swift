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
