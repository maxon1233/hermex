import Foundation

enum SessionNavigationDestination: Hashable, Identifiable {
    case session(SessionSummary)
    case newChat(PendingNewChatRoute)
    case utility(SessionListUtilityDestination)

    var id: Self { self }

    var selectedSessionID: String? {
        guard case .session(let session) = self else { return nil }
        return session.sessionId
    }
}

enum SessionListRefreshPolicy {
    /// SwiftUI keeps the session-list view mounted while a compact-width detail is
    /// pushed, so returning from chat does not reliably produce another `onAppear`.
    /// A destination transition is the authoritative signal that the detail the
    /// user was interacting with is no longer current.
    static func shouldRefreshAfterNavigationChange(
        from oldDestination: SessionNavigationDestination?,
        to newDestination: SessionNavigationDestination?
    ) -> Bool {
        oldDestination != nil && oldDestination != newDestination
    }
}

struct SessionNavigationState: Equatable {
    private(set) var destination: SessionNavigationDestination?
    private(set) var rootRevision = 0
    private var newChatSessionID: String?

    var selectedSessionID: String? {
        destination?.selectedSessionID ?? newChatSessionID
    }

    var isCreatingNewChat: Bool {
        guard case .newChat = destination else { return false }
        return newChatSessionID == nil
    }

    mutating func select(_ session: SessionSummary) {
        rootRevision += 1
        newChatSessionID = nil
        destination = .session(session)
    }

    mutating func select(_ route: PendingNewChatRoute) {
        rootRevision += 1
        newChatSessionID = nil
        destination = .newChat(route)
    }

    mutating func select(_ utility: SessionListUtilityDestination) {
        rootRevision += 1
        newChatSessionID = nil
        destination = .utility(utility)
    }

    mutating func remember(_ session: SessionSummary) {
        guard let sessionID = Self.normalized(session.sessionId) else { return }
        if case .newChat = destination {
            newChatSessionID = sessionID
        }
    }

    mutating func clearDestination() {
        destination = nil
        newChatSessionID = nil
    }

    /// Invalidates the visible detail when its session is removed.
    mutating func remove(sessionID: String?) {
        guard let sessionID = Self.normalized(sessionID) else { return }

        if selectedSessionID == sessionID {
            destination = nil
            newChatSessionID = nil
        }
    }

    private static func normalized(_ sessionID: String?) -> String? {
        guard let sessionID else { return nil }
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
enum ChatComposerDraftPersistence {
    private static let keyPrefix = "chatComposer.draft."

    static func load(
        for sessionID: String?,
        server: URL,
        defaults: UserDefaults = .standard
    ) -> String? {
        guard let key = key(for: sessionID, server: server) else { return nil }
        return defaults.string(forKey: key)
    }

    static func initialDraft(
        _ explicitDraft: String,
        for sessionID: String?,
        server: URL,
        defaults: UserDefaults = .standard
    ) -> String {
        guard explicitDraft.isEmpty else { return explicitDraft }
        return load(for: sessionID, server: server, defaults: defaults) ?? ""
    }

    static func save(
        _ draft: String,
        for sessionID: String?,
        server: URL,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(for: sessionID, server: server) else { return }

        if draft.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(draft, forKey: key)
        }
    }

    private static func key(for sessionID: String?, server: URL) -> String? {
        guard let sessionID else { return nil }
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return nil }
        return keyPrefix + server.absoluteString + "." + normalizedSessionID
    }
}
