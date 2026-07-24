import SwiftUI
import UIKit

struct ChatTranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var transcriptScrollPosition = ScrollPosition(idType: String.self)
    @State private var rowContentFrames: [ChatTranscriptRowContentFrame] = []
    @State private var latestScrollGeometry: ChatTranscriptScrollGeometrySnapshot?
    @State private var hasCompletedInitialScrollResolution = false
    @State private var isLoadingInitialAnchorPage = false
    @State private var initialAnchorPageLoadFailed = false
    @State private var restorationLock: ChatTranscriptRestorationLock?
    @State private var restorationVerificationGeneration = 0
    @State private var restorationVerificationStartedAt: Date?
    @State private var pendingFollowLatestAfterInitialRestoration = false

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
    let onInitialScrollPositionResolution: (Bool) -> Void
    let onReadingPositionChange: (ChatTranscriptScrollPosition?) -> Void
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
                    .scrollPosition($transcriptScrollPosition)
                    .onScrollGeometryChange(
                        for: ChatTranscriptScrollGeometrySnapshot.self,
                        of: { geometry in
                            ChatTranscriptScrollGeometrySnapshot(
                                visibleContentOffsetY: Double(
                                    geometry.contentOffset.y
                                        + geometry.contentInsets.top
                                ),
                                contentHeight: Double(geometry.contentSize.height),
                                visibleContainerHeight: Double(
                                    geometry.containerSize.height
                                ),
                                topContentInset: Double(geometry.contentInsets.top)
                            )
                        },
                        action: { _, newGeometry in
                            handleScrollGeometryChange(newGeometry)
                        }
                    )
                    .onScrollPhaseChange { _, newPhase in
                        guard hasCompletedInitialScrollResolution,
                              newPhase == .tracking || newPhase == .interacting else {
                            return
                        }
                        releaseRestorationLockForUserScroll()
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
                .opacity(hasCompletedInitialScrollResolution ? 1 : 0)
                .accessibilityIdentifier("chat-transcript-viewport")
                .overlay {
                    if !hasCompletedInitialScrollResolution {
                        ProgressView()
                            .accessibilityLabel("Restoring conversation position")
                    }
                }
                .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsScrollToBottomButton)
                .background(Color(.systemBackground))
                .onAppear {
                    resolveInitialScrollPositionIfReady()
                }
                .onChange(of: isLoading) { _, _ in
                    resolveInitialScrollPositionIfReady()
                }
                .onChange(of: isLoadingOlderMessages) { _, _ in
                    resolveInitialScrollPositionIfReady()
                }
                .onChange(of: hasOlderMessages) { _, _ in
                    resolveInitialScrollPositionIfReady()
                }
                .onChange(of: isLoadingInitialAnchorPage) { _, isLoadingPage in
                    guard !isLoadingPage else { return }
                    if initialAnchorPageLoadFailed {
                        fallBackFromMissingInitialAnchor()
                    } else {
                        resolveInitialScrollPositionIfReady()
                    }
                }
                .onPreferenceChange(ChatTranscriptRowFramesPreferenceKey.self) { frames in
                    handleRowContentFramesChange(frames)
                }
                .onChange(of: messages.count) {
                    guard shouldFollowLatestMessage else { return }

                    if latestTranscriptMessageRole == "user" {
                        onScrollToLatestTranscriptMessage(proxy)
                    } else {
                        onScrollToLatestContent(proxy, true)
                    }
                }
                .onChange(of: streamingScrollTrigger) {
                    if shouldFollowLatestMessage {
                        onScrollToLatestContent(proxy, true)
                    }
                }
                .onChange(of: cacheFirstReconcileScrollToken) {
                    // Cache-first reconcile (#289): the server transcript just replaced
                    // the lighter cached render, so snap back to the bottom (no
                    // animation) unless the reader has scrolled away in the meantime.
                    guard shouldFollowLatestMessage else { return }
                    onScrollToLatestContent(proxy, false)
                }
                .onChange(of: shouldFollowLatestMessage) { _, shouldFollow in
                    guard hasCompletedInitialScrollResolution else {
                        pendingFollowLatestAfterInitialRestoration = shouldFollow
                        return
                    }

                    pendingFollowLatestAfterInitialRestoration = false
                    guard shouldFollow,
                          restorationLock?.preservesStoredPosition != true else {
                        return
                    }
                    releaseRestorationLockForProgrammaticScroll()
                }
                .onChange(of: clarificationPrompt?.id) {
                    guard clarificationPrompt != nil, shouldFollowLatestMessage else { return }
                    onScrollToBottom(proxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
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
                    GeometryReader { geometry in
                        let frame = geometry.frame(
                            in: .named(ChatTranscriptContentCoordinateSpace.name)
                        )
                        Color.clear.preference(
                            key: ChatTranscriptRowFramesPreferenceKey.self,
                            value: [
                                ChatTranscriptRowContentFrame(
                                    renderID: transcriptMessage.renderID,
                                    messageID: ChatTranscriptMessageIdentity.resolve(
                                        for: transcriptMessage.message
                                    ),
                                    minY: frame.minY,
                                    maxY: frame.maxY
                                )
                            ]
                        )
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
                    onMetrics: onUpdateScrollMetrics
                )

                ChatVerticalScrollAxisGuard()
            }
            .accessibilityHidden(true)
        }
    }

    private func handleScrollGeometryChange(
        _ geometry: ChatTranscriptScrollGeometrySnapshot
    ) {
        latestScrollGeometry = geometry

        if hasCompletedInitialScrollResolution {
            maintainCompletedRestorationLockOrPublish()
            return
        }

        resolveInitialScrollPositionIfReady()
    }

    private func handleRowContentFramesChange(
        _ frames: [ChatTranscriptRowContentFrame]
    ) {
        rowContentFrames = frames

        if hasCompletedInitialScrollResolution {
            maintainCompletedRestorationLockOrPublish()
            return
        }

        resolveInitialScrollPositionIfReady(frames: frames)
    }

    private func publishReadingPosition(
        geometry: ChatTranscriptScrollGeometrySnapshot,
        frames: [ChatTranscriptRowContentFrame]
    ) {
        onReadingPositionChange(
            ChatTranscriptReadingPositionResolver.resolve(
                frames: frames,
                visibleContentOffsetY: geometry.visibleContentOffsetY
            )
        )
    }

    private func resolveInitialScrollPositionIfReady(
        frames suppliedFrames: [ChatTranscriptRowContentFrame]? = nil
    ) {
        guard !isLoading, !hasCompletedInitialScrollResolution else { return }

        if restorationLock == nil {
            restorationLock = initialScrollPosition.map {
                .saved($0)
            } ?? .bottom(preservesStoredPosition: false)
        }

        guard let restorationLock else { return }
        let frames = suppliedFrames ?? rowContentFrames

        if case .saved(let position) = restorationLock,
           ChatTranscriptReadingPositionResolver.matchingFrame(
               for: position,
               frames: frames
           ) == nil {
            // The anchor is already part of this render pass, but its preference
            // frame has not arrived yet. Waiting here avoids treating a stale
            // frame set as authoritative after a page load.
            if displayedTranscriptContains(position) {
                invalidateRestorationVerification()
                return
            }

            loadOlderMessagesForInitialAnchorOrFallBack()
            return
        }

        applyAndVerifyInitialRestoration(
            restorationLock,
            frames: frames
        )
    }

    private func loadOlderMessagesForInitialAnchorOrFallBack() {
        if isLoadingOlderMessages || isLoadingInitialAnchorPage {
            return
        }

        guard hasOlderMessages else {
            fallBackFromMissingInitialAnchor()
            return
        }

        invalidateRestorationVerification(resetDeadline: true)
        initialAnchorPageLoadFailed = false
        isLoadingInitialAnchorPage = true
        Task { @MainActor in
            let didLoad = await onLoadOlderMessages()
            initialAnchorPageLoadFailed = !didLoad
            isLoadingInitialAnchorPage = false
        }
    }

    private func fallBackFromMissingInitialAnchor() {
        guard !hasCompletedInitialScrollResolution else { return }

        let fallback = ChatTranscriptRestorationLock.bottom(
            preservesStoredPosition: true
        )
        restorationLock = fallback
        invalidateRestorationVerification(resetDeadline: true)
        applyAndVerifyInitialRestoration(fallback, frames: rowContentFrames)
    }

    private func applyAndVerifyInitialRestoration(
        _ lock: ChatTranscriptRestorationLock,
        frames: [ChatTranscriptRowContentFrame]
    ) {
        guard restorationLock == lock,
              let geometry = latestScrollGeometry else {
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
            invalidateRestorationVerification()
            transcriptScrollPosition.scrollTo(y: targetOffsetY)
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
                  restorationLock == lock,
                  let currentGeometry = latestScrollGeometry,
                  let currentTarget = targetContentOffsetY(
                      for: lock,
                      geometry: currentGeometry,
                      frames: rowContentFrames
                  ) else {
                return
            }

            guard abs(
                currentGeometry.visibleContentOffsetY - currentTarget
            ) <= 0.5 else {
                invalidateRestorationVerification()
                transcriptScrollPosition.scrollTo(y: currentTarget)
                return
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

            hasCompletedInitialScrollResolution = true
            initialAnchorPageLoadFailed = false
            restorationVerificationStartedAt = nil
            pendingFollowLatestAfterInitialRestoration = false

            if !lock.preservesStoredPosition {
                publishReadingPosition(
                    geometry: currentGeometry,
                    frames: rowContentFrames
                )
            }

            onInitialScrollPositionResolution(lock.didRestoreRequestedPosition)
        }
    }

    private func maintainCompletedRestorationLockOrPublish() {
        guard let geometry = latestScrollGeometry else { return }

        if transcriptScrollPosition.isPositionedByUser {
            releaseRestorationLockForUserScroll()
        }

        guard let restorationLock else {
            publishReadingPosition(geometry: geometry, frames: rowContentFrames)
            return
        }

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
            transcriptScrollPosition.scrollTo(y: targetOffsetY)
            return
        }

        if !restorationLock.preservesStoredPosition {
            publishReadingPosition(geometry: geometry, frames: rowContentFrames)
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

    private func displayedTranscriptContains(
        _ position: ChatTranscriptScrollPosition
    ) -> Bool {
        let identities = displayedTranscriptMessages.map {
            ChatTranscriptRowIdentity(
                renderID: $0.renderID,
                messageID: ChatTranscriptMessageIdentity.resolve(
                    for: $0.message
                )
            )
        }
        return ChatTranscriptReadingPositionResolver.matchingRowIndex(
            for: position,
            identities: identities
        ) != nil
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
        guard restorationLock != nil else { return }
        invalidateRestorationVerification(resetDeadline: true)
        restorationLock = nil
    }

    private func releaseRestorationLockForProgrammaticScroll() {
        releaseRestorationLockForUserScroll()
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

    var didRestoreRequestedPosition: Bool {
        if case .bottom(preservesStoredPosition: true) = self {
            return false
        }
        return true
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
            lhs.transcriptMediaCacheNamespace == rhs.transcriptMediaCacheNamespace
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
