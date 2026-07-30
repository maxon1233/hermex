import SwiftUI
import UIKit

struct SessionListRowActions {
    let retryLoad: () -> Void
    let open: (SessionSummary) -> Void
    let togglePinned: (SessionSummary) -> Void
    let archive: (SessionSummary) -> Void
    let delete: (SessionSummary) -> Void
    let rename: (SessionSummary) -> Void
    let duplicate: (SessionSummary) -> Void
    let move: (SessionSummary, String?) -> Void
    let createProject: (SessionSummary) -> Void
    let refreshProjects: () -> Void
    let export: (SessionSummary, SessionExportFormat) -> Void
}

enum SessionRowActionPolicy {
    static func offersMutationActions(for session: SessionSummary) -> Bool {
        !session.isSessionReadOnly
    }

    static func canExport(_ session: SessionSummary, isViewingCachedData: Bool) -> Bool {
        !isViewingCachedData && hasServerSessionID(session)
    }

    static func deepLinkURL(
        for session: SessionSummary,
        isViewingCachedData: Bool,
        isMutating: Bool
    ) -> URL? {
        guard !isMutating,
              canExport(session, isViewingCachedData: isViewingCachedData),
              let sessionID = session.sessionId
        else {
            return nil
        }

        return HermesDeepLink.sessionURL(sessionID: sessionID)
    }
}

enum SessionListMotion {
    static func disclosureAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.28, extraBounce: 0)
    }

    static func searchChromeAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.24, extraBounce: 0)
    }

    static func searchFocusAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    static func pressAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.18, extraBounce: 0)
    }

    static func sessionMutationAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0)
    }

    static func sessionRowTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    static func disclosureContentTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}

struct SessionSidebarUtilityRows: View {
    // Vertical gap between every utility row, matching the navigation rows so the
    // headers and subrows share one consistent rhythm now that each is its own row.
    private static let rowSpacing: CGFloat = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let viewModel: SessionListViewModel
    let topPadding: CGFloat
    @Binding var profilesAreExpanded: Bool

    let openDestination: (SessionListUtilityDestination) -> Void
    let switchActiveProfile: (ProfileSummary) -> Void

    // Each disclosure subrow is emitted as its own List row (like the session
    // rows below it). List does not animate height/transition changes inside a
    // single row, so packing the subrows into one row made expand/collapse snap
    // instantly. As real rows, List animates them folding in/out; the fold is
    // driven by a value-based .animation on the List in SessionListView, which
    // works even though the disclosure booleans are @AppStorage-backed.
    var body: some View {
        utilityLinks
            .padding(.top, topPadding)
            .sessionsScreenListRow()

        // In single-profile mode the server rejects switching, so the whole
        // "Active Profile" disclosure would only no-op or error — hide it (#24).
        if !viewModel.isSingleProfileMode {
            activeProfileHeader
                .padding(.top, Self.rowSpacing)
                .sessionsScreenListRow()

            if profilesAreExpanded {
                activeProfileOptionRows
            }
        }
    }

