#if DEBUG
import SwiftUI

/// Deterministic, server-free fixture for exercising the production transcript
/// restoration lifecycle with real Simulator swipe gestures.
struct ScrollRestorationLabView: View {
    @State private var showsTranscript = false
    @State private var resetGeneration = 0
    @State private var openGeneration = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Button("Reset Saved Position") {
                    ChatTranscriptScrollPersistence.save(
                        nil,
                        for: ScrollRestorationLabFixture.server,
                        sessionID: ScrollRestorationLabFixture.sessionID
                    )
                    resetGeneration += 1
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("scroll-lab-reset")

                Button("Seed Legacy Position") {
                    ChatTranscriptScrollPersistence.save(
                        ScrollRestorationLabFixture.legacyPosition,
                        for: ScrollRestorationLabFixture.server,
                        sessionID: ScrollRestorationLabFixture.sessionID
                    )
                    resetGeneration += 1
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("scroll-lab-seed-legacy-position")

                Button("Seed Missing Position") {
                    ChatTranscriptScrollPersistence.save(
                        ScrollRestorationLabFixture.missingPosition,
                        for: ScrollRestorationLabFixture.server,
                        sessionID: ScrollRestorationLabFixture.sessionID
                    )
                    resetGeneration += 1
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("scroll-lab-seed-missing-position")

                Button("Seed Targeted Position") {
                    ChatTranscriptScrollPersistence.save(
                        ScrollRestorationLabFixture.targetedPosition,
                        for: ScrollRestorationLabFixture.server,
                        sessionID: ScrollRestorationLabFixture.sessionID
                    )
                    resetGeneration += 1
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("scroll-lab-seed-targeted-position")

                Button("Open Transcript") {
                    openGeneration += 1
                    showsTranscript = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("scroll-lab-open")

                Text("Reset generation \(resetGeneration)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Scroll Lab")
            .navigationDestination(isPresented: $showsTranscript) {
                ScrollRestorationLabTranscriptView(
                    isLoadingMessages: ProcessInfo.processInfo.arguments.contains(
                        "--scroll-restoration-lab-loading"
                    ),
                    hasOlderMessages: ProcessInfo.processInfo.arguments.contains(
                        "--scroll-restoration-lab-has-older"
                    ),
                    targetedHistoricalRestoration:
                        ProcessInfo.processInfo.arguments.contains(
                            "--scroll-restoration-lab-targeted-history"
                        ),
                    delayedFallbackLayout:
                        ProcessInfo.processInfo.arguments.contains(
                            "--scroll-restoration-lab-delayed-fallback-layout"
                        ),
                    fallbackWindowSwap:
                        ProcessInfo.processInfo.arguments.contains(
                            "--scroll-restoration-lab-fallback-window-swap"
                        )
                )
                    .id(openGeneration)
            }
        }
    }
}

private enum ScrollRestorationLabFixture {
    static let server = URL(string: "https://scroll-restoration-lab.invalid")!
    static let sessionID = "deterministic-transcript"
    static let bottomAnchorID = "scroll-restoration-lab-bottom"
    static let messageOffset = 2_011
    static let boundedMessageCount = ChatViewModel.automaticMessageWindowLimit
    static let legacyPosition = ChatTranscriptScrollPosition(
        renderID: "transcript:2025",
        offsetFromRowTop: 42
    )
    static let missingPosition = ChatTranscriptScrollPosition(
        renderID: "transcript:1000",
        messageID: "scroll-lab-message-outside-window",
        offsetFromRowTop: 42
    )
    static let targetedPosition = ChatTranscriptScrollPosition(
        renderID: "transcript:2092",
        messageID: "scroll-lab-message-81",
        offsetFromRowTop: 42
    )
    static let targetedLatestMessageOffset = 2_600
    static let targetedLatestMessages: [ChatMessage] =
        (0..<boundedMessageCount).map { index in
            let absoluteIndex = targetedLatestMessageOffset + index
            return ChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Newest bounded tail message \(absoluteIndex)",
                timestamp: Double(absoluteIndex),
                messageId: "scroll-lab-latest-\(absoluteIndex)"
            )
        }
    static let targetedHistoricalMessageOffset = 2_067
    static let targetedHistoricalMessages = Array(
        messages[
            (targetedHistoricalMessageOffset - messageOffset)..<(
                targetedHistoricalMessageOffset
                    - messageOffset
                    + ChatViewModel.restorationMessageWindowLimit
            )
        ]
    )
    static let fallbackLatestMessages = Array(
        targetedLatestMessages.suffix(50)
    )
    static let fallbackLatestMessageOffset =
        targetedLatestMessageOffset
            + boundedMessageCount
            - fallbackLatestMessages.count

    // Exercise the largest automatic production window. Keep detailed Markdown
    // in the latest visible turns and regular samples through history; making
    // every historical row verbose causes XCUITest accessibility snapshots to
    // dominate the interaction latency that this fixture is meant to measure.
    static let messages: [ChatMessage] = (0..<boundedMessageCount).map { index in
        let role = index.isMultiple(of: 2) ? "user" : "assistant"
        let content: String
        if role == "user" {
            content = "User message \(index): verify the bounded Mem0 transcript and keep the composer responsive."
        } else if index >= boundedMessageCount - 24 || index % 40 == 1 {
            content = """
            Assistant message \(index)

            This deterministic turn includes **formatted detail**, `inline-code-\(index)`,
            and a stable session reference so Markdown measurement resembles a real
            long-running conversation.

            - Window item \(index)
            - Follow-latest state remains observable
            - Completion reconciliation keeps absolute row identity

            Final paragraph for message \(index), with enough wrapping text to make
            viewport growth and repeated swipe latency meaningful on Simulator.
            """
        } else {
            content = "Assistant message \(index): bounded historical response."
        }

        return ChatMessage(
            role: role,
            content: content,
            timestamp: Double(index),
            messageId: "scroll-lab-message-\(index)"
        )
    }
}

private struct ScrollRestorationLabTranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var initialPosition: ChatTranscriptScrollPosition?
    @State private var committedPosition: ChatTranscriptScrollPosition?
    @State private var positionRecorder: ChatTranscriptScrollPositionRecorder
    @State private var latestMetrics: ChatScrollMetrics?
    @State private var shouldFollowLatest: Bool
    @State private var isNearBottom: Bool
    @State private var isReadingOlderTranscript: Bool
    @State private var isUserInteractingWithScroll = false
    @State private var latestDistanceFromBottom: CGFloat?
    @State private var userScrollCooldownUntil: Date?
    @State private var followScrollGeneration = 0
    @State private var restorationStatus = "pending"
    @State private var initialResolution:
        ChatTranscriptInitialScrollResolution?
    @State private var responseStatus = "idle"
    @State private var draftText = ""
    @State private var isComposerFocused = false
    @State private var composerInputHeight: CGFloat = 22
    @State private var measuredComposerHeight: CGFloat = 22
    @State private var messages: [ChatMessage]
    @State private var messageOffset: Int
    @State private var activeStreamID: String?
    @State private var streamingScrollTrigger = 0
    @State private var responseTask: Task<Void, Never>?
    @State private var olderMessageLoadCount = 0
    @State private var targetedWindowLoadCount = 0
    @State private var latestWindowLoadCount = 0
    @State private var retainedLatestMessages: [ChatMessage]?
    @State private var didExposeUnrelatedLatestTail: Bool
    @State private var latestArrivedWhileTargetPending = false
    @State private var isLoadingMessages: Bool
    @State private var delayedLayoutTask: Task<Void, Never>?
    @State private var didApplyDelayedFallbackLayout = false
    private let hasOlderMessages: Bool
    private let targetedHistoricalRestoration: Bool
    private let delayedFallbackLayout: Bool
    private let fallbackWindowSwap: Bool

    init(
        isLoadingMessages: Bool = false,
        hasOlderMessages: Bool = false,
        targetedHistoricalRestoration: Bool = false,
        delayedFallbackLayout: Bool = false,
        fallbackWindowSwap: Bool = false
    ) {
        self.hasOlderMessages = hasOlderMessages
        self.targetedHistoricalRestoration =
            targetedHistoricalRestoration
        self.delayedFallbackLayout = delayedFallbackLayout
        self.fallbackWindowSwap = fallbackWindowSwap
        _isLoadingMessages = State(
            initialValue: isLoadingMessages
                || targetedHistoricalRestoration
        )
        let initialMessages = targetedHistoricalRestoration
            ? []
            : ScrollRestorationLabFixture.messages
        _messages = State(initialValue: initialMessages)
        _retainedLatestMessages = State(initialValue: nil)
        _didExposeUnrelatedLatestTail = State(
            initialValue: initialMessages.contains(where: {
                $0.messageId?.hasPrefix("scroll-lab-latest-") == true
            })
        )
        _messageOffset = State(
            initialValue: targetedHistoricalRestoration
                ? 0
                : ScrollRestorationLabFixture.messageOffset
        )
        let storedPosition = ChatTranscriptScrollPersistence.load(
            for: ScrollRestorationLabFixture.server,
            sessionID: ScrollRestorationLabFixture.sessionID
        )
        _initialPosition = State(initialValue: storedPosition)
        _committedPosition = State(initialValue: storedPosition)
        _positionRecorder = State(
            initialValue: ChatTranscriptScrollPositionRecorder(
                initialPosition: storedPosition
            ) { position in
                ChatTranscriptScrollPersistence.save(
                    position,
                    for: ScrollRestorationLabFixture.server,
                    sessionID: ScrollRestorationLabFixture.sessionID
                )
            }
        )
        _shouldFollowLatest = State(initialValue: storedPosition == nil)
        _isNearBottom = State(initialValue: storedPosition == nil)
        _isReadingOlderTranscript = State(initialValue: storedPosition != nil)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ChatTranscriptView(
                isLoading: isLoadingMessages,
                errorMessage: nil,
                messages: messages,
                displayedTranscriptMessages: ChatViewModel.transcriptMessages(
                    from: messages,
                    messageOffset: messageOffset
                ),
                initialScrollPosition: initialPosition,
                compressionReferenceCard: nil,
                reasoningGroups: [],
                completedToolCallGroupsForAnchor: { _ in [] },
                liveReasoningText: "",
                reasoningAnchorMessageID: nil,
                liveToolCalls: [],
                toolCallAnchorMessageID: nil,
                streamingAssistantMessageID: nil,
                activeStreamRecoveryState: .idle,
                clarificationPrompt: nil,
                isRespondingToClarification: false,
                clarificationErrorMessage: nil,
                hidesRunStatusAccessibility: false,
                showsThinkingAndToolCards: false,
                showsAssistantTypingIndicator: false,
                showsScrollToBottomButton: !isNearBottom,
                shouldFollowLatestMessage: shouldFollowLatest,
                latestTranscriptMessageRole: messages.last?.role,
                isScrolledNearBottom: isNearBottom,
                activeStreamID: activeStreamID,
                streamingScrollTrigger: streamingScrollTrigger,
                cacheFirstReconcileScrollToken: 0,
                bottomAnchorID: ScrollRestorationLabFixture.bottomAnchorID,
                transcriptMessageSpacing: 10,
                transcriptBlockSpacing: 6,
                transcriptBottomInsetHeight: 104,
                scrollToBottomButtonBottomPadding: 12,
                localAttachmentPreviews: [:],
                listeningMessageID: nil,
                isViewingCachedData: false,
                hasOlderMessages: hasOlderMessages,
                isLoadingOlderMessages: false,
                isRegeneratingMessage: false,
                isEditingMessage: false,
                isForkingMessage: false,
                loadAttachmentImage: { _ in nil },
                loadAttachmentData: { _ in nil },
                loadTranscriptMediaImage: { _ in nil },
                loadTranscriptMediaData: { _ in nil },
                transcriptMediaCacheNamespace: "scroll-restoration-lab",
                actionContext: { _, _ in nil },
                shouldRenderMessageRow: { _ in true },
                onLoadMessages: {},
                onLoadOlderMessages: {
                    olderMessageLoadCount += 1
                    return false
                },
                onUpdateScrollMetrics: updateScrollMetrics,
                onDismissKeyboard: {
                    isComposerFocused = false
                },
                onScrollToBottom: scrollToBottom,
                onScrollToLatestTranscriptMessage: { proxy in
                    scrollToLatestTranscriptMessage(proxy)
                },
                onScrollToLatestContent: { proxy, animated in
                    scrollToLatestContent(proxy, animated: animated)
                },
                onCancelInitialRestoration: {},
                onInitialScrollPositionResolution: completeInitialRestoration,
                onReadingPositionChange: recordReadingPosition,
                onReadingPositionCommit: commitReadingPosition,
                onPreviewAttachment: { _, _ in },
                onPreviewTranscriptMedia: { _ in },
                onToggleListening: { _ in },
                onSubmitClarification: { _ in },
                onSelectText: { _ in },
                onRegenerate: { _ in },
                onEdit: { _ in },
                onFork: { _ in },
                onCopy: { _ in },
                hidesTranscriptMessageAccessibility: true
            )

            HStack(alignment: .bottom, spacing: 8) {
                ComposerTextInputView(
                    text: $draftText,
                    isFocused: $isComposerFocused,
                    inputHeight: $composerInputHeight,
                    measuredHeight: $measuredComposerHeight,
                    isDisabled: false,
                    isKeyboardSendEnabled: activeStreamID == nil,
                    verticalPadding: 10,
                    onKeyboardSend: sendDraftMessage,
                    onPasteFileProviders: { _ in },
                    onPasteFileURLs: { _ in },
                    onPasteImageProviders: { _ in },
                    onPasteImages: { _ in }
                )
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .accessibilityIdentifier("scroll-lab-composer")

                Button(action: sendDraftMessage) {
                    Image(systemName: "arrow.up")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(
                    draftText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                        || activeStreamID != nil
                )
                .accessibilityLabel("Send simulated message")
                .accessibilityIdentifier("scroll-lab-send")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .zIndex(1)
        }
        .navigationTitle("Deterministic Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .topLeading) {
            Text(positionProbeValue)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Scroll position")
                .accessibilityValue(positionProbeValue)
                .accessibilityIdentifier("scroll-position-probe")
        }
        .overlay(alignment: .topTrailing) {
            Text(isComposerFocused ? "focused" : "unfocused")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Composer focus")
                .accessibilityValue(isComposerFocused ? "focused" : "unfocused")
                .accessibilityIdentifier("scroll-lab-composer-focus-probe")
        }
        .overlay(alignment: .top) {
            Text("messages-\(messages.count)")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Transcript message count")
                .accessibilityValue("messages-\(messages.count)")
                .accessibilityIdentifier("scroll-lab-message-count-probe")
        }
        .overlay(alignment: .topTrailing) {
            Text(responseStatus)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Simulated response")
                .accessibilityValue(responseStatus)
                .accessibilityIdentifier("scroll-lab-response-probe")
        }
        .overlay(alignment: .topLeading) {
            Text("older-loads-\(olderMessageLoadCount)")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Older transcript loads")
                .accessibilityValue("older-loads-\(olderMessageLoadCount)")
                .accessibilityIdentifier("scroll-lab-older-load-count-probe")
        }
        .overlay(alignment: .top) {
            Text(scrollStateProbeValue)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Transcript scroll state")
                .accessibilityValue(scrollStateProbeValue)
                .accessibilityIdentifier("scroll-lab-state-probe")
        }
        .overlay(alignment: .bottomLeading) {
            Text("targeted-loads-\(targetedWindowLoadCount)")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Targeted restoration loads")
                .accessibilityValue(
                    "targeted-loads-\(targetedWindowLoadCount)"
                )
                .accessibilityIdentifier(
                    "scroll-lab-targeted-load-count-probe"
                )
        }
        .overlay(alignment: .leading) {
            Text(
                didExposeUnrelatedLatestTail
                    ? "tail-flash-1"
                    : "tail-flash-0"
            )
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Unrelated latest tail exposure")
                .accessibilityValue(
                    didExposeUnrelatedLatestTail
                        ? "tail-flash-1"
                        : "tail-flash-0"
                )
                .accessibilityIdentifier(
                    "scroll-lab-tail-flash-probe"
                )
        }
        .overlay(alignment: .trailing) {
            Text("latest-loads-\(latestWindowLoadCount)")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Latest transcript loads")
                .accessibilityValue(
                    "latest-loads-\(latestWindowLoadCount)"
                )
                .accessibilityIdentifier(
                    "scroll-lab-latest-load-count-probe"
                )
        }
        .overlay(alignment: .trailing) {
            Text(
                latestArrivedWhileTargetPending
                    && isLoadingMessages
                    && messages.isEmpty
                    ? "latest-before-target-pending"
                    : latestArrivedWhileTargetPending
                        ? "latest-before-target-complete"
                        : "latest-before-target-waiting"
            )
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Latest arrived before saved window")
                .accessibilityValue(
                    latestArrivedWhileTargetPending
                        && isLoadingMessages
                        && messages.isEmpty
                        ? "latest-before-target-pending"
                        : latestArrivedWhileTargetPending
                            ? "latest-before-target-complete"
                            : "latest-before-target-waiting"
                )
                .accessibilityIdentifier(
                    "scroll-lab-latest-before-target-probe"
                )
        }
        .overlay(alignment: .bottomTrailing) {
            Text(initialResolutionProbeValue)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Initial scroll resolution")
                .accessibilityValue(initialResolutionProbeValue)
                .accessibilityIdentifier(
                    "scroll-lab-initial-resolution-probe"
                )
        }
        .overlay(alignment: .bottom) {
            Text(
                didApplyDelayedFallbackLayout
                    ? "layout-expanded"
                    : "layout-compact"
            )
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Delayed transcript layout")
                .accessibilityValue(
                    didApplyDelayedFallbackLayout
                        ? "layout-expanded"
                        : "layout-compact"
                )
                .accessibilityIdentifier(
                    "scroll-lab-delayed-layout-probe"
                )
        }
        .task {
            await loadTargetedHistoricalWindowIfNeeded()
        }
        .onChange(of: messages) { _, messages in
            if messages.contains(where: {
                $0.messageId?.hasPrefix("scroll-lab-latest-") == true
            }) {
                didExposeUnrelatedLatestTail = true
            }
        }
        .onDisappear {
            responseTask?.cancel()
            responseTask = nil
            delayedLayoutTask?.cancel()
            delayedLayoutTask = nil
            isComposerFocused = false
            commitReadingPosition()
        }
    }

    private var positionProbeValue: String {
        guard let committedPosition else {
            return "\(restorationStatus)|none"
        }

        return [
            restorationStatus,
            committedPosition.renderID,
            committedPosition.messageID ?? "legacy",
            String(format: "%.3f", committedPosition.offsetFromRowTop),
        ].joined(separator: "|")
    }

    private var initialResolutionProbeValue: String {
        switch initialResolution {
        case .restored:
            return "restored"
        case .missingAnchorFallback:
            return "missing-anchor-fallback"
        case .cancelledByUser:
            return "cancelled-by-user"
        case nil:
            return "pending"
        }
    }

    private var scrollStateProbeValue: String {
        let distance = latestDistanceFromBottom.map {
            String(format: "%.3f", $0)
        } ?? "none"
        return [
            isNearBottom ? "near" : "away",
            shouldFollowLatest ? "follow" : "read",
            isUserInteractingWithScroll ? "interacting" : "idle",
            "distance-\(distance)",
            initialPosition == nil ? "resolved" : "restoring",
        ].joined(separator: "|")
    }

    @MainActor
    private func loadTargetedHistoricalWindowIfNeeded() async {
        guard targetedHistoricalRestoration,
              targetedWindowLoadCount == 0 else {
            return
        }

        targetedWindowLoadCount += 1
        async let latestLoad: Void =
            loadRetainedLatestWindowForTargetedRestoration()
        // Keep the vulnerable interval observable to XCUITest instead of
        // completing both synthetic responses between accessibility snapshots.
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        guard !Task.isCancelled else { return }

        messages = ScrollRestorationLabFixture.targetedHistoricalMessages
        messageOffset =
            ScrollRestorationLabFixture.targetedHistoricalMessageOffset
        isLoadingMessages = false
        _ = await latestLoad
    }

    @MainActor
    private func loadRetainedLatestWindowForTargetedRestoration() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard !Task.isCancelled else { return }

        retainedLatestMessages =
            ScrollRestorationLabFixture.targetedLatestMessages
        latestWindowLoadCount += 1
        if isLoadingMessages && messages.isEmpty {
            latestArrivedWhileTargetPending = true
        }
    }

    private func updateScrollMetrics(_ metrics: ChatScrollMetrics) {
        latestDistanceFromBottom = metrics.distanceFromBottom
        if initialPosition != nil {
            latestMetrics = metrics
            return
        }
        applyResolvedMetrics(metrics)
    }

    private func applyResolvedMetrics(_ metrics: ChatScrollMetrics) {
        let wasUserInteracting = isUserInteractingWithScroll
        let nearBottom = ChatScrollPolicy.isNearBottom(
            distanceFromBottom: metrics.distanceFromBottom,
            isStreaming: activeStreamID != nil
        )
        if isNearBottom != nearBottom {
            isNearBottom = nearBottom
        }
        if wasUserInteracting != metrics.isUserInteracting {
            isUserInteractingWithScroll = metrics.isUserInteracting
            userScrollCooldownUntil = ChatScrollPolicy.cooldownDeadline()
        }

        if nearBottom {
            if !shouldFollowLatest {
                shouldFollowLatest = true
            }
            if isReadingOlderTranscript {
                withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
                    isReadingOlderTranscript = false
                }
            }
        } else if metrics.isUserInteracting {
            if shouldFollowLatest {
                shouldFollowLatest = false
            }
            if !isReadingOlderTranscript,
               ChatScrollPolicy.shouldEnterReadingOlder(
                   distanceFromBottom: metrics.distanceFromBottom,
                   isStreaming: activeStreamID != nil
               ) {
                withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
                    isReadingOlderTranscript = true
                }
            }
        }
    }

    private func completeInitialRestoration(
        _ resolution: ChatTranscriptInitialScrollResolution
    ) {
        initialResolution = resolution
        initialPosition = nil
        if resolution == .missingAnchorFallback {
            self.latestMetrics = nil
            shouldFollowLatest = true
            isReadingOlderTranscript = false
            isNearBottom = true
            if fallbackWindowSwap {
                messages =
                    ScrollRestorationLabFixture.fallbackLatestMessages
                messageOffset =
                    ScrollRestorationLabFixture
                        .fallbackLatestMessageOffset
            }
            scheduleDelayedFallbackLayoutIfNeeded()
        } else if let latestMetrics {
            self.latestMetrics = nil
            applyResolvedMetrics(latestMetrics)
        }
        restorationStatus = "ready"
        commitReadingPosition()
    }

    private func scheduleDelayedFallbackLayoutIfNeeded() {
        guard delayedFallbackLayout,
              !didApplyDelayedFallbackLayout,
              delayedLayoutTask == nil else {
            return
        }

        delayedLayoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled,
                  let lastIndex = messages.indices.last else {
                return
            }

            let existing = messages[lastIndex]
            let expansion = (0..<18).map { paragraph in
                """
                Delayed layout paragraph \(paragraph): this simulates a rich
                Markdown or media row expanding after fallback initially
                reached the bounded transcript's end.
                """
            }.joined(separator: "\n\n")
            messages[lastIndex] = ChatMessage(
                role: existing.role,
                content: (existing.content ?? "") + "\n\n" + expansion,
                timestamp: existing.timestamp,
                messageId: existing.messageId
            )
            didApplyDelayedFallbackLayout = true
            delayedLayoutTask = nil
        }
    }

    private func recordReadingPosition(_ position: ChatTranscriptScrollPosition?) {
        positionRecorder.record(position)
    }

    private func commitReadingPosition() {
        positionRecorder.flush()
        if committedPosition != positionRecorder.latestPosition {
            committedPosition = positionRecorder.latestPosition
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        scrollToLatestContent(
            proxy,
            animated: activeStreamID == nil,
            isUserInitiated: true
        )
    }

    private func scrollToLatestTranscriptMessage(
        _ proxy: ScrollViewProxy,
        animated: Bool = true,
        isUserInitiated: Bool = false
    ) {
        guard !messages.isEmpty else { return }

        scheduleFollowScroll(
            proxy,
            targetID: "transcript:\(messageOffset + messages.count - 1)",
            anchor: .bottom,
            animated: animated,
            isUserInitiated: isUserInitiated
        )
    }

    private func scrollToLatestContent(
        _ proxy: ScrollViewProxy,
        animated: Bool = true,
        isUserInitiated: Bool = false
    ) {
        guard !messages.isEmpty else { return }

        scheduleFollowScroll(
            proxy,
            targetID: ScrollRestorationLabFixture.bottomAnchorID,
            anchor: .bottom,
            animated: animated,
            isUserInitiated: isUserInitiated
        )
    }

    private func scheduleFollowScroll(
        _ proxy: ScrollViewProxy,
        targetID: String,
        anchor: UnitPoint,
        animated: Bool,
        isUserInitiated: Bool
    ) {
        if !isUserInitiated, isAutoFollowScrollPaused {
            return
        }

        if isUserInitiated {
            userScrollCooldownUntil = nil
        }

        shouldFollowLatest = true
        isReadingOlderTranscript = false
        followScrollGeneration += 1
        let generation = followScrollGeneration

        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled,
                  generation == followScrollGeneration else {
                return
            }
            if !isUserInitiated, isAutoFollowScrollPaused {
                return
            }

            if animated {
                let animation = activeStreamID != nil
                    ? ChatMotion.streamingFollow(reduceMotion: reduceMotion)
                    : ChatMotion.scrollToLatest(reduceMotion: reduceMotion)
                withAnimation(animation) {
                    proxy.scrollTo(targetID, anchor: anchor)
                }
            } else {
                proxy.scrollTo(targetID, anchor: anchor)
            }
        }
    }

    private var isAutoFollowScrollPaused: Bool {
        ChatScrollPolicy.isAutoScrollPaused(
            isUserInteracting: isUserInteractingWithScroll,
            cooldownUntil: userScrollCooldownUntil
        )
    }

    private func prepareTranscriptForExplicitSend() {
        shouldFollowLatest = true
        userScrollCooldownUntil = nil
        if isReadingOlderTranscript {
            withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
                isReadingOlderTranscript = false
            }
        }
    }

    private func sendDraftMessage() {
        let submittedDraft = draftText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedDraft.isEmpty, activeStreamID == nil else {
            return
        }

        let shouldRestoreFocusAfterSend = isComposerFocused
        prepareTranscriptForExplicitSend()
        draftText = ""
        responseStatus = "streaming"
        activeStreamID = "deterministic-stream"
        messages.append(
            ChatMessage(
                role: "user",
                content: submittedDraft,
                timestamp: Double(messageOffset + messages.count),
                messageId: "bounded-completion-user"
            )
        )
        streamingScrollTrigger += 1

        if shouldRestoreFocusAfterSend {
            Task { @MainActor in
                await Task.yield()
                guard activeStreamID != nil else { return }
                isComposerFocused = true
            }
        }

        responseTask?.cancel()
        responseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }

            messages.append(
                ChatMessage(
                    role: "assistant",
                    content: """
                    Bounded completion answer

                    The simulated assistant response contains **Markdown**, a
                    short ordered sequence, and enough wrapping content to
                    change the latest row's measured height while the keyboard
                    remains active.

                    1. Stream the latest response.
                    2. Reconcile the authoritative bounded tail.
                    3. Preserve keyboard focus and reader gestures.

                    `follow-latest` remains owned by the app until a real swipe.
                    """,
                    timestamp: Double(messageOffset + messages.count),
                    messageId: "bounded-completion-assistant"
                )
            )
            streamingScrollTrigger += 1

            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }

            let droppedMessageCount = max(
                0,
                messages.count - ScrollRestorationLabFixture.boundedMessageCount
            )
            messages = Array(messages.dropFirst(droppedMessageCount))
            messageOffset += droppedMessageCount
            streamingScrollTrigger += 1
            activeStreamID = nil
            responseStatus = "complete"
            responseTask = nil
        }
    }
}
#endif
