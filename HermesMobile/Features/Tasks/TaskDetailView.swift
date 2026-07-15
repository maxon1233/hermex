import SwiftUI

struct TaskDetailView: View {
    let server: URL
    let onAPIError: (Error) -> Void
    let onMutation: (CronJobListMutation) -> Void
    let sessions: [SessionSummary]
    let onOpenSession: (SessionSummary) -> Void
    let onStartSession: (String) -> Void

    @State private var viewModel: TaskDetailViewModel
    @State private var isPresentingEditTask = false
    @State private var isConfirmingDelete = false
    @State private var isPresentingFullTask = false
    @State private var expandedRunIDs: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    init(
        job: CronJob,
        runningElapsed: Double?,
        server: URL,
        onAPIError: @escaping (Error) -> Void,
        onMutation: @escaping (CronJobListMutation) -> Void = { _ in },
        sessions: [SessionSummary] = [],
        onOpenSession: @escaping (SessionSummary) -> Void = { _ in },
        onStartSession: @escaping (String) -> Void = { _ in }
    ) {
        self.server = server
        self.onAPIError = onAPIError
        self.onMutation = onMutation
        self.sessions = sessions
        self.onOpenSession = onOpenSession
        self.onStartSession = onStartSession
        _viewModel = State(initialValue: TaskDetailViewModel(job: job, runningElapsed: runningElapsed, server: server))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                actionStatusSection
                descriptionSection
                scheduleSection
                currentStatusSection
                runHistorySection
            }
            .padding()
        }
        .navigationTitle(viewModel.job.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await loadOutput() }
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isLoading)

                Menu {
                    Button {
                        Task { await runNow() }
                    } label: {
                        Label("Run Now", systemImage: "play.fill")
                    }
                    .disabled(isActionDisabled)

                    Button {
                        Task { await togglePauseResume() }
                    } label: {
                        Label(pauseResumeTitle, systemImage: pauseResumeSystemImage)
                    }
                    .disabled(isActionDisabled)

                    Button {
                        viewModel.clearActionError()
                        isPresentingEditTask = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .disabled(isActionDisabled)

                    Divider()

                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(isActionDisabled)
                } label: {
                    Label("Task Actions", systemImage: "ellipsis.circle")
                }
                .disabled(viewModel.isMutating)
            }
        }
        .sheet(isPresented: $isPresentingEditTask) {
            CronJobEditorSheet(
                title: String(localized: "Edit Task"),
                draft: CronJobEditorDraft(job: viewModel.job),
                saveTitle: String(localized: "Save"),
                isSaving: viewModel.isMutating,
                errorMessage: viewModel.actionErrorMessage,
                deliveryOptions: viewModel.deliveryOptions
            ) { draft in
                let didUpdate = await viewModel.update(from: draft)
                handleActionResult(didUpdate)
                return didUpdate
            }
        }
        .sheet(isPresented: $isPresentingFullTask) {
            fullTaskSheet
        }
        .alert("Delete Task?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                Task { await deleteTask() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the scheduled task from the Hermes server.")
        }
        .task {
            await loadOutput()
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(viewModel.job.displayName)
                .font(.title2.bold())
                .lineLimit(2)

            Spacer(minLength: 8)

            StatusBadge(
                text: viewModel.runningElapsed == nil ? viewModel.job.status.label : String(localized: "Running"),
                color: statusColor
            )
        }
    }

    @ViewBuilder
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)

            if let summary = viewModel.job.descriptionSummary, !summary.isEmpty {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(.secondary)

                Button("Show full task") {
                    isPresentingFullTask = true
                }
                .font(.subheadline.weight(.medium))
            } else {
                Text("No description provided.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var actionStatusSection: some View {
        if viewModel.isMutating {
            HStack(spacing: 8) {
                ProgressView()
                Text("Updating task...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let actionErrorMessage = viewModel.actionErrorMessage {
            Text(actionErrorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Schedule")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                CronJobMetadataRow(
                    title: String(localized: "How often"),
                    value: viewModel.job.readableScheduleText ?? String(localized: "Not available")
                )

                CronJobMetadataRow(
                    title: String(localized: "Next run"),
                    value: viewModel.job.nextRunAt?.formatted ?? String(localized: "Not available")
                )

                CronJobMetadataRow(
                    title: String(localized: "First run"),
                    value: firstRunText
                )

                if let runningElapsed = viewModel.runningElapsed {
                    CronJobMetadataRow(
                        title: String(localized: "Running for"),
                        value: elapsedText(runningElapsed)
                    )
                }
            }
            .font(.footnote)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var currentStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current Status")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(currentRunStatus.text, systemImage: currentRunStatus.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(currentRunStatus.color)

                    Spacer(minLength: 8)

                    if let time = viewModel.outputs.first?.formattedRunTime {
                        Text(time)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if viewModel.isLoading && viewModel.outputs.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading latest update...")
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage = viewModel.errorMessage, viewModel.outputs.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)

                    Button("Try Again") {
                        Task { await loadOutput() }
                    }
                    .font(.subheadline.weight(.medium))
                } else if let latestOutput = viewModel.outputs.first {
                    if let result = latestOutput.resultText {
                        MarkdownRenderer(content: result)
                    } else {
                        Text("The latest run did not record an update.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No updates yet. This task has not completed a run.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let error = viewModel.job.lastError ?? viewModel.job.lastDeliveryError, !error.isEmpty {
                    Divider()
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                Divider()

                runSessionAction(
                    output: viewModel.outputs.first,
                    momentTitle: String(localized: "Current task status")
                )
                .font(.subheadline.weight(.semibold))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var runHistorySection: some View {
        let runSessions = resolvedRunSessions

        return VStack(alignment: .leading, spacing: 12) {
            Text("Run History")
                .font(.headline)

            if viewModel.outputs.isEmpty {
                Text("No runs recorded.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.outputs) { output in
                        runHistoryCard(output, session: runSessions[output.id])
                    }
                }
            }
        }
    }

    private func runHistoryCard(_ output: CronOutputItem, session: SessionSummary?) -> some View {
        let isExpanded = expandedRunIDs.contains(output.id)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(
                    output.formattedRunTime ?? String(localized: "Recorded result"),
                    systemImage: "clock"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if output.id == viewModel.outputs.first?.id {
                    Text("Latest")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }

            if isExpanded, let result = output.resultText {
                MarkdownRenderer(content: result)
            } else {
                Text(output.summaryText)
                    .font(.body)
                    .foregroundStyle(output.resultText == nil ? .secondary : .primary)
                    .lineLimit(3)
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedRunIDs.remove(output.id)
                        } else {
                            expandedRunIDs.insert(output.id)
                        }
                    }
                } label: {
                    Label(
                        isExpanded ? "Show Less" : "Show Full Run",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                }

                Spacer(minLength: 8)

                runSessionAction(
                    output: output,
                    session: session,
                    momentTitle: String(localized: "Task run")
                )
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var fullTaskSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(viewModel.job.prompt ?? String(localized: "No description provided."))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        isPresentingFullTask = false
                        if let latestOutput = viewModel.outputs.first,
                           let session = resolvedRunSessions[latestOutput.id] {
                            onOpenSession(session)
                        } else {
                            startSession(from: nil, momentTitle: String(localized: "Full task description"))
                        }
                    } label: {
                        Label(
                            latestSession == nil ? "Start Session" : "Open Session",
                            systemImage: "bubble.left.and.bubble.right"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .navigationTitle("Full Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isPresentingFullTask = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var firstRunText: String {
        guard let firstRun = viewModel.outputs
            .filter({ $0.runDate != nil })
            .min(by: { ($0.runDate ?? .distantFuture) < ($1.runDate ?? .distantFuture) }) else {
            return String(localized: "Not run yet")
        }
        return firstRun.formattedRunTime ?? String(localized: "Not recorded")
    }

    private var resolvedRunSessions: [String: SessionSummary] {
        CronRunSessionResolver.sessionsByOutputID(
            job: viewModel.job,
            outputs: viewModel.outputs,
            sessions: sessions
        )
    }

    private var latestSession: SessionSummary? {
        guard let latestOutput = viewModel.outputs.first else { return nil }
        return resolvedRunSessions[latestOutput.id]
    }

    @ViewBuilder
    private func runSessionAction(
        output: CronOutputItem?,
        session: SessionSummary? = nil,
        momentTitle: String
    ) -> some View {
        let resolvedSession = session ?? output.flatMap { resolvedRunSessions[$0.id] }
        if let resolvedSession {
            Button {
                onOpenSession(resolvedSession)
            } label: {
                Label("Open Session", systemImage: "bubble.left.and.bubble.right")
            }
        } else {
            Button {
                startSession(from: output, momentTitle: momentTitle)
            } label: {
                Label("Start Session", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }

    private func startSession(from output: CronOutputItem?, momentTitle: String) {
        onStartSession(
            CronSessionContextBuilder.draft(
                job: viewModel.job,
                outputs: viewModel.outputs,
                selectedOutput: output,
                momentTitle: momentTitle
            )
        )
    }

    private var currentRunStatus: (text: String, systemImage: String, color: Color) {
        if viewModel.runningElapsed != nil {
            return (String(localized: "Running now"), "arrow.triangle.2.circlepath", .blue)
        }

        switch viewModel.job.lastStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ok", "success", "succeeded", "completed":
            return (String(localized: "Latest run completed"), "checkmark.circle.fill", .green)
        case "error", "failed", "failure":
            return (String(localized: "Latest run failed"), "xmark.circle.fill", .red)
        case "cancelled", "canceled":
            return (String(localized: "Latest run cancelled"), "slash.circle.fill", .orange)
        default:
            if viewModel.outputs.isEmpty {
                return (String(localized: "Waiting for first run"), "clock", .secondary)
            }
            return (String(localized: "Latest update"), "info.circle.fill", .blue)
        }
    }

    private var statusColor: Color {
        if viewModel.runningElapsed != nil {
            return .blue
        }

        switch viewModel.job.status {
        case .active:
            return .green
        case .paused, .off:
            return .orange
        case .error:
            return .red
        case .needsAttention:
            return .yellow
        }
    }

    private var isActionDisabled: Bool {
        viewModel.isMutating || viewModel.job.jobId == nil
    }

    private var pauseResumeTitle: String {
        shouldResume ? String(localized: "Resume") : String(localized: "Pause")
    }

    private var pauseResumeSystemImage: String {
        shouldResume ? "play.circle" : "pause.circle"
    }

    private var shouldResume: Bool {
        viewModel.job.status == .paused || viewModel.job.status == .off
    }

    private func elapsedText(_ elapsed: Double) -> String {
        if elapsed < 60 {
            return "\(Int(elapsed.rounded()))s"
        }

        let minutes = Int(elapsed / 60)
        let seconds = Int(elapsed.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(seconds)s"
    }

    private func loadOutput() async {
        await viewModel.load()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func runNow() async {
        let didRun = await viewModel.runNow()
        handleActionResult(didRun)
    }

    private func togglePauseResume() async {
        let didMutate: Bool
        if shouldResume {
            didMutate = await viewModel.resume()
        } else {
            didMutate = await viewModel.pause()
        }
        handleActionResult(didMutate)
    }

    private func deleteTask() async {
        let didDelete = await viewModel.delete()
        handleActionResult(didDelete)

        if didDelete {
            dismiss()
        }
    }

    private func handleActionResult(_ success: Bool) {
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }

        guard success, let mutation = viewModel.lastMutation else {
            return
        }

        onMutation(mutation)
    }
}