    private func disclosureSubrow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 24)
            .padding(.top, Self.rowSpacing)
            .sessionsScreenListRow()
            .transition(SessionListMotion.disclosureContentTransition(reduceMotion: reduceMotion))
    }

    private var utilityLinks: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            SidebarNavButton(title: String(localized: "Tasks"), assetImage: "LucideCalendarClock") {
                openDestination(.tasks)
            }

            SidebarNavButton(title: String(localized: "Skills"), assetImage: "LucideHammer") {
                openDestination(.skills)
            }

            SidebarNavButton(title: String(localized: "Memory"), assetImage: "LucideBrain") {
                openDestination(.memory)
            }

            SidebarNavButton(title: String(localized: "Insights"), assetImage: "LucideChartColumnIncreasing") {
                openDestination(.insights)
            }
        }
        .padding(.horizontal, 24)
    }

    private var activeProfileHeader: some View {
        SidebarDisclosureButton(
            title: String(localized: "Active Profile"),
            assetImage: "LucideUserRoundCog",
            isExpanded: profilesAreExpanded,
            tint: viewModel.activeProfileErrorMessage == nil ? .primary : .orange
        ) {
            profilesAreExpanded.toggle()
        } accessory: {
            if viewModel.isLoadingActiveProfile {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .accessibilityLabel(profilesAreExpanded ? "Collapse active profile picker" : "Expand active profile picker")
    }

    @ViewBuilder
    private var activeProfileOptionRows: some View {
        if viewModel.isLoadingActiveProfile && viewModel.profileOptions.isEmpty {
            disclosureSubrow {
                CompactStatusRow(title: String(localized: "Loading profiles..."), systemImage: "person.crop.circle")
            }
        } else if viewModel.profileOptions.isEmpty {
            disclosureSubrow {
                CompactStatusRow(
                    title: viewModel.activeProfileErrorMessage == nil ? String(localized: "No profiles") : String(localized: "Could not load profiles"),
                    systemImage: "exclamationmark.triangle"
                )
            }
        } else {
            ForEach(viewModel.profileOptions) { profile in
                let profileIsActive = isActiveProfile(profile)

                disclosureSubrow {
                    ActiveProfilePickerRow(
                        profile: profile,
                        isSelected: profileIsActive,
                        isSwitching: viewModel.isSwitchingActiveProfile
                            && viewModel.switchingActiveProfileName == profile.normalizedName
                    ) {
                        guard !profileIsActive else { return }
                        switchActiveProfile(profile)
                    }
                    .disabled(
                        viewModel.isViewingCachedData
                            || viewModel.isSwitchingActiveProfile
                            || profile.normalizedName == nil
                    )
                }
            }
        }
    }

    private func isActiveProfile(_ profile: ProfileSummary) -> Bool {
        guard let profileName = profile.normalizedName else { return false }

        if let activeProfileName = viewModel.activeProfileName {
            return profileName == activeProfileName
        }

        return profile.isActive == true
    }
}

/// Vertical, collapsible successor of the desktop's horizontal project bar
/// (`.project-bar` in `static/sessions.js`): a "Projects" header row that
/// shows the active scope while folded, and — unfolded — one row per scope
/// (All / Unassigned / each project) with its color, live row count, and a
/// selection checkmark, plus the add-project button beside the header.
/// Vertical because sideways chip scrolling hides options on a phone;
/// selecting a scope folds the picker again to give the list back its space.
struct SessionProjectScopeDisclosure: View {
    private static let rowSpacing: CGFloat = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let projects: [ProjectSummary]
    let activeFilter: SessionProjectFilter
    /// The Unassigned row only renders while unprojected sessions exist —
    /// desktop parity keeps the picker uncluttered once everything is
    /// organized.
    let showsUnassignedRow: Bool
    let isViewingCachedData: Bool
    let isRenamingProject: Bool
    let isDeletingProject: Bool
    let sessionCount: (SessionProjectFilter) -> Int
    @Binding var isExpanded: Bool
    let select: (SessionProjectFilter) -> Void
    let renameProject: (ProjectSummary) -> Void
    let deleteProject: (ProjectSummary) -> Void
    let createProject: () -> Void

    var body: some View {
        headerRow
            .sessionsScreenListRow()

        if isExpanded {
            scopeSubrow {
                scopeRow(
                    title: String(localized: "All"),
                    accessibilityLabel: String(localized: "All sessions"),
                    icon: .system("rectangle.stack"),
                    filter: .all
                )
            }

            if showsUnassignedRow {
                scopeSubrow {
                    scopeRow(
                        title: String(localized: "Unassigned"),
                        accessibilityLabel: String(localized: "Unassigned sessions"),
                        icon: .system("tray"),
                        filter: .unassigned
                    )
                }
            }

            ForEach(projects) { project in
                scopeSubrow {
                    projectRow(for: project)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            SidebarDisclosureButton(
                title: String(localized: "Projects"),
                assetImage: "LucideFolder",
                isExpanded: isExpanded
            ) {
                isExpanded.toggle()
            } accessory: {
                // While folded, the header itself answers "what am I looking
                // at" — the active scope stays visible without unfolding.
                if !isExpanded {
                    activeScopeSummary
                }
            }
            .accessibilityLabel(isExpanded ? "Collapse project scopes" : "Expand project scopes")
            .accessibilityValue(activeScopeName)

            // Sibling of the disclosure button (not nested in its label) so
            // VoiceOver exposes it as its own focusable control.
            if isExpanded {
                addProjectButton
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, Self.rowSpacing)
    }

    private var activeScopeSummary: some View {
        HStack(spacing: 6) {
            if case .project(let projectID) = activeFilter,
               let project = project(withID: projectID) {
                Circle()
                    .fill(ProjectSummary.displayColor(
                        colorHex: project.color,
                        fallbackSeed: project.projectId ?? projectDisplayName(project)
                    ))
                    .frame(width: 8, height: 8)
            }

            Text(activeScopeName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.thinMaterial, in: Capsule())
        .accessibilityHidden(true)
    }

    private var addProjectButton: some View {
        HapticButton(action: createProject) {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isViewingCachedData)
        .accessibilityLabel("Add project")
        .accessibilityHint("Creates a new empty project.")
    }

    private func scopeSubrow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 24)
            .padding(.top, Self.rowSpacing)
            .sessionsScreenListRow()
            .transition(SessionListMotion.disclosureContentTransition(reduceMotion: reduceMotion))
    }

    private enum ScopeRowIcon {
        case system(String)
        case folder(Color)
    }

    @ViewBuilder
    private func iconView(_ icon: ScopeRowIcon) -> some View {
        switch icon {
        case .folder(let tint):
            SidebarUtilityIcon(assetImage: "LucideFolder", tint: tint)
        case .system(let name):
            Image(systemName: name)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
        }
    }

    private func scopeRow(
        title: String,
        accessibilityLabel: String,
        icon: ScopeRowIcon,
        filter: SessionProjectFilter
    ) -> some View {
        let isSelected = activeFilter == filter
        let count = sessionCount(filter)

        return Button {
            select(filter)
        } label: {
            HStack(spacing: 18) {
                iconView(icon)

                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if isSelected {
                    SidebarSelectedSubrowIndicator()
                }
            }
            .frame(minHeight: 44)
            .sidebarSubrowSelectionStyle(isSelected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(scopeAccessibilityValue(count: count, isSelected: isSelected))
        .accessibilityHint(isSelected ? "Already showing this scope." : "Shows this scope's sessions.")
    }

    private func projectRow(for project: ProjectSummary) -> some View {
        let isSelected = isActive(project)
        let count = project.projectId.map { sessionCount(.project($0)) } ?? 0

        return HStack(spacing: 8) {
            Button {
                guard let projectID = project.projectId else { return }
                select(.project(projectID))
            } label: {
                HStack(spacing: 18) {
                    iconView(.folder(ProjectSummary.displayColor(
                        colorHex: project.color,
                        fallbackSeed: project.projectId ?? projectDisplayName(project)
                    )))

                    Text(projectDisplayName(project))
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if count > 0 {
                        Text("\(count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    if isSelected {
                        SidebarSelectedSubrowIndicator()
                    }
                }
                .padding(.leading, 18)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Project \(projectDisplayName(project))"))
            .accessibilityValue(scopeAccessibilityValue(count: count, isSelected: isSelected))
            .accessibilityHint(isSelected ? "Already showing this project." : "Shows this project's sessions.")

            Menu {
                Button {
                    renameProject(project)
                } label: {
                    Label("Rename Project", systemImage: "pencil")
                }
                .disabled(projectActionsAreDisabled(project))

                Button(role: .destructive) {
                    deleteProject(project)
                } label: {
                    Label("Delete Project", systemImage: "trash")
                }
                .disabled(projectActionsAreDisabled(project))
            } label: {
                Label(
                    String(localized: "Project actions for \(projectDisplayName(project))"),
                    systemImage: "ellipsis"
                )
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Project actions for \(projectDisplayName(project))"))
            .accessibilityHint("Shows rename and delete actions for this project.")
        }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.20), lineWidth: 1)
                    }
            }
        }
    }

    private var activeScopeName: String {
        switch activeFilter {
        case .all:
            return String(localized: "All")
        case .unassigned:
            return String(localized: "Unassigned")
        case .project(let projectID):
            guard let project = project(withID: projectID) else {
                return String(localized: "Project")
            }
            return projectDisplayName(project)
        }
    }

    private func scopeAccessibilityValue(count: Int, isSelected: Bool) -> String {
        let countTitle = String(localized: "\(count) sessions")
        return isSelected ? String(localized: "Selected, \(countTitle)") : countTitle
    }

    private func project(withID projectID: String) -> ProjectSummary? {
        projects.first { $0.projectId == projectID }
    }

    private func isActive(_ project: ProjectSummary) -> Bool {
        guard let projectID = project.projectId else { return false }
        return activeFilter == .project(projectID)
    }

    private func projectDisplayName(_ project: ProjectSummary) -> String {
        let name = project.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else {
            return String(localized: "Untitled Project")
        }
        return name
    }

    private func projectActionsAreDisabled(_ project: ProjectSummary) -> Bool {
        isViewingCachedData
            || isRenamingProject
            || isDeletingProject
            || project.projectId == nil
    }
}

struct SessionListRowsSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let viewModel: SessionListViewModel

    let sessions: [SessionSummary]
    let emptyTitle: String
    let emptyDescription: String?
    let isSearchActive: Bool
    let showsMessageCount: Bool
    let showsWorkspace: Bool
    let selectedSessionID: String?
    let actions: SessionListRowActions
    /// Child sessions nested beneath each top-level row, keyed by parent
    /// session ID (`SessionListViewModel.childSessionsByParentID`).
    var childSessionsByParentID: [String: [SessionSummary]] = [:]
    var expandedChildSessionParentIDs: Set<String> = []
    var onToggleChildSessions: ((SessionSummary) -> Void)? = nil

    var body: some View {
        sessionsHeaderRow
            .padding(.top, isSearchActive ? 16 : 28)
            .sessionsScreenListRow()

        if viewModel.isLoading && viewModel.sessions.isEmpty {
            sessionLoadingSkeletonRows
        } else if let errorMessage = viewModel.errorMessage, viewModel.sessions.isEmpty {
            sessionsErrorRow(message: errorMessage)
                .sessionsScreenListRow()
        } else if sessions.isEmpty {
            SessionListStatusRow(
                title: emptyTitle,
                description: emptyDescription,
                systemImage: "bubble.left"
            )
                .padding(.horizontal, 24)
                .sessionsScreenListRow()
        } else {
            ForEach(Array(groupedSections.enumerated()), id: \.element.id) { index, section in
                sessionGroupHeader(section.title, isFirst: index == 0)

                ForEach(section.sessions) { session in
                    let nestedChildSessions = childSessions(for: session)
                    let nestedChildrenAreExpanded = childSessionsAreExpanded(
                        for: session,
                        childSessions: nestedChildSessions
                    )

                    SessionInteractiveRow(
                        viewModel: viewModel,
                        session: session,
                        showsMessageCount: showsMessageCount,
                        showsWorkspace: showsWorkspace,
                        selectedSessionID: selectedSessionID,
                        actions: actions,
                        childSessionCount: nestedChildSessions.count,
                        childSessionsAreExpanded: nestedChildrenAreExpanded,
                        hasStreamingChildSession: nestedChildSessions.contains(
                            where: SessionRowView.isActiveStreaming
                        ),
                        onToggleChildSessions: onToggleChildSessions.map { toggle in
                            { toggle(session) }
                        }
                    )

                    if nestedChildrenAreExpanded {
                        ForEach(nestedChildSessions) { childSession in
                            SessionChildInteractiveRow(
                                viewModel: viewModel,
                                session: childSession,
                                selectedSessionID: selectedSessionID,
                                actions: actions
                            )
                            .transition(
                                SessionListMotion.disclosureContentTransition(reduceMotion: reduceMotion)
                            )
                        }
                    }
                }
            }
        }
    }

    private var groupedSections: [SessionListSection] {
        SessionListViewModel.makeSections(for: sessions)
    }

    private func childSessions(for session: SessionSummary) -> [SessionSummary] {
        guard let sessionID = session.sessionId else { return [] }
        return childSessionsByParentID[sessionID] ?? []
    }

    /// Search shows every matched parent's children unfolded, mirroring the
    /// desktop sidebar, so a child hit is visible without an extra tap.
    private func childSessionsAreExpanded(
        for session: SessionSummary,
        childSessions: [SessionSummary]
    ) -> Bool {
        guard !childSessions.isEmpty else { return false }
        if isSearchActive { return true }
        guard let sessionID = session.sessionId else { return false }
        return expandedChildSessionParentIDs.contains(sessionID)
    }

    private func sessionGroupHeader(_ title: String, isFirst: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.top, isFirst ? 0 : 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .sessionsScreenListRow()
    }

    private var sessionsHeaderRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if !isSearchActive {
                    Text("Sessions")
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                }

                Spacer()

                if viewModel.isSearchingRemoteSessions {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Searching sessions")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var sessionLoadingSkeletonRows: some View {
        ForEach(Array(SessionRowSkeletonConfiguration.loadingRows.enumerated()), id: \.element.id) { index, row in
            SessionRowSkeletonView(
                configuration: row,
                showsMessageCount: showsMessageCount,
                showsWorkspace: showsWorkspace
            )
            .sessionsScreenListRow(insets: EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading sessions")
            .accessibilityHidden(index > 0)
        }
        .allowsHitTesting(false)
    }

    private func sessionsErrorRow(message errorMessage: String) -> some View {
        let content = sessionsErrorContent(fallbackMessage: errorMessage)

        return VStack(alignment: .leading, spacing: 10) {
            SessionListStatusRow(
                title: content.title,
                description: content.description,
                systemImage: "exclamationmark.triangle",
                descriptionLineLimit: 3
            )

            Button("Retry", action: actions.retryLoad)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityLabel("Retry loading sessions")
                .accessibilityHint("Attempts to reconnect to the server and reload sessions.")
        }
        .padding(.horizontal, 24)
    }

    private func sessionsErrorContent(fallbackMessage: String) -> (title: String, description: String) {
        if let sessionLoadError = viewModel.sessionLoadError,
           CacheFallbackPolicy.shouldUseCache(for: sessionLoadError) {
            return (
                String(localized: "Cannot reach server"),
                String(localized: "Check that your Mac is awake and cloudflared is running.")
            )
        }

        return (String(localized: "Could not load sessions"), fallbackMessage)
    }

}

struct SessionInteractiveRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let viewModel: SessionListViewModel
    let session: SessionSummary
    let showsMessageCount: Bool
    let showsWorkspace: Bool
    let selectedSessionID: String?
    let actions: SessionListRowActions
    var childSessionCount = 0
    var childSessionsAreExpanded = false
    var hasStreamingChildSession = false
    var onToggleChildSessions: (() -> Void)? = nil

    var body: some View {
        Button {
            actions.open(session)
        } label: {
            SessionRowView(
                session: session,
                showsMessageCount: showsMessageCount,
                showsWorkspace: showsWorkspace,
                isViewingCachedData: viewModel.isViewingCachedData,
                childSessionCount: childSessionCount,
                childSessionsAreExpanded: childSessionsAreExpanded,
                hasStreamingChildSession: hasStreamingChildSession,
                onToggleChildSessions: onToggleChildSessions
            )
        }
        .buttonStyle(.plain)
        .id(session.id)
        .background(
            session.sessionId == selectedSessionID
                ? Color.accentColor.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .transition(SessionListMotion.sessionRowTransition(reduceMotion: reduceMotion))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            sessionLeadingSwipeActions(for: session)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            sessionTrailingSwipeActions(for: session)
        }
        .contextMenu {
            SessionRowContextMenu(
                session: session,
                projects: viewModel.projects,
                isViewingCachedData: viewModel.isViewingCachedData,
                isRenamingSession: viewModel.isRenamingSession,
                isCreatingProject: viewModel.isCreatingProject,
                isMovingSession: viewModel.isMovingSession,
                isLoadingProjects: viewModel.isLoadingProjects,
                isMutating: viewModel.isMutating(session),
                actions: actions
            )
        }
        // The row collapses to a single VoiceOver element, so the nested chip
        // button is unreachable there; expose the fold as a named action.
        .modifier(ChildSessionsToggleAccessibilityAction(
            childSessionsAreExpanded: childSessionsAreExpanded,
            onToggleChildSessions: childSessionCount > 0 ? onToggleChildSessions : nil
        ))
        .sessionsScreenListRow(insets: EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
    }

    @ViewBuilder
    private func sessionLeadingSwipeActions(for session: SessionSummary) -> some View {
        if canShowSessionMutationActions(for: session) {
            Button {
                actions.togglePinned(session)
            } label: {
                Label(session.pinned == true ? "Unpin" : "Pin", systemImage: "pin")
            }
            .disabled(viewModel.isMutating(session))
            .tint(.accentColor)
        }
    }

    @ViewBuilder
    private func sessionTrailingSwipeActions(for session: SessionSummary) -> some View {
        if canShowSessionMutationActions(for: session) {
            Button {
                actions.archive(session)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(viewModel.isMutating(session))
            .tint(.orange)

            Button {
                actions.delete(session)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(viewModel.isMutating(session))
            .tint(.red)
        }
    }

    private func canShowSessionMutationActions(for session: SessionSummary) -> Bool {
        SessionRowActionPolicy.offersMutationActions(for: session)
            && !viewModel.isViewingCachedData
            && hasServerSessionID(session)
    }
}

/// Applies the "expand/collapse children" custom VoiceOver action only when a
/// toggle is available — an unconditional `accessibilityAction` would announce
/// a dead action on childless rows.
private struct ChildSessionsToggleAccessibilityAction: ViewModifier {
    let childSessionsAreExpanded: Bool
    let onToggleChildSessions: (() -> Void)?

    func body(content: Content) -> some View {
        if let onToggleChildSessions {
            content.accessibilityAction(
                named: childSessionsAreExpanded
                    ? String(localized: "Collapse child sessions")
                    : String(localized: "Expand child sessions")
            ) {
                onToggleChildSessions()
            }
        } else {
            content
        }
    }
}

/// Nested child-session row: opens the child on tap and offers the shared
/// context menu. Delegated children are runner-owned and view-only
/// (`isSessionReadOnly`), so the menu already reduces to copy/export for them;
/// swipe mutations are intentionally not attached.
struct SessionChildInteractiveRow: View {
    let viewModel: SessionListViewModel
    let session: SessionSummary
    let selectedSessionID: String?
    let actions: SessionListRowActions

    var body: some View {
        Button {
            actions.open(session)
        } label: {
            SessionChildSessionRowView(
                session: session,
                isViewingCachedData: viewModel.isViewingCachedData
            )
        }
        .buttonStyle(.plain)
        .id(session.id)
        .background(
            session.sessionId == selectedSessionID
                ? Color.accentColor.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contextMenu {
            SessionRowContextMenu(
                session: session,
                projects: viewModel.projects,
                isViewingCachedData: viewModel.isViewingCachedData,
                isRenamingSession: viewModel.isRenamingSession,
                isCreatingProject: viewModel.isCreatingProject,
                isMovingSession: viewModel.isMovingSession,
                isLoadingProjects: viewModel.isLoadingProjects,
                isMutating: viewModel.isMutating(session),
                actions: actions
            )
        }
        .sessionsScreenListRow(insets: EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
    }
}

struct SessionRowContextMenu: View {
    let session: SessionSummary
    let projects: [ProjectSummary]
    let isViewingCachedData: Bool
    let isRenamingSession: Bool
    let isCreatingProject: Bool
    let isMovingSession: Bool
    let isLoadingProjects: Bool
    let isMutating: Bool
    let actions: SessionListRowActions

    var body: some View {
        let fullTitle = SessionRowView.displayTitle(for: session)

        Section("Full Title") {
            Text(fullTitle)

            Button {
                UIPasteboard.general.string = fullTitle
            } label: {
                Label("Copy Full Title", systemImage: "doc.on.doc")
            }
        }

        if SessionRowActionPolicy.offersMutationActions(for: session) {
            Button {
                actions.togglePinned(session)
            } label: {
                Label(session.pinned == true ? "Unpin" : "Pin", systemImage: "pin")
            }
            .disabled(!canShowSessionMutationActions || isMutating)

            Button {
                actions.rename(session)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(isViewingCachedData || isRenamingSession || !hasServerSessionID(session))

            Button {
                actions.duplicate(session)
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            .disabled(isViewingCachedData || session.sessionId == nil || isMutating)

            Menu {
                SessionProjectMoveMenu(
                    session: session,
                    projects: projects,
                    isCreatingProject: isCreatingProject,
                    isMovingSession: isMovingSession,
                    isLoadingProjects: isLoadingProjects,
                    actions: actions
                )
            } label: {
                Label("Move to Project", systemImage: "folder")
            }
            .disabled(isViewingCachedData || session.sessionId == nil || isMutating)
        }

        // Export works for any session the server can see, including read-only
        // and foreign/CLI rows; it only needs a live server session ID.
        Menu {
            Button {
                actions.export(session, .html)
            } label: {
                Label("Export as HTML", systemImage: "doc.richtext")
            }

            Button {
                actions.export(session, .json)
            } label: {
                Label("Export as JSON", systemImage: "curlybraces")
            }

            if let deepLinkURL = SessionRowActionPolicy.deepLinkURL(
                for: session,
                isViewingCachedData: isViewingCachedData,
                isMutating: isMutating
            ) {
                Button {
                    UIPasteboard.general.string = deepLinkURL.absoluteString
                } label: {
                    Label("Copy Deeplink", systemImage: "doc.on.doc")
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(!canExportSession || isMutating)

        if SessionRowActionPolicy.offersMutationActions(for: session) {
            Button {
                actions.archive(session)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(!canShowSessionMutationActions || isMutating)

            Button(role: .destructive) {
                actions.delete(session)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!canShowSessionMutationActions || isMutating)
        }
    }

    private var canShowSessionMutationActions: Bool {
        SessionRowActionPolicy.offersMutationActions(for: session)
            && !isViewingCachedData
            && hasServerSessionID(session)
    }

    private var canExportSession: Bool {
        SessionRowActionPolicy.canExport(session, isViewingCachedData: isViewingCachedData)
    }
}

struct SessionProjectMoveMenu: View {
    let session: SessionSummary
    let projects: [ProjectSummary]
    let isCreatingProject: Bool
    let isMovingSession: Bool
    let isLoadingProjects: Bool
    let actions: SessionListRowActions

    var body: some View {
        Button {
            actions.move(session, nil)
        } label: {
            Label("No project", systemImage: session.projectId == nil ? "checkmark" : "tray")
        }
        .disabled(isMovingSession || session.projectId == nil)

        if !projects.isEmpty {
            Divider()

            ForEach(projects) { project in
                let projectID = project.projectId
                let isSelected = session.projectId == projectID
                let projectName = project.name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Untitled Project")

                Button {
                    actions.move(session, projectID)
                } label: {
                    Label(
                        projectName,
                        systemImage: isSelected ? "checkmark" : "folder"
                    )
                }
                .disabled(isMovingSession || projectID == nil || isSelected)
            }
        }

        Divider()

        Button {
            actions.createProject(session)
        } label: {
            Label("New Project", systemImage: "folder.badge.plus")
        }
        .disabled(isCreatingProject || isMovingSession)

        if projects.isEmpty {
            Button {
                actions.refreshProjects()
            } label: {
                Label("Refresh Projects", systemImage: "arrow.clockwise")
            }
            .disabled(isLoadingProjects)
        }
    }
}

/// Pure, testable backing model for the session-list avatar's long-press server
/// switcher (#283). Maps `AuthManager.servers` + the active server id into the
/// rows the context menu renders, deriving each row's display name the same way
/// the Settings server list does, so the menu's contents — and which server is
/// marked active — are unit-testable without standing up the view.
struct AvatarServerSwitcherModel: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: String
        let account: ServerAccount
        let displayName: String
        let isActive: Bool
    }

    let entries: [Entry]

    /// The id of the entry marked active, or nil when the active id matches no
    /// configured server (a defensive transient, e.g. mid-removal).
    var activeID: String? { entries.first(where: \.isActive)?.id }

    init(servers: [ServerAccount], activeServerID: String?) {
        entries = servers.map { account in
            let hostFallback = URL(string: account.urlString)?.host ?? account.urlString
            let displayName = account.displayName.isEmpty ? hostFallback : account.displayName
            return Entry(
                id: account.id,
                account: account,
                displayName: displayName,
                isActive: account.id == activeServerID
            )
        }
    }
}

/// Long-press menu on the session-list avatar: switch the active server (the
/// active one marked + disabled, mirroring `SessionProjectMoveMenu`'s checkmark
/// idiom), plus shortcuts into #17's add-server flow and the Settings server
/// list (#283). Holds no switching logic — it calls back into the tested #17
/// `AuthManager.switchActiveServer` action and the existing navigation.
struct AvatarServerSwitcherMenu: View {
    let model: AvatarServerSwitcherModel
    let switchToServer: (ServerAccount) -> Void
    let addServer: () -> Void
    let manageServers: () -> Void

    var body: some View {
        Section("Servers") {
            ForEach(model.entries) { entry in
                Button {
                    switchToServer(entry.account)
                } label: {
                    Label(entry.displayName, systemImage: entry.isActive ? "checkmark" : "server.rack")
                }
                .disabled(entry.isActive)
                .accessibilityLabel(
                    entry.isActive
                        ? String(localized: "\(entry.displayName), active server")
                        : String(localized: "Switch to \(entry.displayName)")
                )
            }
        }

        Section {
            Button {
                addServer()
            } label: {
                Label("Add Server…", systemImage: "plus")
            }

            Button {
                manageServers()
            } label: {
                Label("Manage Servers", systemImage: "gearshape")
            }
        }
    }
}

extension View {
    func sessionsScreenListRow(insets: EdgeInsets = EdgeInsets()) -> some View {
        listRowInsets(insets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color(.systemBackground))
    }

    func sessionsTopChromeListRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 18, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .zIndex(1)
    }

    func sessionsChromeGlass<S: InsettableShape>(
        isInteractive: Bool = false,
        tint: Color? = nil,
        fallbackMaterial: Material = .ultraThinMaterial,
        in shape: S
    ) -> some View {
        adaptiveGlass(
            .regular,
            isInteractive: isInteractive,
            tint: tint,
            fallbackMaterial: fallbackMaterial,
            in: shape
        )
    }
}

/// Sheet item for a finished session export: the temp file offered to the
/// share sheet. Identity is the file URL, which is unique per export.
struct SessionExportShareItem: Identifiable {
    let fileURL: URL

    var id: String { fileURL.absoluteString }
}

/// Minimal `UIActivityViewController` wrapper — the app has no other share
/// surface and `ShareLink` can't be presented programmatically after an async
/// download finishes. Cleanup of the temp file happens in the sheet's
/// `onDismiss`, which runs after the activity UI is gone in both the
/// completed and cancelled paths.
struct SessionExportShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private func hasServerSessionID(_ session: SessionSummary) -> Bool {
    guard let sessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return false
    }

    return !sessionID.isEmpty
}

struct SessionListFloatingChatButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed

        configuration.label
            .scaleEffect(reduceMotion ? 1 : (isPressed ? 0.975 : 1))
            .opacity(isPressed ? 0.96 : 1)
            .shadow(
                color: .black.opacity(isPressed ? 0.10 : 0.18),
                radius: isPressed ? 8 : 18,
                y: isPressed ? 3 : 8
            )
            .animation(SessionListMotion.pressAnimation(reduceMotion: reduceMotion), value: isPressed)
    }
}

struct SidebarNavButton: View {
    let title: String
    let assetImage: String
    let action: () -> Void

    var body: some View {
        HapticButton(action: action) {
            HStack(spacing: 18) {
                SidebarUtilityIcon(assetImage: assetImage)

                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct SidebarDisclosureButton<Accessory: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let assetImage: String
    let isExpanded: Bool
    var tint: Color = .primary
    let action: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HapticButton(action: action) {
            HStack(alignment: .center, spacing: 18) {
                SidebarUtilityIcon(assetImage: assetImage, tint: tint)

                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                accessory()

                SidebarDisclosureChevron(isExpanded: isExpanded)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SidebarDisclosureChevron: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let isExpanded: Bool

    // Rotate inside a square box so the pivot is the visual center; the outer
    // frame keeps a fixed slot so the chevron never shifts horizontally or
    // vertically. A value-based animation rotates it in place (and is skipped
    // under Reduce Motion) regardless of the ambient List transaction.
    // `chevron.forward` mirrors to point leading-ward under RTL; the expand
    // rotation reverses there so the open state still points down (issue #294).
    var body: some View {
        Image(systemName: "chevron.forward")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .rotationEffect(
                .degrees(RTLLayout.disclosureChevronRotationDegrees(
                    isExpanded: isExpanded,
                    isRightToLeft: layoutDirection == .rightToLeft
                )),
                anchor: .center
            )
            .frame(width: 24, height: 40)
            .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: isExpanded)
            .accessibilityHidden(true)
    }
}

struct SidebarUtilityIcon: View {
    let assetImage: String
    var tint: Color = .primary

    var body: some View {
        Image(assetImage)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 21, height: 21)
            .foregroundStyle(tint)
            .frame(width: 28)
            .accessibilityHidden(true)
    }
}

struct SidebarSelectedSubrowIndicator: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Color.accentColor, in: Circle())
            .accessibilityHidden(true)
    }
}

struct SidebarSubrowSelectionStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.20), lineWidth: 1)
                        }
                }
            }
    }
}

