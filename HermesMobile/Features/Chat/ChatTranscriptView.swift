import SwiftUI
import UIKit

struct ChatTranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewportCache = ChatTranscriptViewportCache()
    @State private var viewportController = ChatScrollViewportController()
    @State private var hasCompletedInitialScrollResolution = false
    @State private var isApplyingInitialRestoration = false
    @State private var measuredRowRenderID: String?
    @State private var restorationLock: ChatTranscriptRestorationLock?
    @State private var restorationVerificationGeneration = 0
    @State private var restorationVerificationStartedAt: Date?
    @State private var restorationLockReleaseGeneration = 0
    @State private var pendingFollowLatestAfterInitialRestoration = false
    @State private var hasRevealedWhileAwaitingSavedRowFrame = false

    let isLoading: Bool
    let errorMessage: String?
    let messages: [ChatMessage]
    let displayedTranscriptMessages: [TranscriptMessage]
    let initialScrollPosition: ChatTranscriptScrollPosition?
    let compressionReferenceCard: CompressionReferenceCard?
    let reasoningGroups: [ReasoningGroup]
    let completedToolCallGroupsForAnchor: (String?) -> [ToolCallGroup]
    let liveReasoningText: String
    let reasoningAnchorMessageID: String?
    let liveToolCalls: [ToolCall]
    let toolCallAnchorMessageID: String?
    let streamingAssistantMessageID: String?
    let activeStreamRecoveryState: ActiveStreamRecoveryState
    let clarificationPrompt: ClarificationPromptState?
    let isRespondingToClarification: Bool
    let clarificationErrorMessage: String?
    let hidesRunStatusAccessibility: Bool
    let showsThinkingAndToolCards: Bool
    let showsAssistantTypingIndicator: Bool
    let showsScrollToBottomButton: Bool
    let shouldFollowLatestMessage: Bool
    let latestTranscriptMessageRole: String?
    let isScrolledNearBottom: Bool
    let activeStreamID: String?
    let streamingScrollTrigger: Int
    let cacheFirstReconcileScrollToken: Int
    let bottomAnchorID: String
    let transcriptMessageSpacing: CGFloat
    let transcriptBlockSpacing: CGFloat
    let transcriptBottomInsetHeight: CGFloat
    let scrollToBottomButtonBottomPadding: CGFloat
    let localAttachmentPreviews: [String: [String: Data]]
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasOlderMessages: Bool
    let isLoadingOlderMessages: Bool
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let loadAttachmentImage: (String) async -> Data?
    let loadAttachmentData: (String) async -> Data?
    let loadTranscriptMediaImage: (TranscriptMediaReference) async -> Data?
    let loadTranscriptMediaData: (TranscriptMediaReference) async -> Data?
    let transcriptMediaCacheNamespace: String
    let actionContext: (ChatMessage, Int) -> MessageActionContext?
    let shouldRenderMessageRow: (ChatMessage) -> Bool
    let onLoadMessages: () async -> Void
    let onLoadOlderMessages: () async -> Bool
    let onUpdateScrollMetrics: (ChatScrollMetrics) -> Void
    let onDismissKeyboard: () -> Void
    let onScrollToBottom: (ScrollViewProxy) -> Void
    let onScrollToLatestTranscriptMessage: (ScrollViewProxy) -> Void
    let onScrollToLatestContent: (ScrollViewProxy, Bool) -> Void
    let onCancelInitialRestoration: () -> Void
    let onInitialScrollPositionResolution: (
        ChatTranscriptInitialScrollResolution
    ) -> Void
    let onReadingPositionChange: (ChatTranscriptScrollPosition?) -> Void
    let onReadingPositionCommit: () -> Void
    let onPreviewAttachment: (MessageAttachment, Data?) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onSubmitClarification: (String) -> Void
    let onSelectText: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void
    /// Non-nil shows the inline "Commit & Push" button under the latest assistant turn
    /// (issue #315, Slice C, surface B). Nil hides it (non-git chats, no changes, etc.).
    var inlineCommitContext: ChatInlineCommitContext? = nil
    var onInlineCommit: () -> Void = {}
    /// Non-nil shows the turn-end "File changes" recap card under the latest assistant turn
    /// (issue #316, Slice D, surface B). Nil hides it (non-git chats, no changes, streaming).
    var turnChangesSummary: TurnFileChangeSummary? = nil
    var onOpenTurnDiff: () -> Void = {}
    var onOpenTurnFileDiff: (GitFile) -> Void = { _ in }
    /// Test-fixture escape hatch; production keeps every transcript row accessible.
    var hidesTranscriptMessageAccessibility = false

    var body: some View {
        if isLoading && messages.isEmpty && clarificationPrompt == nil {
            ChatTranscriptLoadingSkeletonView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, messages.isEmpty, clarificationPrompt == nil {
            ContentUnavailableView {
                Label("Could Not Load Messages", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await onLoadMessages() }
                }
            }
        } else if messages.isEmpty && clarificationPrompt == nil {
            ContentUnavailableView {
                Image(systemName: "bubble.left.and.bubble.right")
            } description: {
                Text("Send a message to start the conversation.")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onDismissKeyboard()
            }
        } else {
            transcriptScrollView
        }
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                let viewportWidth = max(0, viewport.size.width)
                let contentWidth = transcriptContentWidth(for: viewportWidth)

                ZStack(alignment: .bottom) {
                    ScrollView {
                        transcriptScrollContent(
                            proxy: proxy,
                            viewportWidth: viewportWidth,
                            contentWidth: contentWidth
                        )
                    }
                    .defaultScrollAnchor(
                        ChatScrollPolicy.initialTranscriptAnchor,
                        for: .initialOffset
                    )
                    .onScrollTargetVisibilityChange(
                        idType: String.self,
                        threshold: 0.01
                    ) { renderIDs in
                        handleVisibleRenderIDsChange(renderIDs)
                    }
                    .onScrollPhaseChange { _, newPhase in
                        handleScrollPhaseChange(newPhase)
                    }
                    .frame(width: viewportWidth)
                    .refreshable {
                        if hasOlderMessages {
                            await loadOlderMessagesPreservingPosition(proxy: proxy)
                        } else {
                            await onLoadMessages()
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear
                            .frame(height: transcriptBottomInsetHeight)
                            .accessibilityHidden(true)
                    }
                    // The navigation root supplies a gradual soft top edge;
                    // retain the softer fade only around the bottom composer.
                    .adaptiveSoftScrollEdges(.bottom)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            guard clarificationPrompt == nil else { return }
                            onDismissKeyboard()
                        }
                    )

                    if showsScrollToBottomButton {
                        ChatScrollToBottomButton(
                            bottomPadding: scrollToBottomButtonBottomPadding,
                            onTap: {
                                releaseRestorationLockForProgrammaticScroll()
                                onScrollToBottom(proxy)
                            }
                        )
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                    }
                }
                .opacity(hidesTranscriptForInitialRestoration ? 0 : 1)
                .accessibilityIdentifier("chat-transcript-viewport")
                .overlay {
                    if hidesTranscriptForInitialRestoration {
                        ProgressView()
                            .accessibilityLabel("Restoring conversation position")
                    }
                }
                .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsScrollToBottomButton)
                .background(Color(.systemBackground))
                .onAppear {
                    resolveInitialScrollPositionIfReady()
                }
                .onChange(of: initialScrollPosition) {
                    handleInitialScrollPositionReplacement()
                }
                .onDisappear {
                    commitPendingReadingPosition()
                }
                .onChange(of: isLoading) { _, isLoading in
                    if isLoading {
                        resolveInitialScrollPositionIfReady()
                    } else if hasCompletedInitialScrollResolution {
                        scheduleRestorationLockReleaseIfReady()
                    } else {
                        resolveInitialScrollPositionIfReady()
                    }
                }
                .onPreferenceChange(ChatTranscriptRowFramesPreferenceKey.self) { frames in
                    handleRowContentFramesChange(frames)
                }
                .onChange(of: measuredRowRenderID) { _, renderID in
                    guard let renderID,
                          !hasCompletedInitialScrollResolution,
                          case .saved(let position) = restorationLock,
                          displayedTranscriptRenderID(for: position) == renderID
                    else {
                        return
                    }

                    // Give a distant saved row one coarse, non-animated
                    // materialization pass before applying its exact pixel
                    // offset. The exact verifier remains authoritative.
                    Task { @MainActor in
                        await Task.yield()
                        guard !hasCompletedInitialScrollResolution,
                              measuredRowRenderID == renderID,
                              case .saved(let currentPosition) = restorationLock,
                              displayedTranscriptRenderID(
                                  for: currentPosition
                              ) == renderID,
                              ChatTranscriptReadingPositionResolver.matchingFrame(
                                  for: currentPosition,
                                  frames: rowContentFrames
                              ) == nil else {
                            return
                        }
                        // SCROLLTRACE
                        ChatScrollTrace.log("scrollTo.coarseAnchor row=\(renderID)")
                        proxy.scrollTo(renderID, anchor: .top)
                    }
                }
                .onChange(of: messages.count) { oldCount, newCount in
                    // SCROLLTRACE
                    ChatScrollTrace.log(
                        "messages.countChanged \(oldCount)->\(newCount) follow=\(shouldFollowLatestMessage) lock=\(restorationLock != nil)"
                    )
                    guard shouldFollowLatestMessage else { return }
                    if restorationLock?.preservesStoredPosition != true {
                        markFollowLatestReadingPositionChange()
                    }

                    if latestTranscriptMessageRole == "user" {
                        onScrollToLatestTranscriptMessage(proxy)
                    } else {
                        onScrollToLatestContent(proxy, true)
                    }
                }
                .onChange(of: streamingScrollTrigger) {
                    // SCROLLTRACE
                    ChatScrollTrace.log(
                        "scrollTo.streamingTrigger follow=\(shouldFollowLatestMessage)"
                    )
                    if shouldFollowLatestMessage {
                        onScrollToLatestContent(proxy, true)
                    }
                }
                .onChange(of: cacheFirstReconcileScrollToken) {
                    // SCROLLTRACE
                    ChatScrollTrace.log(
                        "scrollTo.cacheFirstReconcile follow=\(shouldFollowLatestMessage)"
                    )
                    // Cache-first reconcile (#289): the server transcript just replaced
                    // the lighter cached render, so snap back to the bottom (no
                    // animation) unless the reader has scrolled away in the meantime.
                    guard shouldFollowLatestMessage else { return }
                    markFollowLatestReadingPositionChange()
                    onScrollToLatestContent(proxy, false)
                }
                .onChange(of: shouldFollowLatestMessage) { _, shouldFollow in
                    // SCROLLTRACE
                    ChatScrollTrace.log(
                        "followLatest.changed follow=\(shouldFollow) completed=\(hasCompletedInitialScrollResolution) lock=\(String(describing: restorationLock))"
                    )
                    guard hasCompletedInitialScrollResolution else {
                        pendingFollowLatestAfterInitialRestoration = shouldFollow
                        if shouldFollow {
                            cancelInitialRestorationForUserIntent()
                        }
                        return
                    }

                    pendingFollowLatestAfterInitialRestoration = false
                    guard shouldFollow else { return }
                    if restorationLock?.preservesStoredPosition == true {
                        // The missing saved row resolved to the bounded
                        // window's true end. Reissue that transition through
                        // ScrollViewProxy after the parent adopts follow-latest
                        // state so late LazyVStack layout cannot strand the
                        // revealed viewport above the bottom. Do not register
                        // this fallback as reader intent: the unavailable
                        // saved position must remain eligible for a later
                        // authoritative response.
                        onScrollToLatestContent(proxy, false)
                        return
                    }
                    releaseRestorationLockForProgrammaticScroll()
                }
                .onChange(of: clarificationPrompt?.id) {
                    guard clarificationPrompt != nil, shouldFollowLatestMessage else { return }
                    markFollowLatestReadingPositionChange()
                    onScrollToBottom(proxy)
                }
                .onChange(of: activeStreamID) { previousStreamID, newStreamID in
                    guard previousStreamID != nil,
                          newStreamID == nil,
                          shouldFollowLatestMessage else {
                        return
                    }
                    markFollowLatestReadingPositionChange()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    cancelInitialRestorationForUserIntent()
                    if isScrolledNearBottom {
                        onScrollToBottom(proxy)
                    }
                }
            }
        }
    }

    private func transcriptScrollContent(
        proxy: ScrollViewProxy,
        viewportWidth: CGFloat,
        contentWidth: CGFloat
    ) -> some View {
        VStack(spacing: transcriptMessageSpacing) {
            olderMessagesButton(proxy: proxy)

            if let compressionReferenceCard, compressionReferenceCard.afterRenderID == nil {
                compressionReferenceCardView(compressionReferenceCard)
            }

            ForEach(displayedTranscriptMessages) { transcriptMessage in
                // Scope live-streaming state to the row that actually displays it.
                // Non-anchor / non-streaming rows receive stable empty/nil values so
                // their inputs don't change on every ~16ms flush; combined with the
                // `.equatable()` wrapper below, SwiftUI then skips re-evaluating their
                // (markdown-heavy) bodies while a response streams in.
                let isReasoningAnchor = reasoningAnchorMessageID == transcriptMessage.anchorID
                let isToolCallAnchor = toolCallAnchorMessageID == transcriptMessage.anchorID
                let isStreamingRow = streamingAssistantMessageID != nil
                    && transcriptMessage.message.messageId == streamingAssistantMessageID

                ChatTranscriptMessageBlock(
                    transcriptMessage: transcriptMessage,
                    transcriptBlockSpacing: transcriptBlockSpacing,
                    showsThinkingAndToolCards: showsThinkingAndToolCards,
                    reasoningGroups: reasoningGroups,
                    toolCallGroups: completedToolCallGroupsForAnchor(transcriptMessage.anchorID),
                    liveReasoningText: isReasoningAnchor ? liveReasoningText : "",
                    reasoningAnchorMessageID: isReasoningAnchor ? reasoningAnchorMessageID : nil,
                    liveToolCalls: isToolCallAnchor ? liveToolCalls : [],
                    toolCallAnchorMessageID: isToolCallAnchor ? toolCallAnchorMessageID : nil,
                    streamingAssistantMessageID: isStreamingRow ? streamingAssistantMessageID : nil,
                    localAttachmentPreviews: localAttachmentPreviews[transcriptMessage.message.id],
                    listeningMessageID: listeningMessageID,
                    isViewingCachedData: isViewingCachedData,
                    hasActiveStream: activeStreamID != nil,
                    isRegeneratingMessage: isRegeneratingMessage,
                    isEditingMessage: isEditingMessage,
                    isForkingMessage: isForkingMessage,
                    loadAttachmentImage: loadAttachmentImage,
                    loadAttachmentData: loadAttachmentData,
                    loadTranscriptMediaImage: loadTranscriptMediaImage,
                    loadTranscriptMediaData: loadTranscriptMediaData,
                    transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
                    actionContext: actionContext,
                    shouldRenderMessageRow: shouldRenderMessageRow,
                    hidesTranscriptMessageAccessibility: hidesTranscriptMessageAccessibility,
                    onPreviewAttachment: onPreviewAttachment,
                    onPreviewTranscriptMedia: onPreviewTranscriptMedia,
                    onToggleListening: onToggleListening,
                    onSelectText: onSelectText,
                    onRegenerate: onRegenerate,
                    onEdit: onEdit,
                    onFork: onFork,
                    onCopy: onCopy
                )
                .equatable()
                .id(transcriptMessage.renderID)
                .background {
                    if measuredRowRenderID == transcriptMessage.renderID {
                        GeometryReader { geometry in
                            let frame = geometry.frame(
                                in: .named(
                                    ChatTranscriptContentCoordinateSpace.name
                                )
                            )
                            Color.clear.preference(
                                key: ChatTranscriptRowFramesPreferenceKey.self,
                                value: [
                                    ChatTranscriptRowContentFrame(
                                        renderID: transcriptMessage.renderID,
                                        messageID: transcriptMessage
                                            .persistenceMessageID,
                                        minY: frame.minY,
                                        maxY: frame.maxY
                                    )
                                ]
                            )
                        }
                    }
                }

                if let compressionReferenceCard,
                   compressionReferenceCard.afterRenderID == transcriptMessage.renderID {
                    compressionReferenceCardView(compressionReferenceCard)
                }
            }

            transcriptLooseBlocks
            liveResponseBlocks
            inlineClarificationCard
            typingIndicator
            turnChangesCard
            inlineCommitButton

            Color.clear
                .frame(height: 1)
                .id(bottomAnchorID)
                .allowsHitTesting(false)
        }
        .scrollTargetLayout()
        .padding(.top, 16)
        .frame(width: contentWidth, alignment: .leading)
        .padding(.horizontal, transcriptHorizontalPadding)
        .frame(width: viewportWidth, alignment: .leading)
        .clipped()
        .coordinateSpace(name: ChatTranscriptContentCoordinateSpace.name)
        .background {
            ZStack {
                ChatScrollObserver(
                    isStreaming: activeStreamID != nil,
                    viewportController: viewportController,
                    onMetrics: onUpdateScrollMetrics
                )

                ChatVerticalScrollAxisGuard()
            }
            .accessibilityHidden(true)
        }
    }

    private func handleRowContentFramesChange(
        _ frames: [ChatTranscriptRowContentFrame]
    ) {
        guard let measuredRowRenderID,
              let frame = frames.last(where: {
                  $0.renderID == measuredRowRenderID
              }) else {
            return
        }

        // SCROLLTRACE
        if viewportCache.rowContentFrames.first != frame {
            ChatScrollTrace.log(
                "frames.measured row=\(frame.renderID) minY=\(String(format: "%.1f", frame.minY)) maxY=\(String(format: "%.1f", frame.maxY)) completed=\(hasCompletedInitialScrollResolution) lock=\(restorationLock != nil)"
            )
        }
        viewportCache.rowContentFrames = [frame]
        refreshLatestScrollGeometry()
        if hasCompletedInitialScrollResolution {
            if restorationLock != nil {
                maintainCompletedRestorationLock()
                scheduleRestorationLockReleaseIfReady()
            } else {
                scheduleReadingPositionCommitIfNeeded()
            }
            return
        }

        resolveInitialScrollPositionIfReady(frames: [frame])
    }

    private func handleVisibleRenderIDsChange(_ renderIDs: [String]) {
        // Visibility callbacks can fire for every row boundary crossed during a
        // fling. Keep the values non-observable and select one row only after
        // the scroll phase reports idle.
        viewportCache.visibleRenderIDs = renderIDs
    }

    private func handleScrollPhaseChange(_ phase: ScrollPhase) {
        viewportCache.isScrollIdle = phase == .idle
        refreshLatestScrollGeometry()

        if phase == .tracking || phase == .interacting {
            cancelPendingReadingPositionCommit()
            releaseRestorationLockForUserScroll()
            return
        }

        guard phase == .idle else { return }
        if hasCompletedInitialScrollResolution {
            requestLeadingVisibleRowMeasurement()
            scheduleReadingPositionCommitIfNeeded()
        } else {
            resolveInitialScrollPositionIfReady()
        }
    }

    private func refreshLatestScrollGeometry() {
        guard let snapshot = viewportController.currentSnapshot() else { return }
        viewportCache.latestScrollGeometry = ChatTranscriptScrollGeometrySnapshot(
            visibleContentOffsetY: snapshot.visibleContentOffsetY,
            contentHeight: snapshot.contentHeight,
            visibleContainerHeight: snapshot.visibleContainerHeight,
            topContentInset: snapshot.topContentInset
        )
    }

    private func requestLeadingVisibleRowMeasurement() {
        guard restorationLock == nil else { return }
        let visibleRenderIDs = Set(viewportCache.visibleRenderIDs)
        let leadingRenderID = displayedTranscriptMessages.first(where: {
            visibleRenderIDs.contains($0.renderID)
        })?.renderID
            ?? (isScrolledNearBottom
                ? displayedTranscriptMessages.last?.renderID
                : nil)
        guard let leadingRenderID else { return }
        selectMeasuredRow(leadingRenderID)
    }

    private func selectMeasuredRow(_ renderID: String?) {
        guard measuredRowRenderID != renderID else { return }
        viewportCache.rowContentFrames = []
        measuredRowRenderID = renderID
    }

    private var latestScrollGeometry: ChatTranscriptScrollGeometrySnapshot? {
        viewportCache.latestScrollGeometry
    }

    private var rowContentFrames: [ChatTranscriptRowContentFrame] {
        viewportCache.rowContentFrames
    }

    @discardableResult
    private func publishLatestReadingPosition() -> Bool {
        refreshLatestScrollGeometry()
        guard hasCompletedInitialScrollResolution,
              restorationLock == nil,
              let geometry = latestScrollGeometry else {
            return false
        }
        return publishReadingPosition(
            geometry: geometry,
            frames: rowContentFrames
        )
    }

    private func scheduleReadingPositionCommitIfNeeded() {
        guard viewportCache.isScrollIdle,
              viewportCache.readingPositionCommitGate.hasPendingCommit else {
            return
        }

        cancelPendingReadingPositionCommit()
        viewportCache.pendingReadingPositionCommit = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled,
                  viewportCache.isScrollIdle,
                  viewportCache.readingPositionCommitGate.hasPendingCommit else {
                return
            }

            viewportCache.pendingReadingPositionCommit = nil
            guard publishLatestReadingPosition() else { return }
            viewportCache.readingPositionCommitGate.consumePendingCommit()
            onReadingPositionCommit()
        }
    }

    private func commitPendingReadingPosition() {
        cancelPendingReadingPositionCommit()
        if viewportCache.readingPositionCommitGate.hasPendingCommit,
           publishLatestReadingPosition() {
            viewportCache.readingPositionCommitGate.consumePendingCommit()
        }
        onReadingPositionCommit()
    }

    private func cancelPendingReadingPositionCommit() {
        viewportCache.pendingReadingPositionCommit?.cancel()
        viewportCache.pendingReadingPositionCommit = nil
    }

    @discardableResult
    private func publishReadingPosition(
        geometry: ChatTranscriptScrollGeometrySnapshot,
        frames: [ChatTranscriptRowContentFrame]
    ) -> Bool {
        guard let position = ChatTranscriptReadingPositionResolver.resolve(
            frames: frames,
            visibleContentOffsetY: geometry.visibleContentOffsetY
        ) else {
            return false
        }
        onReadingPositionChange(position)
        return true
    }

    private func resolveInitialScrollPositionIfReady(
        frames suppliedFrames: [ChatTranscriptRowContentFrame]? = nil
    ) {
        guard !hasCompletedInitialScrollResolution else { return }
        refreshLatestScrollGeometry()

        if restorationLock == nil {
            restorationLock = initialScrollPosition.map {
                .saved($0)
            } ?? .bottom(preservesStoredPosition: false)
            // SCROLLTRACE
            ChatScrollTrace.log(
                "resolve.lockCreated lock=\(String(describing: restorationLock)) isLoading=\(isLoading) rows=\(displayedTranscriptMessages.count)"
            )
        }

        guard let restorationLock else { return }
        let frames = suppliedFrames ?? rowContentFrames

        guard case .saved(let position) = restorationLock else {
            completeInitialScrollResolution(
                restorationLock,
                geometry: latestScrollGeometry,
                frames: frames
            )
            return
        }

        guard let displayedRenderID = displayedTranscriptRenderID(
            for: position
        ) else {
            // SCROLLTRACE
            ChatScrollTrace.log(
                "resolve.anchorNotDisplayed saved=\(position.renderID) isLoading=\(isLoading) rows=\(displayedTranscriptMessages.count)"
            )
            selectMeasuredRow(nil)
            // Never expose an unrelated newest-page placeholder while the
            // one-shot saved-position lookup is still in flight. If the saved
            // row cannot be resolved after loading, the normal fallback below
            // reveals latest once and stays there.
            isApplyingInitialRestoration = isLoading
            invalidateRestorationVerification()
            guard !isLoading else { return }
            fallBackFromMissingInitialAnchor()
            return
        }

        isApplyingInitialRestoration =
            !hasRevealedWhileAwaitingSavedRowFrame
        selectMeasuredRow(displayedRenderID)
        guard ChatTranscriptReadingPositionResolver.matchingFrame(
            for: position,
            frames: frames
        ) != nil else {
            // SCROLLTRACE
            ChatScrollTrace.log(
                "resolve.awaitingFrame anchor=\(displayedRenderID) frames=\(frames.count)"
            )
            invalidateRestorationVerification()
            scheduleInitialRestorationVerification(for: restorationLock)
            return
        }

        applyAndVerifyInitialRestoration(
            restorationLock,
            frames: frames
        )
    }

    private var hidesTranscriptForInitialRestoration: Bool {
        isApplyingInitialRestoration
            || (
                initialScrollPosition != nil
                    && !hasCompletedInitialScrollResolution
                    && !hasRevealedWhileAwaitingSavedRowFrame
            )
    }

    /// A stale transient row can be canonicalized while the bounded target
    /// request is in flight. Retarget the still-hidden restoration lock before
    /// any missing-anchor fallback can reveal the newest tail.
    private func handleInitialScrollPositionReplacement() {
        // SCROLLTRACE
        ChatScrollTrace.log(
            "resolve.initialPositionReplaced new=\(initialScrollPosition?.renderID ?? "nil") completed=\(hasCompletedInitialScrollResolution)"
        )
        guard !hasCompletedInitialScrollResolution else { return }

        invalidateRestorationVerification(resetDeadline: true)
        measuredRowRenderID = nil
        hasRevealedWhileAwaitingSavedRowFrame = false
        restorationLock = initialScrollPosition.map {
            .saved($0)
        } ?? .bottom(preservesStoredPosition: false)
        isApplyingInitialRestoration = initialScrollPosition != nil
        resolveInitialScrollPositionIfReady()
    }

    private func fallBackFromMissingInitialAnchor() {
        guard !hasCompletedInitialScrollResolution else { return }

        let fallback = ChatTranscriptRestorationLock.bottom(
            preservesStoredPosition: true
        )
        restorationLock = fallback
        invalidateRestorationVerification(resetDeadline: true)
        applyAndVerifyInitialRestoration(
            fallback,
            frames: rowContentFrames
        )
    }

    private func applyAndVerifyInitialRestoration(
        _ lock: ChatTranscriptRestorationLock,
        frames: [ChatTranscriptRowContentFrame]
    ) {
        refreshLatestScrollGeometry()
        guard restorationLock == lock else {
            return
        }
        guard let geometry = latestScrollGeometry else {
            scheduleInitialRestorationVerification(for: lock)
            return
        }
        guard let targetOffsetY = targetContentOffsetY(
            for: lock,
            geometry: geometry,
            frames: frames
        ) else {
            return
        }

        guard abs(geometry.visibleContentOffsetY - targetOffsetY) <= 0.5 else {
            // SCROLLTRACE
            ChatScrollTrace.log(
                "applyInitial.correcting target=\(String(format: "%.1f", targetOffsetY)) current=\(String(format: "%.1f", geometry.visibleContentOffsetY)) revealed=\(hasRevealedWhileAwaitingSavedRowFrame)"
            )
            invalidateRestorationVerification()
            viewportController.scrollToVisibleContentOffsetY(targetOffsetY)
            scheduleInitialRestorationVerification(for: lock)
            return
        }

        scheduleInitialRestorationVerification(for: lock)
    }

    private func scheduleInitialRestorationVerification(
        for lock: ChatTranscriptRestorationLock
    ) {
        let verificationStartedAt = restorationVerificationStartedAt ?? Date()
        restorationVerificationStartedAt = verificationStartedAt
        restorationVerificationGeneration += 1
        let verificationGeneration = restorationVerificationGeneration

        Task { @MainActor in
            // Do not reveal between SwiftUI's initial text/media layout passes.
            // The generation check restarts this quiet window whenever either
            // row geometry or the scroll geometry changes.
            try? await Task.sleep(nanoseconds: 200_000_000)

            // Preference and scroll-geometry callbacks can keep arriving for
            // many seconds while a long markdown transcript lays out. Do not
            // let that callback churn starve the reader behind the restoration
            // spinner forever: after a bounded stabilization window, the most
            // recent task may verify the current target. The retained lock
            // continues correcting later non-user layout shifts after reveal.
            let reachedVerificationDeadline =
                Date().timeIntervalSince(verificationStartedAt) >= 1.5

            guard (
                    verificationGeneration == restorationVerificationGeneration
                        || reachedVerificationDeadline
                  ),
                  !hasCompletedInitialScrollResolution,
                  restorationLock == lock else {
                return
            }

            refreshLatestScrollGeometry()
            guard let currentGeometry = latestScrollGeometry,
                  let currentTarget = targetContentOffsetY(
                      for: lock,
                      geometry: currentGeometry,
                      frames: rowContentFrames
                  ) else {
                if reachedVerificationDeadline {
                    if case .saved(let position) = lock,
                       displayedTranscriptRenderID(for: position) != nil {
                        // Identity is present, so this is slow row measurement,
                        // not a missing saved row. Bound the hidden phase, keep
                        // the saved lock, and let the eventual frame callback
                        // finish the exact restoration. A user gesture,
                        // keyboard focus, send, or explicit latest action can
                        // still cancel this pending lock immediately.
                        // SCROLLTRACE
                        ChatScrollTrace.log(
                            "verify.deadlineRevealAwaitingFrame anchor=\(position.renderID) offsetY=\(String(format: "%.1f", latestScrollGeometry?.visibleContentOffsetY ?? -1)) contentH=\(String(format: "%.1f", latestScrollGeometry?.contentHeight ?? -1))"
                        )
                        hasRevealedWhileAwaitingSavedRowFrame = true
                        isApplyingInitialRestoration = false
                        invalidateRestorationVerification(
                            resetDeadline: true
                        )
                    } else if case .bottom = lock {
                        completeInitialScrollResolution(
                            lock,
                            geometry: latestScrollGeometry,
                            frames: rowContentFrames
                        )
                    } else {
                        // SCROLLTRACE
                        ChatScrollTrace.log(
                            "verify.deadlineMissingAnchorFallback lock=\(String(describing: lock))"
                        )
                        fallBackFromMissingInitialAnchor()
                    }
                } else {
                    scheduleInitialRestorationVerification(for: lock)
                }
                return
            }

            let isAtTarget = abs(
                currentGeometry.visibleContentOffsetY - currentTarget
            ) <= 0.5
            if !isAtTarget {
                // SCROLLTRACE
                ChatScrollTrace.log(
                    "verify.correcting target=\(String(format: "%.1f", currentTarget)) current=\(String(format: "%.1f", currentGeometry.visibleContentOffsetY)) deadline=\(reachedVerificationDeadline) revealed=\(hasRevealedWhileAwaitingSavedRowFrame)"
                )
                invalidateRestorationVerification()
                viewportController.scrollToVisibleContentOffsetY(currentTarget)
                refreshLatestScrollGeometry()
                if reachedVerificationDeadline {
                    let reachedTargetAfterFinalCorrection =
                        latestScrollGeometry.map {
                            abs($0.visibleContentOffsetY - currentTarget) <= 0.5
                        } ?? false
                    if !reachedTargetAfterFinalCorrection {
                        if case .bottom = lock {
                            completeInitialScrollResolution(
                                lock,
                                geometry: latestScrollGeometry,
                                frames: rowContentFrames
                            )
                        } else {
                            fallBackFromMissingInitialAnchor()
                        }
                        return
                    }
                } else {
                    scheduleInitialRestorationVerification(for: lock)
                    return
                }
            }

            if pendingFollowLatestAfterInitialRestoration,
               !lock.preservesStoredPosition {
                // A follow-latest transition can arrive while the restored
                // viewport is still hidden (for example, a send immediately
                // after opening). Make bottom the new verified target before
                // revealing instead of letting the saved-position lock undo
                // that already-fired scroll and exposing a visible jump.
                pendingFollowLatestAfterInitialRestoration = false
                let followLock = ChatTranscriptRestorationLock.bottom(
                    preservesStoredPosition: false
                )
                restorationLock = followLock
                invalidateRestorationVerification(resetDeadline: true)
                applyAndVerifyInitialRestoration(
                    followLock,
                    frames: rowContentFrames
                )
                return
            }

            completeInitialScrollResolution(
                lock,
                geometry: currentGeometry,
                frames: rowContentFrames
            )
        }
    }

    private func completeInitialScrollResolution(
        _ lock: ChatTranscriptRestorationLock,
        geometry: ChatTranscriptScrollGeometrySnapshot?,
        frames: [ChatTranscriptRowContentFrame]
    ) {
        guard !hasCompletedInitialScrollResolution else { return }

        // SCROLLTRACE
        ChatScrollTrace.log(
            "resolve.complete lock=\(String(describing: lock)) offsetY=\(String(format: "%.1f", geometry?.visibleContentOffsetY ?? -1))"
        )
        hasCompletedInitialScrollResolution = true
        isApplyingInitialRestoration = false
        hasRevealedWhileAwaitingSavedRowFrame = false
        restorationVerificationStartedAt = nil
        pendingFollowLatestAfterInitialRestoration = false

        if !lock.preservesStoredPosition,
           let geometry {
            publishReadingPosition(
                geometry: geometry,
                frames: frames
            )
        }

        onInitialScrollPositionResolution(lock.initialScrollResolution)
        if lock.preservesStoredPosition {
            scheduleMissingAnchorFallbackSettlement()
        } else {
            scheduleRestorationLockReleaseIfReady()
        }
    }

    private func maintainCompletedRestorationLock() {
        refreshLatestScrollGeometry()
        guard let geometry = latestScrollGeometry else { return }
        guard let restorationLock else { return }

        guard let targetOffsetY = targetContentOffsetY(
            for: restorationLock,
            geometry: geometry,
            frames: rowContentFrames
        ) else {
            // Preserve the last valid stored anchor until the reader explicitly
            // chooses another position.
            return
        }

        guard abs(
            geometry.visibleContentOffsetY - targetOffsetY
        ) <= 0.5 else {
            // SCROLLTRACE
            ChatScrollTrace.log(
                "maintainLock.correcting target=\(String(format: "%.1f", targetOffsetY)) current=\(String(format: "%.1f", geometry.visibleContentOffsetY)) lock=\(String(describing: restorationLock))"
            )
            viewportController.scrollToVisibleContentOffsetY(targetOffsetY)
            return
        }
    }

    private func scheduleRestorationLockReleaseIfReady() {
        guard hasCompletedInitialScrollResolution,
              !isLoading,
              restorationLock != nil,
              restorationLock?.preservesStoredPosition != true else {
            return
        }

        restorationLockReleaseGeneration += 1
        let releaseGeneration = restorationLockReleaseGeneration
        Task { @MainActor in
            // One quiet-window correction plus one final verification is enough
            // to absorb the authoritative cache reconcile and late initial
            // Markdown layout without retaining a lock into normal interaction.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled,
                  releaseGeneration == restorationLockReleaseGeneration,
                  restorationLock != nil else {
                return
            }
            maintainCompletedRestorationLock()

            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled,
                  releaseGeneration == restorationLockReleaseGeneration,
                  restorationLock != nil else {
                return
            }
            maintainCompletedRestorationLock()
            releaseRestorationLock()
            requestLeadingVisibleRowMeasurement()
        }
    }

    private func scheduleMissingAnchorFallbackSettlement() {
        guard hasCompletedInitialScrollResolution,
              restorationLock?.preservesStoredPosition == true else {
            return
        }

        restorationLockReleaseGeneration += 1
        let releaseGeneration = restorationLockReleaseGeneration
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(1.5)

            repeat {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled,
                      releaseGeneration == restorationLockReleaseGeneration,
                      restorationLock?.preservesStoredPosition == true else {
                    return
                }

                // Re-read UIScrollView's current content size after the parent
                // has expanded its follow-latest chrome, then correct to the
                // actual maximum offset for the full bounded settlement
                // window. This absorbs delayed Markdown/media layout without
                // bringing back the permanent size-change anchor that caused
                // keyboard and streaming scroll fights.
                viewportController.scrollToVisibleContentOffsetY(
                    Double.greatestFiniteMagnitude
                )
                refreshLatestScrollGeometry()
            } while Date() < deadline

            guard releaseGeneration == restorationLockReleaseGeneration,
                  restorationLock?.preservesStoredPosition == true else {
                return
            }
            viewportController.scrollToVisibleContentOffsetY(
                Double.greatestFiniteMagnitude
            )
            releaseRestorationLock()
            requestLeadingVisibleRowMeasurement()
        }
    }

    private func targetContentOffsetY(
        for lock: ChatTranscriptRestorationLock,
        geometry: ChatTranscriptScrollGeometrySnapshot,
        frames: [ChatTranscriptRowContentFrame]
    ) -> Double? {
        let proposedOffsetY: Double

        switch lock {
        case .saved(let position):
            guard let resolvedOffsetY =
                ChatTranscriptReadingPositionResolver.targetContentOffsetY(
                    for: position,
                    frames: frames,
                    topContentInset: geometry.topContentInset
                ) else {
                return nil
            }
            proposedOffsetY = resolvedOffsetY
        case .bottom:
            proposedOffsetY = geometry.contentHeight
                - geometry.visibleContainerHeight
        }

        return ChatTranscriptReadingPositionResolver
            .clampedVisibleContentOffsetY(
                proposedOffsetY,
                contentHeight: geometry.contentHeight,
                visibleContainerHeight: geometry.visibleContainerHeight
            )
    }

    private func displayedTranscriptRenderID(
        for position: ChatTranscriptScrollPosition
    ) -> String? {
        let identities = displayedTranscriptMessages.map {
            ChatTranscriptRowIdentity(
                renderID: $0.renderID,
                messageID: $0.persistenceMessageID
            )
        }
        guard let matchingIndex =
                ChatTranscriptReadingPositionResolver.matchingRowIndex(
                    for: position,
                    identities: identities
                ) else {
            return nil
        }
        return displayedTranscriptMessages[matchingIndex].renderID
    }

    private func invalidateRestorationVerification(
        resetDeadline: Bool = false
    ) {
        restorationVerificationGeneration += 1
        if resetDeadline {
            restorationVerificationStartedAt = nil
        }
    }

    private func releaseRestorationLockForUserScroll() {
        viewportCache.readingPositionCommitGate.register(.readerScroll)
        if hasCompletedInitialScrollResolution {
            releaseRestorationLock()
        } else {
            cancelInitialRestorationForUserIntent()
        }
    }

    private func releaseRestorationLock() {
        guard restorationLock != nil else { return }
        // SCROLLTRACE
        ChatScrollTrace.log("lock.released")
        restorationLockReleaseGeneration += 1
        invalidateRestorationVerification(resetDeadline: true)
        restorationLock = nil
    }

    private func releaseRestorationLockForProgrammaticScroll() {
        markFollowLatestReadingPositionChange()
        if hasCompletedInitialScrollResolution {
            releaseRestorationLock()
        } else {
            cancelInitialRestorationForUserIntent()
        }
    }

    private func cancelInitialRestorationForUserIntent() {
        // SCROLLTRACE
        ChatScrollTrace.log(
            "resolve.cancelledByUserIntent completed=\(hasCompletedInitialScrollResolution)"
        )
        guard !hasCompletedInitialScrollResolution else {
            releaseRestorationLock()
            return
        }

        invalidateRestorationVerification(resetDeadline: true)
        restorationLockReleaseGeneration += 1
        restorationLock = nil
        isApplyingInitialRestoration = false
        hasRevealedWhileAwaitingSavedRowFrame = false
        hasCompletedInitialScrollResolution = true
        pendingFollowLatestAfterInitialRestoration = false
        onCancelInitialRestoration()
        onInitialScrollPositionResolution(.cancelledByUser)
    }

    private func markFollowLatestReadingPositionChange() {
        viewportCache.readingPositionCommitGate.register(.followLatest)
        scheduleReadingPositionCommitIfNeeded()
    }

    private func compressionReferenceCardView(_ card: CompressionReferenceCard) -> some View {
        MarkerMessageCardView(kind: .compressionReference, content: card.referenceText)
    }

    private var transcriptHorizontalPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 20 : 16
    }

    private func transcriptContentWidth(for viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - (transcriptHorizontalPadding * 2))
    }

    @ViewBuilder
    private func olderMessagesButton(proxy: ScrollViewProxy) -> some View {
        if hasOlderMessages {
            LoadOlderMessagesButton(isLoading: isLoadingOlderMessages) {
                Task { await loadOlderMessagesPreservingPosition(proxy: proxy) }
            }
        }
    }

    private func loadOlderMessagesPreservingPosition(proxy: ScrollViewProxy) async {
        let renderID = displayedTranscriptMessages.first?.renderID
        let didLoad = await onLoadOlderMessages()
        guard didLoad, let renderID else { return }

        await Task.yield()
        if reduceMotion {
            proxy.scrollTo(renderID, anchor: .top)
        } else {
            withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
                proxy.scrollTo(renderID, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private var transcriptLooseBlocks: some View {
        reasoningBlocks(anchorMessageID: nil)
        toolCallGroups(anchorMessageID: nil)
    }

    @ViewBuilder
    private var liveResponseBlocks: some View {
        if activeStreamID != nil {
            if showsThinkingAndToolCards {
                if hasLiveReasoningText,
                   !hasDisplayedTranscriptMessage(anchorID: reasoningAnchorMessageID) {
                    ReasoningBlockView(text: liveReasoningText)
                }

                if !liveToolCalls.isEmpty,
                   !hasDisplayedTranscriptMessage(anchorID: toolCallAnchorMessageID) {
                    ToolActivityGroupView(
                        group: ToolCallGroup.live(
                            anchorMessageID: toolCallAnchorMessageID,
                            toolCalls: liveToolCalls
                        )
                    )
                }
            }

            if activeStreamRecoveryState != .idle {
                StreamRecoveryStatusView(state: activeStreamRecoveryState)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(hidesRunStatusAccessibility)
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
            }
        }
    }

    @ViewBuilder
    private var inlineClarificationCard: some View {
        if let clarificationPrompt {
            ClarificationRequestCard(
                prompt: clarificationPrompt,
                isResponding: isRespondingToClarification,
                errorMessage: clarificationErrorMessage,
                onSubmit: onSubmitClarification
            )
            .id(clarificationPrompt.id)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
        }
    }

    @ViewBuilder
    private var typingIndicator: some View {
        if showsAssistantTypingIndicator {
            AssistantTypingIndicatorView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(hidesRunStatusAccessibility)
        }
    }

    @ViewBuilder
    private var turnChangesCard: some View {
        if let summary = turnChangesSummary {
            GitTurnChangesCard(
                summary: summary,
                onOpenAll: onOpenTurnDiff,
                onOpenFile: onOpenTurnFileDiff
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var inlineCommitButton: some View {
        if let context = inlineCommitContext {
            GitInlineCommitButton(
                runningPhase: context.runningPhase,
                isDisabled: context.isDisabled,
                action: onInlineCommit
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
    }

    private var hasLiveReasoningText: Bool {
        !liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func hasDisplayedTranscriptMessage(anchorID: String?) -> Bool {
        guard let anchorID else { return false }

        return displayedTranscriptMessages.contains { $0.anchorID == anchorID }
    }

    @ViewBuilder
    private func reasoningBlocks(anchorMessageID: String?) -> some View {
        if showsThinkingAndToolCards {
            ForEach(reasoningGroups.filter { $0.anchorMessageID == anchorMessageID }) { group in
                ReasoningBlockView(text: group.text)
            }
        }
    }

    @ViewBuilder
    private func toolCallGroups(anchorMessageID: String?) -> some View {
        if showsThinkingAndToolCards {
            ForEach(completedToolCallGroupsForAnchor(anchorMessageID)) { group in
                ToolActivityGroupView(group: group)
            }
        }
    }
}

/// Non-observable storage for values sampled at display refresh frequency.
/// Mutating this cache must not invalidate the markdown-heavy transcript tree.
private final class ChatTranscriptViewportCache {
    var rowContentFrames: [ChatTranscriptRowContentFrame] = []
    var visibleRenderIDs: [String] = []
    var latestScrollGeometry: ChatTranscriptScrollGeometrySnapshot?
    var isScrollIdle = true
    var readingPositionCommitGate = ChatTranscriptReadingPositionCommitGate()
    var pendingReadingPositionCommit: Task<Void, Never>?

    deinit {
        pendingReadingPositionCommit?.cancel()
    }
}

private struct ChatTranscriptScrollGeometrySnapshot: Equatable {
    let visibleContentOffsetY: Double
    let contentHeight: Double
    let visibleContainerHeight: Double
    let topContentInset: Double
}

private enum ChatTranscriptRestorationLock: Equatable {
    case saved(ChatTranscriptScrollPosition)
    case bottom(preservesStoredPosition: Bool)

    var preservesStoredPosition: Bool {
        if case .bottom(let preservesStoredPosition) = self {
            return preservesStoredPosition
        }
        return false
    }

    var initialScrollResolution: ChatTranscriptInitialScrollResolution {
        if case .bottom(preservesStoredPosition: true) = self {
            return .missingAnchorFallback
        }
        return .restored
    }
}

private enum ChatTranscriptContentCoordinateSpace {
    static let name = "chatTranscriptContent"
}

private struct ChatTranscriptRowFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [ChatTranscriptRowContentFrame] = []

    static func reduce(
        value: inout [ChatTranscriptRowContentFrame],
        nextValue: () -> [ChatTranscriptRowContentFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct ChatTranscriptMessageBlock: View, Equatable {
    let transcriptMessage: TranscriptMessage
    let transcriptBlockSpacing: CGFloat
    let showsThinkingAndToolCards: Bool
    let reasoningGroups: [ReasoningGroup]
    let toolCallGroups: [ToolCallGroup]
    let liveReasoningText: String
    let reasoningAnchorMessageID: String?
    let liveToolCalls: [ToolCall]
    let toolCallAnchorMessageID: String?
    let streamingAssistantMessageID: String?
    let localAttachmentPreviews: [String: Data]?
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasActiveStream: Bool
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let loadAttachmentImage: (String) async -> Data?
    let loadAttachmentData: (String) async -> Data?
    let loadTranscriptMediaImage: (TranscriptMediaReference) async -> Data?
    let loadTranscriptMediaData: (TranscriptMediaReference) async -> Data?
    let transcriptMediaCacheNamespace: String
    let actionContext: (ChatMessage, Int) -> MessageActionContext?
    let shouldRenderMessageRow: (ChatMessage) -> Bool
    let hidesTranscriptMessageAccessibility: Bool
    let onPreviewAttachment: (MessageAttachment, Data?) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onSelectText: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void

    // Equality over the value inputs only. The closures are pure functions of
    // these values (e.g. `actionContext` is fully determined by
    // `transcriptMessage`), so two blocks that compare equal render identically.
    // This lets `.equatable()` skip re-evaluating rows whose data is unchanged
    // even though their closure props are recreated on every parent body pass.
    static func == (lhs: ChatTranscriptMessageBlock, rhs: ChatTranscriptMessageBlock) -> Bool {
        lhs.transcriptMessage == rhs.transcriptMessage &&
            lhs.transcriptBlockSpacing == rhs.transcriptBlockSpacing &&
            lhs.showsThinkingAndToolCards == rhs.showsThinkingAndToolCards &&
            lhs.reasoningGroups == rhs.reasoningGroups &&
            lhs.toolCallGroups == rhs.toolCallGroups &&
            lhs.liveReasoningText == rhs.liveReasoningText &&
            lhs.reasoningAnchorMessageID == rhs.reasoningAnchorMessageID &&
            lhs.liveToolCalls == rhs.liveToolCalls &&
            lhs.toolCallAnchorMessageID == rhs.toolCallAnchorMessageID &&
            lhs.streamingAssistantMessageID == rhs.streamingAssistantMessageID &&
            lhs.localAttachmentPreviews == rhs.localAttachmentPreviews &&
            lhs.listeningMessageID == rhs.listeningMessageID &&
            lhs.isViewingCachedData == rhs.isViewingCachedData &&
            lhs.hasActiveStream == rhs.hasActiveStream &&
            lhs.isRegeneratingMessage == rhs.isRegeneratingMessage &&
            lhs.isEditingMessage == rhs.isEditingMessage &&
            lhs.isForkingMessage == rhs.isForkingMessage &&
            lhs.transcriptMediaCacheNamespace == rhs.transcriptMediaCacheNamespace &&
            lhs.hidesTranscriptMessageAccessibility ==
                rhs.hidesTranscriptMessageAccessibility
    }

    var body: some View {
        VStack(alignment: .leading, spacing: transcriptBlockSpacing) {
            reasoningBlocks
            liveReasoningBlock
            toolActivityGroups
            liveToolActivityGroup

            if shouldRenderMessageRow(transcriptMessage.message) {
                ChatTranscriptMessageRow(
                    message: transcriptMessage.message,
                    visibleIndex: transcriptMessage.loadedIndex,
                    actionContext: actionContext(transcriptMessage.message, transcriptMessage.loadedIndex),
                    localAttachmentPreviews: localAttachmentPreviews,
                    listeningMessageID: listeningMessageID,
                    isViewingCachedData: isViewingCachedData,
                    hasActiveStream: hasActiveStream,
                    isStreaming: ChatTranscriptDisplaySettings.shouldUseStreamingBubbleRendering(
                        hasActiveStream: hasActiveStream,
                        messageRole: transcriptMessage.message.role,
                        messageID: transcriptMessage.message.messageId,
                        streamingAssistantMessageID: streamingAssistantMessageID
                    ),
                    isRegeneratingMessage: isRegeneratingMessage,
                    isEditingMessage: isEditingMessage,
                    isForkingMessage: isForkingMessage,
                    loadAttachmentImage: loadAttachmentImage,
                    loadAttachmentData: loadAttachmentData,
                    loadTranscriptMediaImage: loadTranscriptMediaImage,
                    loadTranscriptMediaData: loadTranscriptMediaData,
                    transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
                    onPreviewAttachment: onPreviewAttachment,
                    onPreviewTranscriptMedia: onPreviewTranscriptMedia,
                    onToggleListening: onToggleListening,
                    onSelectText: onSelectText,
                    onRegenerate: onRegenerate,
                    onEdit: onEdit,
                    onFork: onFork,
                    onCopy: onCopy
                )
            }
        }
        .accessibilityHidden(hidesTranscriptMessageAccessibility)
    }

    @ViewBuilder
    private var reasoningBlocks: some View {
        if showsThinkingAndToolCards {
            ForEach(reasoningGroups.filter { $0.anchorMessageID == transcriptMessage.anchorID }) { group in
                ReasoningBlockView(text: group.text)
            }
        }
    }

    @ViewBuilder
    private var liveReasoningBlock: some View {
        if shouldRenderLiveReasoningBlock {
            ReasoningBlockView(text: liveReasoningText)
        }
    }

    @ViewBuilder
    private var toolActivityGroups: some View {
        if showsThinkingAndToolCards {
            ForEach(toolCallGroups) { group in
                ToolActivityGroupView(group: group)
            }
        }
    }

    @ViewBuilder
    private var liveToolActivityGroup: some View {
        if shouldRenderLiveToolActivityGroup {
            ToolActivityGroupView(
                group: ToolCallGroup.live(
                    anchorMessageID: toolCallAnchorMessageID,
                    toolCalls: liveToolCalls
                )
            )
        }
    }

    private var shouldRenderLiveReasoningBlock: Bool {
        hasActiveStream &&
            showsThinkingAndToolCards &&
            reasoningAnchorMessageID == transcriptMessage.anchorID &&
            !liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldRenderLiveToolActivityGroup: Bool {
        hasActiveStream &&
            showsThinkingAndToolCards &&
            toolCallAnchorMessageID == transcriptMessage.anchorID &&
            !liveToolCalls.isEmpty
    }
}

private struct ChatTranscriptMessageRow: View {
    let message: ChatMessage
    let visibleIndex: Int
    let actionContext: MessageActionContext?
    let localAttachmentPreviews: [String: Data]?
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasActiveStream: Bool
    let isStreaming: Bool
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let loadAttachmentImage: (String) async -> Data?
    let loadAttachmentData: (String) async -> Data?
    let loadTranscriptMediaImage: (TranscriptMediaReference) async -> Data?
    let loadTranscriptMediaData: (TranscriptMediaReference) async -> Data?
    let transcriptMediaCacheNamespace: String
    let onPreviewAttachment: (MessageAttachment, Data?) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onSelectText: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void

    var body: some View {
        // Compaction marker messages render as collapsible cards (matching the
        // web UI), never as user bubbles — and without bubble actions, which
        // don't apply to system-emitted markers.
        if let markerKind = ChatMarkerMessageClassifier.classify(message) {
            MarkerMessageCardView(kind: markerKind, content: message.content)
        } else if let actionContext {
            bubble
                .contextMenu {
                    ChatMessageActionMenu(
                        context: actionContext,
                        listeningMessageID: listeningMessageID,
                        isViewingCachedData: isViewingCachedData,
                        hasActiveStream: hasActiveStream,
                        isRegeneratingMessage: isRegeneratingMessage,
                        isEditingMessage: isEditingMessage,
                        isForkingMessage: isForkingMessage,
                        onToggleListening: onToggleListening,
                        onSelectText: onSelectText,
                        onRegenerate: onRegenerate,
                        onEdit: onEdit,
                        onFork: onFork,
                        onCopy: onCopy
                    )
                }
        } else {
            bubble
        }
    }

    private var bubble: some View {
        MessageBubbleView(
            message: message,
            loadAttachmentImage: loadAttachmentImage,
            loadAttachmentData: loadAttachmentData,
            loadTranscriptMediaImage: loadTranscriptMediaImage,
            loadTranscriptMediaData: loadTranscriptMediaData,
            transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
            localAttachmentPreviews: localAttachmentPreviews,
            onPreviewAttachment: onPreviewAttachment,
            onPreviewTranscriptMedia: onPreviewTranscriptMedia,
            isStreaming: isStreaming
        )
    }
}

private struct ChatScrollToBottomButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let bottomPadding: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(.primary)
                .adaptiveGlass(
                    .regular,
                    isInteractive: true,
                    fallbackMaterial: .regularMaterial,
                    in: Circle()
                )
                .chatMinimumHitTarget(in: Circle())
        }
        .buttonStyle(.chatTactile(
            .icon,
            shadow: ChatTactileButtonStyle.Shadow(
                color: .black,
                opacity: colorScheme == .dark ? 0.32 : 0.16,
                radius: 8,
                y: 4,
                pressedOpacity: colorScheme == .dark ? 0.18 : 0.08,
                pressedRadius: 3,
                pressedY: 2
            )
        ))
        .padding(.bottom, bottomPadding)
        .accessibilityLabel("Scroll to latest message")
    }
}

private struct LoadOlderMessagesButton: View {
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }

                Text(isLoading ? String(localized: "Loading older messages") : String(localized: "Load older messages"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(.separator).opacity(0.32), lineWidth: 0.5)
            )
        }
        .buttonStyle(.chatTactile(.capsule))
        .disabled(isLoading)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(isLoading ? String(localized: "Loading older messages") : String(localized: "Load older messages"))
    }
}
