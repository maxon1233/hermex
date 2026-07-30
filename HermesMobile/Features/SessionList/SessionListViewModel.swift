import Foundation
import Observation
import SwiftData
import SwiftUI

struct SessionListSection: Identifiable {
    enum Kind: String, Equatable {
        case pinned
        case today
        case yesterday
        case thisWeek
        case earlier
    }

    let kind: Kind
    let title: String
    let sessions: [SessionSummary]

    var id: String { kind.rawValue }
}

enum ActiveSessionStateRefreshResult: Equatable {
    case unchanged
    case reloaded
    case failed
}

/// Which project scope the session list shows — the mobile counterpart of the
/// desktop sidebar's `_activeProject` (`static/sessions.js`): `all` = every
/// session, `unassigned` = only sessions with no project (`NO_PROJECT_FILTER`),
/// `project` = one project's sessions.
enum SessionProjectFilter: Equatable {
    case all
    case unassigned
    case project(String)

    /// Desktop reveal rule (hermes-webui #3134): an explicitly selected
    /// project chip shows its own rows even when they are server-stamped
    /// `default_hidden` background executions (cron/webhook).
    func explicitlyReveals(_ session: SessionSummary) -> Bool {
        guard case .project(let projectID) = self else { return false }
        return session.projectId == projectID
    }

    func includes(_ session: SessionSummary) -> Bool {
        switch self {
        case .all:
            return true
        case .unassigned:
            guard let projectID = session.projectId else { return true }
            return projectID.isEmpty
        case .project(let projectID):
            return session.projectId == projectID
        }
    }
}

@MainActor
@Observable
final class SessionListViewModel {
    private(set) var sessions: [SessionSummary] = []
    private(set) var isLoading = false
    private(set) var isCreatingSession = false
    private(set) var isCreatingProject = false
    private(set) var isLoadingProjects = false
    private(set) var isDeletingProject = false
    private(set) var isRenamingSession = false
    private(set) var isRenamingProject = false
    private(set) var isMovingSession = false
    private(set) var isViewingCachedData = false
    private(set) var projects: [ProjectSummary] = []
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var cacheErrorMessage: String?
    private(set) var searchErrorMessage: String?
    private(set) var isSearchingRemoteSessions = false
    private(set) var sessionLoadError: Error?
    private(set) var lastError: Error?
    private(set) var activeProfileName: String?
    private(set) var activeProfileDisplayName: String?
    private(set) var activeProfileModel: String?
    private(set) var activeProfileProvider: String?
    private(set) var profileOptions: [ProfileSummary] = []
    private(set) var isSingleProfileMode = false
    private(set) var isLoadingActiveProfile = false
    private(set) var isSwitchingActiveProfile = false
    private(set) var switchingActiveProfileName: String?
    private(set) var activeProfileErrorMessage: String?
    private(set) var mutatingSessionIDs: Set<String> = []
    /// Total archived sessions reported by the last successful list load
    /// (`archived_count`, issue #17). nil until a load succeeds or when an older
    /// server omits the field — the Archived entry stays hidden then.
    private(set) var archivedCount: Int?

    private(set) var remoteContentSearchSessionIDs: [String] = []
    private var activeRemoteSearchQuery: String?

    private let client: APIClient
    private let sessionMutator: SessionMutator
    private let server: URL

    init(server: URL, client: APIClient? = nil) {
        self.server = server
        let resolvedClient = client ?? APIClient(baseURL: server)
        self.client = resolvedClient
        self.sessionMutator = SessionMutator(client: resolvedClient)

        // Sweep exports leaked by a previous app run (view dismissed while a
        // download was in flight, so the share sheet — and its on-dismiss
        // cleanup — never appeared). `State(initialValue:)` re-runs this init
        // on every parent redraw, so the sweep must be once-per-process (the
        // lazy static below), or it would delete a file an active share sheet
        // is presenting. The first-ever init always precedes the first export,
        // so the single sweep can never race an in-flight export.
        _ = Self.sweepLeakedExportsOnce
    }

