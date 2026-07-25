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
                ScrollRestorationLabTranscriptView()
                    .id(openGeneration)
            }
        }
    }
}

private enum ScrollRestorationLabFixture {
    static let server = URL(string: "https://scroll-restoration-lab.invalid")!
    static let sessionID = "deterministic-transcript"
    static let bottomAnchorID = "scroll-restoration-lab-bottom"

    static let messages: [ChatMessage] = (0..<18).map { index in
        let role = index.isMultiple(of: 2) ? "user" : "assistant"
        let repeatedDetail = (0..<2)
            .map { paragraph in
                "Message \(index), paragraph \(paragraph): deterministic viewport content for exact restoration."
            }
            .joined(separator: "\n\n")

        return ChatMessage(
            role: role,
            content: "\(role.capitalized) message \(index)\n\n\(repeatedDetail)",
            timestamp: Double(index),
            messageId: nil
        )
    }

    static let transcriptMessages = ChatViewModel.transcriptMessages(from: messages)
}

private struct ScrollRestorationLabTranscriptView: View {
    @State private var initialPosition: ChatTranscriptScrollPosition?
    @State private var committedPosition: ChatTranscriptScrollPosition?
    @State private var positionRecorder: ChatTranscriptScrollPositionRecorder
    @State private var latestMetrics: ChatScrollMetrics?
    @State private var shouldFollowLatest: Bool
    @State private var isNearBottom: Bool
    @State private var restorationStatus = "pending"

    init() {
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
    }

    var body: some View {
        ChatTranscriptView(
            isLoading: false,
            errorMessage: nil,
            messages: ScrollRestorationLabFixture.messages,
            displayedTranscriptMessages: ScrollRestorationLabFixture.transcriptMessages,
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
            latestTranscriptMessageRole: ScrollRestorationLabFixture.messages.last?.role,
            isScrolledNearBottom: isNearBottom,
            activeStreamID: nil,
            streamingScrollTrigger: 0,
            cacheFirstReconcileScrollToken: 0,
            bottomAnchorID: ScrollRestorationLabFixture.bottomAnchorID,
            transcriptMessageSpacing: 10,
            transcriptBlockSpacing: 6,
            transcriptBottomInsetHeight: 104,
            scrollToBottomButtonBottomPadding: 12,
            localAttachmentPreviews: [:],
            listeningMessageID: nil,
            isViewingCachedData: false,
            hasOlderMessages: false,
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
            onLoadOlderMessages: { false },
            onUpdateScrollMetrics: updateScrollMetrics,
            onDismissKeyboard: {},
            onScrollToBottom: scrollToBottom,
            onScrollToLatestTranscriptMessage: scrollToBottom,
            onScrollToLatestContent: { proxy, _ in
                scrollToBottom(proxy)
            },
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
            onCopy: { _ in }
        )
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
        .onDisappear {
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

    private func updateScrollMetrics(_ metrics: ChatScrollMetrics) {
        if initialPosition != nil {
            latestMetrics = metrics
            return
        }
        applyResolvedMetrics(metrics)
    }

    private func applyResolvedMetrics(_ metrics: ChatScrollMetrics) {
        let nearBottom = ChatScrollPolicy.isNearBottom(
            distanceFromBottom: metrics.distanceFromBottom,
            isStreaming: false
        )
        if isNearBottom != nearBottom {
            isNearBottom = nearBottom
        }

        if nearBottom, !shouldFollowLatest {
            shouldFollowLatest = true
        } else if !nearBottom, metrics.isUserInteracting, shouldFollowLatest {
            shouldFollowLatest = false
        }
    }

    private func completeInitialRestoration(_: Bool) {
        initialPosition = nil
        if let latestMetrics {
            self.latestMetrics = nil
            applyResolvedMetrics(latestMetrics)
        }
        restorationStatus = "ready"
        commitReadingPosition()
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
        shouldFollowLatest = true
        proxy.scrollTo(
            ScrollRestorationLabFixture.bottomAnchorID,
            anchor: .bottom
        )
    }
}
#endif