extension View {
    func sidebarSubrowSelectionStyle(isSelected: Bool) -> some View {
        modifier(SidebarSubrowSelectionStyle(isSelected: isSelected))
    }
}

struct ActiveProfilePickerRow: View {
    let profile: ProfileSummary
    let isSelected: Bool
    let isSwitching: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                SidebarUtilityIcon(
                    assetImage: "LucideUserRound",
                    tint: isSelected ? Color.accentColor : .primary
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(defaultModelTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isSwitching {
                    ProgressView()
                        .controlSize(.small)
                } else if isSelected {
                    SidebarSelectedSubrowIndicator()
                }
            }
            .frame(minHeight: 44)
            .sidebarSubrowSelectionStyle(isSelected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var defaultModelTitle: String {
        let model = profile.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model, !model.isEmpty else {
            return String(localized: "Default model unavailable")
        }
        return model
    }

    private var accessibilityLabel: String {
        let state = isSelected ? String(localized: "Active profile") : String(localized: "Profile")
        let switchingState = isSwitching ? String(localized: ", switching in progress") : ""
        return String(localized: "\(state), \(profile.displayName), \(defaultModelTitle)\(switchingState)")
    }
}

extension ProjectSummary {
    /// The project's chip/dot color: the server-assigned hex when present,
    /// else a stable per-project fallback (carried over from the retired
    /// Projects disclosure rows so existing projects keep their colors).
    static func displayColor(colorHex: String?, fallbackSeed: String) -> Color {
        if let apiColor = Color(hexString: colorHex) {
            return apiColor
        }

        let seed = fallbackSeed.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult &+ Int(scalar.value)
        }

        switch seed % 5 {
        case 0: return .green
        case 1: return .blue
        case 2: return .red
        case 3: return .orange
        default: return .primary
        }
    }
}

extension Color {
    init?(hexString: String?) {
        guard let hexString else { return nil }

        var trimmed = hexString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            trimmed.removeFirst()
        }