    /// Root temp directory holding one UUID subdirectory per export
    /// (see `export(_:format:)`).
    nonisolated static var exportsRootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("session-exports", isDirectory: true)
    }

    /// Lazy static ⇒ runs exactly once per process, on first access.
    nonisolated private static let sweepLeakedExportsOnce: Void = {
        try? FileManager.default.removeItem(at: exportsRootDirectory)
    }()

    var sections: [SessionListSection] {
        Self.makeSections(for: sessions)
    }

    static func makeSections(
        for sessions: [SessionSummary],
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> [SessionListSection] {
        let sortedSessions = sessions.sorted { left, right in
            timestamp(for: left) > timestamp(for: right)
        }
        let pinned = sortedSessions.filter { $0.pinned == true }
        let unpinned = sortedSessions.filter { $0.pinned != true }

        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)
            ?? startOfToday
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? startOfYesterday

        var today: [SessionSummary] = []
        var yesterday: [SessionSummary] = []
        var thisWeek: [SessionSummary] = []
        var earlier: [SessionSummary] = []

        for session in unpinned {
            guard let date = date(for: session) else {
                earlier.append(session)
                continue
            }

            if date >= startOfToday {
                today.append(session)
            } else if date >= startOfYesterday {
                yesterday.append(session)
            } else if date >= startOfWeek {
                thisWeek.append(session)
            } else {
                earlier.append(session)
            }
        }

        return [
            SessionListSection(kind: .pinned, title: String(localized: "Pinned"), sessions: pinned),
            SessionListSection(kind: .today, title: String(localized: "Today"), sessions: today),
            SessionListSection(kind: .yesterday, title: String(localized: "Yesterday"), sessions: yesterday),
            SessionListSection(kind: .thisWeek, title: String(localized: "This Week"), sessions: thisWeek),
            SessionListSection(kind: .earlier, title: String(localized: "Earlier"), sessions: earlier)
        ]
        .filter { !$0.sessions.isEmpty }
    }

    /// Compatibility shape for pre-chip call sites: nil = every project.
    func visibleSessions(
        searchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility = .showAll
    ) -> [SessionSummary] {
        visibleSessions(
            searchText: searchText,
            projectFilter: selectedProjectID.map(SessionProjectFilter.project) ?? .all,
            automatedVisibility: automatedVisibility
        )
    }

    func visibleSessions(
        searchText rawSearchText: String,
        projectFilter: SessionProjectFilter,
        automatedVisibility: AutomatedSessionVisibility = .showAll
    ) -> [SessionSummary] {
        let query = Self.normalizedSearchQuery(rawSearchText)
        let childrenByParentID = Self.childSessionsByParentID(
            in: sessions,
            automatedVisibility: automatedVisibility
        )
        let attachedChildIDs = Set(childrenByParentID.values.joined().compactMap(\.sessionId))
        let baseSessions = sessions.filter { session in
            if let sessionID = session.sessionId, attachedChildIDs.contains(sessionID) {
                return false
            }

            // The explicitly selected project chip reveals its own rows —
            // `default_hidden` background executions and cron rows included
            // (desktop parity, #3134) — while the CLI/Claude Code/subagent
            // preferences keep applying. Nested children stay nested via the
            // check above.
            if projectFilter.explicitlyReveals(session) {
                return automatedVisibility.showsInExplicitlySelectedProject(session)
            }

            guard session.defaultHidden != true else { return false }
            return automatedVisibility.shows(session)
        }
        let projectFilteredSessions = baseSessions.filter { projectFilter.includes($0) }
        // A parent also matches when one of its attached children does, so a
        // child hit surfaces with its context instead of as a bare orphan row.
        let localMatches = projectFilteredSessions.filter { session in
            guard !query.isEmpty else { return true }
            if Self.searchableText(for: session).contains(query) { return true }
            guard let sessionID = session.sessionId else { return false }
            return childrenByParentID[sessionID]?.contains { child in
                Self.searchableText(for: child).contains(query)
            } == true
        }
        let sortedLocalMatches = Self.sortedSessions(localMatches)

        guard !query.isEmpty, activeRemoteSearchQuery == query else {
            return sortedLocalMatches
        }

        let localMatchIDs = Set(sortedLocalMatches.compactMap(\.sessionId))
        let sessionsByID = Dictionary(
            projectFilteredSessions.compactMap { session -> (String, SessionSummary)? in
                guard let sessionID = session.sessionId, !sessionID.isEmpty else { return nil }
                return (sessionID, session)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var attachedAncestorByChildID: [String: String] = [:]
        for (parentID, children) in childrenByParentID {
            for child in children {
                guard let childID = child.sessionId else { continue }
                attachedAncestorByChildID[childID] = parentID
            }
        }
        var seenRemoteIDs = Set<String>()
        let remoteMatches = remoteContentSearchSessionIDs.compactMap { sessionID -> SessionSummary? in
            let resolvedID = attachedAncestorByChildID[sessionID] ?? sessionID
            guard !localMatchIDs.contains(resolvedID),
                  seenRemoteIDs.insert(resolvedID).inserted
            else {
                return nil
            }
            return sessionsByID[resolvedID]
        }

        return sortedLocalMatches + Self.sortedSessions(remoteMatches)
    }

    /// Whether any ordinarily-visible top-level row has no project — the
    /// desktop's `hasUnprojected`, which decides both whether the Unassigned
    /// chip renders and whether the unassigned scope has anything to show.
    func hasUnassignedSessions(
        automatedVisibility: AutomatedSessionVisibility = .showAll
    ) -> Bool {
        let childrenByParentID = Self.childSessionsByParentID(
            in: sessions,
            automatedVisibility: automatedVisibility
        )
        let attachedChildIDs = Set(childrenByParentID.values.joined().compactMap(\.sessionId))

        return sessions.contains { session in
            guard SessionProjectFilter.unassigned.includes(session),
                  session.defaultHidden != true,
                  automatedVisibility.shows(session)
            else {
                return false
            }

            guard let sessionID = session.sessionId else { return true }
            return !attachedChildIDs.contains(sessionID)
        }
    }

    /// Resolves the chip the UI should treat as active. Falls back to All when
    /// the stored choice can no longer show anything: Unassigned with every
    /// session organized (the desktop hides that chip entirely), or a project
    /// that no longer exists (the desktop resets on delete).
    nonisolated static func effectiveProjectFilter(
        _ filter: SessionProjectFilter,
        hasUnassignedSessions: Bool,
        knownProjectIDs: Set<String>
    ) -> SessionProjectFilter {
        switch filter {
        case .all:
            return .all
        case .unassigned:
            return hasUnassignedSessions ? .unassigned : .all
        case .project(let projectID):
            return knownProjectIDs.contains(projectID) ? filter : .all
        }
    }

    /// Child sessions attached beneath their top-level ancestor row, keyed by
    /// that ancestor's session ID — the shape the desktop sidebar builds in
    /// `_attachChildSessionsToSidebarRows` (`static/sessions.js`).
    ///
    /// A child chain (a subagent spawned by another subagent) flattens under its
    /// nearest non-child ancestor, newest first. Children hidden by the
    /// automated-visibility toggles are dropped entirely, and a child whose
    /// parent chain leaves the loaded list is intentionally absent here —
    /// ``visibleSessions(searchText:selectedProjectID:automatedVisibility:)``
    /// keeps it top-level instead so a row can never silently disappear.
    func childSessionsByParentID(
        automatedVisibility: AutomatedSessionVisibility = .showAll
    ) -> [String: [SessionSummary]] {
        Self.childSessionsByParentID(in: sessions, automatedVisibility: automatedVisibility)
    }

    nonisolated static func childSessionsByParentID(
        in sessions: [SessionSummary],
        automatedVisibility: AutomatedSessionVisibility = .showAll
    ) -> [String: [SessionSummary]] {
        var sessionsByID: [String: SessionSummary] = [:]
        for session in sessions {
            guard let sessionID = nonEmpty(session.sessionId) else { continue }
            if sessionsByID[sessionID] == nil {
                sessionsByID[sessionID] = session
            }
        }

        var childrenByParentID: [String: [SessionSummary]] = [:]
        for session in sessions {
            guard session.isChildSessionRow,
                  automatedVisibility.shows(session),
                  let ancestorID = attachedAncestorID(for: session, sessionsByID: sessionsByID)
            else {
                continue
            }

            childrenByParentID[ancestorID, default: []].append(session)
        }

        return childrenByParentID.mapValues { children in
            children.sorted { timestamp(for: $0) > timestamp(for: $1) }
        }
    }

    /// The nearest non-child ancestor `session` nests under, or nil when the
    /// parent chain leaves the loaded list or degenerates into a cycle — the
    /// child then stays a top-level row rather than vanishing.
    nonisolated private static func attachedAncestorID(
        for session: SessionSummary,
        sessionsByID: [String: SessionSummary]
    ) -> String? {
        guard let sessionID = nonEmpty(session.sessionId) else { return nil }

        var visited: Set<String> = [sessionID]
        var current = session
        while current.isChildSessionRow {
            guard let parentID = nonEmpty(current.parentSessionId),
                  let parent = sessionsByID[parentID],
                  visited.insert(parentID).inserted
            else {
                return nil
            }

            if !parent.isChildSessionRow {
                return parentID
            }

            current = parent
        }

        return nil
    }

    @discardableResult
    func load(modelContext: ModelContext? = nil, animation: Animation? = nil) async -> Bool {
        isLoading = true
        errorMessage = nil
        cacheErrorMessage = nil
        sessionLoadError = nil
        lastError = nil
        defer { isLoading = false }

        do {
            let response = try await client.sessions()
            let visibleSessions = (response.sessions ?? [])
                .filter { $0.archived != true && $0.shouldAppearInSessionList }
            applySessions(visibleSessions, archivedCount: response.archivedCount, animation: animation)
            isViewingCachedData = false

            if let modelContext {
                do {
                    try CacheStore.cacheSessions(visibleSessions, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            sessionLoadError = error
            if CacheFallbackPolicy.shouldUseCache(for: error), let modelContext {
                do {
                    let cachedSessions = try CacheStore.cachedSessions(serverURL: server, in: modelContext)
                        .filter(\.shouldAppearInSessionList)
                    if !cachedSessions.isEmpty {
                        sessions = cachedSessions
                        isViewingCachedData = true
                        errorMessage = nil
                    } else {
                        isViewingCachedData = false
                        errorMessage = error.localizedDescription
                    }
                } catch {
                    cacheErrorMessage = error.localizedDescription
                    isViewingCachedData = false
                    errorMessage = lastError?.localizedDescription
                }
            } else {
                isViewingCachedData = false
                errorMessage = error.localizedDescription
            }

            return false
        }
    }

    func loadActiveProfile() async {
        guard !isLoadingActiveProfile else { return }

        isLoadingActiveProfile = true
        activeProfileErrorMessage = nil
        defer { isLoadingActiveProfile = false }

        do {
            let response = try await client.profiles()
            applyActiveProfile(response)
        } catch {
            guard !isCancellationError(error) else { return }

            activeProfileErrorMessage = error.localizedDescription
        }
    }

    func switchActiveProfile(_ profile: ProfileSummary) async -> Bool {
        guard !isViewingCachedData else {
            activeProfileErrorMessage = String(localized: "Reconnect to the server to change profiles.")
            return false
        }

        guard let profileName = Self.nonEmpty(profile.name) else {
            activeProfileErrorMessage = String(localized: "The server did not provide a profile name.")
            return false
        }

        guard profileName != activeProfileName else {
            return true
        }

        isSwitchingActiveProfile = true
        switchingActiveProfileName = profileName
        activeProfileErrorMessage = nil
        lastError = nil
        defer {
            isSwitchingActiveProfile = false
            switchingActiveProfileName = nil
        }

        do {
            let response = try await client.switchProfile(name: profileName)
            if let error = Self.nonEmpty(response.error) {
                activeProfileErrorMessage = error
                return false
            }

            let resolvedName = Self.nonEmpty(response.active) ?? profileName
            // The switch response has no `single_profile_mode` field; carry the
            // last known value forward so the switcher visibility doesn't flap.
            let profileResponse = ProfilesResponse(
                profiles: response.profiles ?? profileOptions,
                active: resolvedName,
                singleProfileMode: isSingleProfileMode
            )
            applyActiveProfile(
                profileResponse,
                fallbackProfile: profile,
                fallbackDefaultModel: response.defaultModel
            )
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            activeProfileErrorMessage = error.localizedDescription
            return false
        }
    }

    func searchSessions(
        query rawQuery: String,
        content: Bool = true,
        depth: Int = 5,
        debounceNanoseconds: UInt64 = 350_000_000
    ) async {
        let query = Self.normalizedSearchQuery(rawQuery)
        activeRemoteSearchQuery = query
        remoteContentSearchSessionIDs = []
        searchErrorMessage = nil

        guard !query.isEmpty, !isViewingCachedData else {
            isSearchingRemoteSessions = false
            return
        }

        do {
            if debounceNanoseconds > 0 {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            }

            guard !Task.isCancelled, activeRemoteSearchQuery == query else { return }

            isSearchingRemoteSessions = true
            let response = try await client.searchSessions(query: query, content: content, depth: depth)

            guard !Task.isCancelled, activeRemoteSearchQuery == query else { return }

            remoteContentSearchSessionIDs = contentMatchIDs(from: response.sessions ?? [])
            isSearchingRemoteSessions = false
        } catch {
            guard activeRemoteSearchQuery == query else { return }

            isSearchingRemoteSessions = false
            guard !isCancellationError(error) else { return }

            remoteContentSearchSessionIDs = []
            searchErrorMessage = error.localizedDescription
            lastError = error
        }
    }

    func clearSearchResults() {
        activeRemoteSearchQuery = nil
        remoteContentSearchSessionIDs = []
        searchErrorMessage = nil
        isSearchingRemoteSessions = false
    }

    private var loadFailureRefreshResult: ActiveSessionStateRefreshResult {
        lastError == nil ? .unchanged : .failed
    }

    @discardableResult
    func refreshActiveSessionStatesIfNeeded(
        streamIDs rawStreamIDs: [String],
        modelContext: ModelContext? = nil
    ) async -> ActiveSessionStateRefreshResult {
        guard !isViewingCachedData, !isLoading else { return .unchanged }

        let streamIDs = Self.normalizedStreamIDs(rawStreamIDs)
        guard !streamIDs.isEmpty else {
            return await load(modelContext: modelContext) ? .reloaded : loadFailureRefreshResult
        }

        for streamID in streamIDs {
            do {
                let response = try await client.chatStreamStatus(streamID: streamID)
                guard response.active == false else { continue }
                return await load(modelContext: modelContext) ? .reloaded : loadFailureRefreshResult
            } catch {
                guard !isCancellationError(error) else { return .unchanged }
                if case APIError.unauthorized = error {
                    lastError = error
                    return .failed
                }
                continue
            }
        }

        return .unchanged
    }

    func loadSessionForDeepLink(id rawSessionID: String, modelContext: ModelContext? = nil) async -> SessionSummary? {
        let sessionID = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return nil }

        if let loadedSession = sessions.first(where: { $0.sessionId == sessionID }) {
            return loadedSession
        }

        actionErrorMessage = nil
        lastError = nil

        if let modelContext {
            do {
                if let cachedSession = try CacheStore.cachedSessions(serverURL: server, in: modelContext)
                    .first(where: { $0.sessionId == sessionID }) {
                    return cachedSession
                }
            } catch {
                cacheErrorMessage = error.localizedDescription
            }
        }

        do {
            let response = try await client.session(id: sessionID, includeMessages: false, messageLimit: nil)
            guard let sessionDetail = response.session else {
                actionErrorMessage = String(localized: "The server did not return the linked session.")
                return nil
            }

            let session = SessionSummary(from: sessionDetail)
            if session.archived != true,
               session.shouldAppearInSessionList,
               !sessions.contains(where: { $0.sessionId == session.sessionId }) {
                sessions.insert(session, at: 0)
            }

            if let modelContext, session.shouldAppearInSessionList {
                do {
                    try CacheStore.cacheSession(session, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            return session
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func setPinned(
        _ pinned: Bool,
        for session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard beginSessionMutation(sessionId) else { return false }
        defer { endSessionMutation(sessionId) }

        return await mutate(modelContext: modelContext, animation: animation) {
            try await sessionMutator.setPinned(pinned, sessionID: sessionId)
        }
    }

    func archive(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard beginSessionMutation(sessionId) else { return false }
        defer { endSessionMutation(sessionId) }

        return await mutate(modelContext: modelContext, animation: animation) {
            try await sessionMutator.archive(sessionID: sessionId)
        }
    }

    func delete(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard beginSessionMutation(sessionId) else { return false }
        defer { endSessionMutation(sessionId) }

        return await mutate(modelContext: modelContext, animation: animation) {
            try await sessionMutator.delete(sessionID: sessionId)
        }
    }

    func isMutating(_ session: SessionSummary) -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else { return false }
        return mutatingSessionIDs.contains(sessionId)
    }

    func rename(_ session: SessionSummary, to rawTitle: String, modelContext: ModelContext? = nil) async -> Bool {
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to rename a session.")
            return false
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard let title = Self.nonEmpty(rawTitle) else {
            actionErrorMessage = String(localized: "Enter a session title.")
            return false
        }

        isRenamingSession = true
        actionErrorMessage = nil
        lastError = nil
        defer { isRenamingSession = false }

        do {
            let response = try await sessionMutator.rename(sessionID: sessionId, title: title)
            if let error = Self.nonEmpty(response.error) {
                actionErrorMessage = error
                return false
            }

            let resolvedTitle = Self.nonEmpty(response.session?.title) ?? title
            let baseSession = sessions.first(where: { $0.sessionId == sessionId }) ?? session
            let updatedSession = baseSession.replacingTitle(with: resolvedTitle)
            if let existingIndex = sessions.firstIndex(where: { $0.sessionId == sessionId }) {
                sessions[existingIndex] = updatedSession
            }

            if let modelContext {
                do {
                    try CacheStore.cacheSession(updatedSession, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func duplicate(_ session: SessionSummary, modelContext: ModelContext? = nil) async -> SessionSummary? {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        guard beginSessionMutation(sessionId) else { return nil }
        defer { endSessionMutation(sessionId) }

        actionErrorMessage = nil
        lastError = nil

        do {
            let result = try await sessionMutator.duplicate(
                sessionID: sessionId,
                title: duplicateTitle(for: session)
            )

            guard let duplicatedSession = result.session else {
                actionErrorMessage = result.errorMessage
                return nil
            }

            await load(modelContext: modelContext)
            if !sessions.contains(where: { $0.sessionId == duplicatedSession.sessionId }) {
                sessions.insert(duplicatedSession, at: 0)

                if let modelContext {
                    do {
                        try CacheStore.cacheSessions(sessions, serverURL: server, in: modelContext)
                    } catch {
                        cacheErrorMessage = error.localizedDescription
                    }
                }
            }
            return duplicatedSession
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Downloads the session transcript (`GET /api/session/export`) and writes
    /// it to a unique temp directory so the share sheet can offer it as a file
    /// with a real filename. Returns the file URL, or nil after surfacing the
    /// failure through the standard action-error alert. The caller owns
    /// cleanup of the returned file's parent directory after sharing.
    func export(_ session: SessionSummary, format: SessionExportFormat) async -> URL? {
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to export a session.")
            return nil
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        // Reuses the per-session mutation gate: it disables the row's other
        // actions while the download runs (the "progress state") and blocks a
        // double-tap from firing two exports.
        guard beginSessionMutation(sessionId) else { return nil }
        defer { endSessionMutation(sessionId) }

        actionErrorMessage = nil
        lastError = nil

        do {
            let file = try await client.exportSession(
                id: sessionId,
                format: format,
                fallbackTitle: session.title
            )

            let directory = Self.exportsRootDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let fileURL = directory.appendingPathComponent(file.filename)
            try file.data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            guard !isCancellationError(error) else { return nil }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func loadProjects() async {
        isLoadingProjects = true
        actionErrorMessage = nil
        lastError = nil
        defer { isLoadingProjects = false }

        do {
            let response = try await client.projects()
            projects = response.projects ?? []
        } catch {
            guard !isCancellationError(error) else { return }

            lastError = error
            actionErrorMessage = error.localizedDescription
        }
    }

    func move(_ session: SessionSummary, to projectID: String?, modelContext: ModelContext? = nil) async {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return
        }

        guard beginSessionMutation(sessionId) else { return }
        defer { endSessionMutation(sessionId) }

        isMovingSession = true
        defer { isMovingSession = false }

        _ = await mutate(modelContext: modelContext) {
            try await sessionMutator.move(sessionID: sessionId, to: projectID)
        }
    }

    func createProject(
        named rawName: String,
        color: String,
        moving session: SessionSummary,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        guard let sessionId = session.sessionId else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isCreatingProject = true
        isMovingSession = true
        defer {
            isCreatingProject = false
            isMovingSession = false
        }

        do {
            let createResponse = try await client.createProject(name: name, color: color)
            guard let project = createResponse.project else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project.")
                return false
            }

            guard let projectID = project.projectId, !projectID.isEmpty else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project ID.")
                return false
            }

            upsertProject(project)
            try await sessionMutator.move(sessionID: sessionId, to: projectID)
            await load(modelContext: modelContext)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Creates a new project without moving any session into it.
    ///
    /// Mirrors ``createProject(named:color:moving:modelContext:)`` but skips the
    /// `sessionMutator.move(...)` step, so the Projects sidebar's standalone
    /// "Add project" button can make an empty, unassigned project.
    func createEmptyProject(
        named rawName: String,
        color: String,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isCreatingProject = true
        defer { isCreatingProject = false }

        do {
            let createResponse = try await client.createProject(name: name, color: color)
            guard let project = createResponse.project else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project.")
                return false
            }

            guard let projectID = project.projectId, !projectID.isEmpty else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project ID.")
                return false
            }

            upsertProject(project)
            await load(modelContext: modelContext)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func delete(_ project: ProjectSummary, modelContext: ModelContext? = nil) async -> Bool {
        guard let projectID = project.projectId, !projectID.isEmpty else {
            actionErrorMessage = String(localized: "The server did not provide a project ID.")
            return false
        }

        isDeletingProject = true
        actionErrorMessage = nil
        lastError = nil
        defer { isDeletingProject = false }

        do {
            _ = try await client.deleteProject(id: projectID)
            projects.removeAll { $0.projectId == projectID }
            await load(modelContext: modelContext)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func rename(_ project: ProjectSummary, named rawName: String, color: String?) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        guard let projectID = project.projectId, !projectID.isEmpty else {
            actionErrorMessage = String(localized: "The server did not provide a project ID.")
            return false
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isRenamingProject = true
        defer { isRenamingProject = false }

        do {
            let response = try await client.renameProject(id: projectID, name: name, color: color)
            guard let renamedProject = response.project else {
                actionErrorMessage = response.error ?? String(localized: "The server did not return the renamed project.")
                return false
            }

            guard renamedProject.projectId?.isEmpty == false else {
                actionErrorMessage = response.error ?? String(localized: "The server did not return the renamed project ID.")
                return false
            }

            upsertProject(renamedProject)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Creates a new session. `profile` pins it to a specific server profile (the "New Chat
    /// in <Profile>" App Intent, #339); nil keeps the legacy behavior of letting the server
    /// use its active profile (the "+" button / plain New Chat).
    func createSession(modelContext: ModelContext? = nil, profile: String? = nil) async -> SessionSummary? {
        isCreatingSession = true
        actionErrorMessage = nil
        lastError = nil
        defer { isCreatingSession = false }

        do {
            let workspaces = try await client.workspaces()
            let workspace = workspaces.last ?? workspaces.workspaces?.compactMap(\.path).first
            let response = try await client.createSession(
                workspace: workspace,
                model: nil,
                modelProvider: nil,
                profile: Self.nonEmpty(profile)
            )

            guard let sessionDetail = response.session else {
                actionErrorMessage = String(localized: "The server did not return the new session.")
                return nil
            }

            let newSession = SessionSummary(from: sessionDetail)
            guard newSession.sessionId?.isEmpty == false else {
                actionErrorMessage = String(localized: "The server did not return the new session ID.")
                return nil
            }

            if newSession.shouldAppearInSessionList {
                if let existingIndex = sessions.firstIndex(where: { $0.sessionId == newSession.sessionId }) {
                    sessions[existingIndex] = newSession
                } else {
                    sessions.insert(newSession, at: 0)
                }

                if let modelContext {
                    do {
                        try CacheStore.cacheSession(newSession, serverURL: server, in: modelContext)
                    } catch {
                        cacheErrorMessage = error.localizedDescription
                    }
                }
            }

            return newSession
        } catch {
            guard !isCancellationError(error) else { return nil }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    /// Drops any empty Untitled placeholders still held in memory. Used when
    /// returning from the pending new-chat flow so stale rows cannot flash during
    /// the navigation pop animation.
    func removeEmptySidebarPlaceholders() {
        let filtered = sessions.filter(\.shouldAppearInSessionList)
        guard filtered.count != sessions.count else { return }
        sessions = filtered
    }

    private static func normalizedSearchQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func activeStreamIDs(in sessions: [SessionSummary]) -> [String] {
        normalizedStreamIDs(sessions.compactMap(\.activeStreamId))
    }

    private static func normalizedStreamIDs(_ rawStreamIDs: [String]) -> [String] {
        Array(Set(rawStreamIDs.compactMap(nonEmpty))).sorted()
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sortedSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.sorted { left, right in
            if (left.pinned == true) != (right.pinned == true) {
                return left.pinned == true
            }

            return timestamp(for: left) > timestamp(for: right)
        }
    }

    nonisolated private static func timestamp(for session: SessionSummary) -> Double {
        session.lastMessageAt ?? session.updatedAt ?? session.createdAt ?? 0
    }

    private static func date(for session: SessionSummary) -> Date? {
        let value = timestamp(for: session)
        guard value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private static func searchableText(for session: SessionSummary) -> String {
        [
            session.title,
            session.workspace,
            session.model,
            session.modelProvider,
            session.profile,
            session.sourceLabel
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    }

    /// `archivedCount` is applied inside the same transaction as the rows so the
    /// bottom Archived entry inserts/removes with the list mutation animation.
    private func applySessions(
        _ newSessions: [SessionSummary],
        archivedCount newArchivedCount: Int?,
        animation: Animation?
    ) {
        guard let animation else {
            sessions = newSessions
            archivedCount = newArchivedCount
            return
        }

        withAnimation(animation) {
            sessions = newSessions
            archivedCount = newArchivedCount
        }
    }

    private func contentMatchIDs(from sessions: [SessionSummary]) -> [String] {
        let locallyVisibleSessionIDs = Set(self.sessions.compactMap { session -> String? in
            guard session.archived != true, let sessionID = session.sessionId, !sessionID.isEmpty else {
                return nil
            }

            return sessionID
        })
        var seenSessionIDs = Set<String>()

        return sessions.compactMap { session in
            guard session.matchType?.lowercased() == "content",
                  let sessionID = session.sessionId,
                  locallyVisibleSessionIDs.contains(sessionID),
                  !seenSessionIDs.contains(sessionID)
            else {
                return nil
            }

            seenSessionIDs.insert(sessionID)
            return sessionID
        }
    }

    private func timestamp(for session: SessionSummary) -> Double {
        Self.timestamp(for: session)
    }

    private func duplicateTitle(for session: SessionSummary) -> String {
        let baseTitle = Self.nonEmpty(session.title) ?? String(localized: "Untitled Session")
        return String(localized: "\(baseTitle) (copy)")
    }

    private func beginSessionMutation(_ sessionId: String) -> Bool {
        mutatingSessionIDs.insert(sessionId).inserted
    }

    private func endSessionMutation(_ sessionId: String) {
        mutatingSessionIDs.remove(sessionId)
    }

    private func upsertProject(_ project: ProjectSummary) {
        guard let projectID = project.projectId, !projectID.isEmpty else { return }

        if let existingIndex = projects.firstIndex(where: { $0.projectId == projectID }) {
            projects[existingIndex] = project
        } else {
            projects.append(project)
        }
    }

    private func applyActiveProfile(
        _ response: ProfilesResponse,
        fallbackProfile: ProfileSummary? = nil,
        fallbackDefaultModel: String? = nil
    ) {
        profileOptions = response.profiles ?? profileOptions

        // Tolerant: only a present field moves the flag, so an older server
        // (or the carried-forward switch-response value) keeps today's behavior.
        if let singleProfileMode = response.singleProfileMode {
            isSingleProfileMode = singleProfileMode
        }

        // Keep the App Intents profile cache fresh so the "New Chat in <Profile>" picker
        // (#339) stays populated when the Shortcuts app resolves it in the background, where
        // a live, authenticated fetch may not be possible, then nudge the system to (re-)index
        // the parameterized App Shortcut (iOS only indexes it once its suggested values exist).
        // A nil `profiles` (field absent/undecoded) is left untouched — tolerant decoding — but
        // an explicit empty list is forwarded so `save([])` can clear a stale picker if the
        // server ever reports none.
        if let profiles = response.profiles {
            let changed = ProfileEntityCache.shared.save(profiles)
            ProfileEntityProvider.refreshAppShortcuts(changed: changed)
        }

        let profileName = response.effectiveDefaultProfileName
        let profile = response.profile(matching: profileName) ?? fallbackProfile

        activeProfileName = profileName
        activeProfileDisplayName = response.displayName(for: profileName)
            ?? profile?.displayName
        activeProfileModel = Self.nonEmpty(profile?.model) ?? Self.nonEmpty(fallbackDefaultModel)
        activeProfileProvider = Self.nonEmpty(profile?.provider)
    }

    private func mutate(
        modelContext: ModelContext? = nil,
        animation: Animation? = nil,
        _ operation: () async throws -> Void
    ) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        do {
            try await operation()
            return await load(modelContext: modelContext, animation: animation)
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let underlying: Error
        if case APIError.network(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }

        guard let urlError = underlying as? URLError else { return false }
        return urlError.code == .cancelled
    }

}