        let expanded: String
        switch trimmed.count {
        case 3:
            expanded = trimmed.map { "\($0)\($0)" }.joined()
        case 6:
            expanded = trimmed
        default:
            return nil
        }

        guard let value = UInt64(expanded, radix: 16) else { return nil }

        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

struct CompactStatusRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .frame(minHeight: 42)
    }
}

private struct SessionListStatusRow: View {
    let title: String
    let description: String?
    let systemImage: String
    var descriptionLineLimit: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)

                if let description {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(descriptionLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 42)
    }
}

struct SessionRowSkeletonView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var verticalPadding: CGFloat = 8

    let configuration: SessionRowSkeletonConfiguration
    let showsMessageCount: Bool
    let showsWorkspace: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: rowContentSpacing) {
            titleArea

            if let metadataLabel {
                Text(verbatim: metadataLabel)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(metadataLineLimit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
        .frame(minHeight: metadataLabel == nil ? 46 : 54)
        .redacted(reason: .placeholder)
    }

    @ViewBuilder
    private var titleArea: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                titleText
                relativeDateText
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleText

                Spacer(minLength: 8)

                relativeDateText
            }
        }
    }

    private var titleText: some View {
        Text(verbatim: configuration.title)
            .font(AppFont.headline(weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var relativeDateText: some View {
        Text(verbatim: configuration.relativeDate)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var rowContentSpacing: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 6 : 4
    }

    private var metadataLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 1
    }

    private var metadataLabel: String? {
        let parts = [
            showsMessageCount ? configuration.messageCount : nil,
            showsWorkspace ? configuration.workspace : nil
        ].compactMap(\.self)

        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

struct SessionRowSkeletonConfiguration: Identifiable {
    let id: String
    let title: String
    let messageCount: String
    let workspace: String
    let relativeDate: String

    static let loadingRows: [SessionRowSkeletonConfiguration] = [
        SessionRowSkeletonConfiguration(
            id: "recent-build",
            title: "Review latest mobile build notes",
            messageCount: "12 messages",
            workspace: "hermes-mobile",
            relativeDate: "5m"
        ),
        SessionRowSkeletonConfiguration(
            id: "polish-pass",
            title: "Plan the next polish pass",
            messageCount: "8 messages",
            workspace: "design",
            relativeDate: "1h"
        ),
        SessionRowSkeletonConfiguration(
            id: "streaming-check",
            title: "Streaming behavior investigation",
            messageCount: "24 messages",
            workspace: "webui",
            relativeDate: "3h"
        ),
        SessionRowSkeletonConfiguration(
            id: "testflight",
            title: "TestFlight validation checklist",
            messageCount: "6 messages",
            workspace: "release",
            relativeDate: "1d"
        ),
        SessionRowSkeletonConfiguration(
            id: "followup",
            title: "Follow-up implementation details",
            messageCount: "17 messages",
            workspace: "notes",
            relativeDate: "2d"
        )
    ]
}

struct OfflineCacheBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .imageScale(.small)
                .accessibilityHidden(true)

            Text("Offline - viewing cached version")
                .font(.subheadline)
                .fontWeight(.semibold)

            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}
