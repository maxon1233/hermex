import CryptoKit
import CoreGraphics
import Foundation
import SwiftUI

/// Pure decision rules for the chat transcript's auto-scroll behavior.
///
/// The transcript keeps app-owned follow-bottom intent separate from
/// user-owned manual scrolling, and a short cooldown after any user
/// interaction prevents streaming layout growth from yanking the viewport
/// while a manual scroll is still settling.
enum ChatScrollPolicy {
    /// Existing transcripts should enter at their latest content as part of the
    /// scroll view's first layout, before the destination becomes visible.
    static let initialTranscriptAnchor = UnitPoint.bottom

    /// Distance (pt) from the bottom within which we treat the transcript as
    /// pinned to the latest content while idle.
    static let bottomDetectionThreshold: CGFloat = 80

    /// Looser bottom threshold while a response is streaming, so small layout
    /// jitter from incoming tokens does not flip follow state off.
    static let streamingBottomDetectionThreshold: CGFloat = 160

    /// Extra distance past the bottom threshold required before the composer
    /// chrome collapses into its compact "reading older" presentation.
    static let readingOlderHysteresis: CGFloat = 64

    /// How long automatic follow-scroll stays paused after the user last
    /// interacted with the scroll view.
    static let userScrollCooldown: TimeInterval = 0.25

    static func bottomThreshold(isStreaming: Bool) -> CGFloat {
        isStreaming ? streamingBottomDetectionThreshold : bottomDetectionThreshold
    }

    static func isNearBottom(distanceFromBottom: CGFloat, isStreaming: Bool) -> Bool {
        distanceFromBottom <= bottomThreshold(isStreaming: isStreaming)
    }

    /// True once the user has scrolled far enough above the bottom that the
    /// composer chrome should collapse. The hysteresis keeps the chrome stable
    /// when hovering right around the bottom threshold.
    static func shouldEnterReadingOlder(distanceFromBottom: CGFloat, isStreaming: Bool) -> Bool {
        distanceFromBottom > bottomThreshold(isStreaming: isStreaming) + readingOlderHysteresis
    }

    static func cooldownDeadline(after date: Date = Date()) -> Date {
        date.addingTimeInterval(userScrollCooldown)
    }

    /// Automatic follow-scroll is paused while the user is actively touching the
    /// scroll view and for a brief cooldown window afterward. Explicit user
    /// actions (tapping scroll-to-bottom, sending a message) bypass this.
    static func isAutoScrollPaused(
        isUserInteracting: Bool,
        cooldownUntil: Date?,
        now: Date = Date()
    ) -> Bool {
        if isUserInteracting {
            return true
        }

        guard let cooldownUntil else {
            return false
        }

        return now < cooldownUntil
    }
}

struct ChatTranscriptScrollPosition: Codable, Equatable {
    static let visibleContentCoordinateVersion = 2

    let renderID: String
    /// Stable server message identity when upstream supplied one. Older
    /// persisted values omit this and continue to resolve by `renderID`.
    let messageID: String?
    /// Signed distance from the row's top to the visible content origin.
    ///
    /// Positive values mean the reader is partway through a tall row. A small
    /// negative value preserves the spacing above the first visible row.
    let offsetFromRowTop: Double
    /// Version 2 stores offsets from the top of the unobscured visible content
    /// area. A missing value was written by earlier builds from raw
    /// UIScrollView contentOffset and needs the current top inset added once
    /// during restoration.
    let coordinateSpaceVersion: Int?

    init(
        renderID: String,
        messageID: String? = nil,
        offsetFromRowTop: Double,
        coordinateSpaceVersion: Int? = visibleContentCoordinateVersion
    ) {
        self.renderID = renderID
        self.messageID = messageID
        self.offsetFromRowTop = offsetFromRowTop
        self.coordinateSpaceVersion = coordinateSpaceVersion
    }
}

/// Keeps high-frequency viewport samples out of SwiftUI's observation graph.
///
/// `record(_:)` is intentionally memory-only so it is safe to call for every
/// scroll geometry sample. `flush()` performs at most one write for the latest
/// changed position and is called only when scrolling settles or the view/app
/// leaves the foreground.
final class ChatTranscriptScrollPositionRecorder {
    private(set) var latestPosition: ChatTranscriptScrollPosition?
    private(set) var persistedPosition: ChatTranscriptScrollPosition?
    private let writer: (ChatTranscriptScrollPosition) -> Void

    init(
        initialPosition: ChatTranscriptScrollPosition?,
        writer: @escaping (ChatTranscriptScrollPosition) -> Void
    ) {
        latestPosition = initialPosition
        persistedPosition = initialPosition
        self.writer = writer
    }

    func record(_ position: ChatTranscriptScrollPosition?) {
        guard let position, position != latestPosition else { return }
        latestPosition = position
    }

    /// Drops viewport samples captured while an attempted restoration was
    /// laying out its fallback content. The last successfully persisted reader
    /// position remains eligible for a later restoration attempt.
    func discardUnpersistedPosition() {
        latestPosition = persistedPosition
    }

    /// Resets recorder bookkeeping after the caller explicitly removes an
    /// unrecoverable persisted anchor from its backing store.
    func resetPosition(_ position: ChatTranscriptScrollPosition?) {
        latestPosition = position
        persistedPosition = position
    }

    /// Replaces a stale row identity with its authoritative equivalent while
    /// preserving the exact pixel offset the reader had within that row.
    ///
    /// Completion reconciliation uses this when a temporary `stream-*` row is
    /// replaced by the server's persisted assistant message.
    @discardableResult
    func rebasePosition(
        sourceRenderID: String,
        sourceMessageID: String?,
        targetRenderID: String,
        targetMessageID: String?
    ) -> ChatTranscriptScrollPosition? {
        guard let latestPosition,
              latestPosition.renderID == sourceRenderID,
              latestPosition.messageID == sourceMessageID else {
            return nil
        }

        let rebasedPosition = ChatTranscriptScrollPosition(
            renderID: targetRenderID,
            messageID: targetMessageID,
            offsetFromRowTop: latestPosition.offsetFromRowTop,
            coordinateSpaceVersion: latestPosition.coordinateSpaceVersion
        )
        self.latestPosition = rebasedPosition
        writer(rebasedPosition)
        persistedPosition = rebasedPosition
        return rebasedPosition
    }

    @discardableResult
    func flush() -> Bool {
        guard let latestPosition,
              latestPosition != persistedPosition,
              !Self.hasTransientMessageIdentity(latestPosition) else {
            return false
        }

        writer(latestPosition)
        persistedPosition = latestPosition
        return true
    }

    private static func hasTransientMessageIdentity(
        _ position: ChatTranscriptScrollPosition
    ) -> Bool {
        position.hasTransientMessageIdentity
    }
}

extension ChatTranscriptScrollPosition {
    var hasTransientMessageIdentity: Bool {
        guard let messageID else { return false }
        return messageID.hasPrefix("stream-")
            || messageID.hasPrefix("local-")
    }
}

/// Prevents layout-only viewport changes from replacing a reader's saved
/// position.
///
/// Keyboard presentation, composer-height changes, and late Markdown layout
/// all change scroll geometry without expressing new navigation intent. Only a
/// reader gesture or a follow-latest scroll is allowed to advance the persisted
/// transcript position.
struct ChatTranscriptReadingPositionCommitGate {
    enum Trigger {
        case layout
        case readerScroll
        case followLatest
    }

    private(set) var hasPendingCommit = false

    mutating func register(_ trigger: Trigger) {
        switch trigger {
        case .layout:
            break
        case .readerScroll, .followLatest:
            hasPendingCommit = true
        }
    }

    @discardableResult
    mutating func consumePendingCommit() -> Bool {
        guard hasPendingCommit else { return false }
        hasPendingCommit = false
        return true
    }
}

struct ChatTranscriptRowContentFrame: Equatable {
    let renderID: String
    let messageID: String?
    let minY: Double
    let maxY: Double

    init(
        renderID: String,
        messageID: String? = nil,
        minY: Double,
        maxY: Double
    ) {
        self.renderID = renderID
        self.messageID = messageID
        self.minY = minY
        self.maxY = maxY
    }
}

struct ChatTranscriptRowIdentity: Equatable {
    let renderID: String
    let messageID: String?
}

enum ChatTranscriptMessageIdentity {
    /// Returns a stable, compact row identity even on servers that omit
    /// `messageId`. The hash avoids persisting full conversation content while
    /// remaining deterministic across launches and page-window changes.
    static func resolve(for message: ChatMessage) -> String {
        if let messageID = message.messageId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !messageID.isEmpty {
            return messageID
        }

        let digest = SHA256.hash(
            data: Data(message.id.utf8)
        )
        return "fingerprint:" + digest.map {
            String(format: "%02x", $0)
        }.joined()
    }
}

enum ChatTranscriptReadingPositionResolver {
    static func resolve(
        frames: [ChatTranscriptRowContentFrame],
        visibleContentOffsetY: Double
    ) -> ChatTranscriptScrollPosition? {
        guard var firstFrame = frames.first else {
            return nil
        }

        var finalFrame = firstFrame
        var firstIntersectingFrame: ChatTranscriptRowContentFrame?

        for frame in frames {
            if frame.minY < firstFrame.minY {
                firstFrame = frame
            }
            if frame.minY > finalFrame.minY {
                finalFrame = frame
            }
            if frame.maxY > visibleContentOffsetY {
                if let currentFrame = firstIntersectingFrame {
                    if frame.minY < currentFrame.minY {
                        firstIntersectingFrame = frame
                    }
                } else {
                    firstIntersectingFrame = frame
                }
            }
        }

        // When the viewport is in spacing after the final ordinary message
        // (for example above the composer), retain the final row as the anchor
        // and allow an offset larger than that row's height.
        let anchorFrame = firstIntersectingFrame ?? finalFrame

        return ChatTranscriptScrollPosition(
            renderID: anchorFrame.renderID,
            messageID: anchorFrame.messageID,
            offsetFromRowTop: visibleContentOffsetY - anchorFrame.minY
        )
    }

    static func targetContentOffsetY(
        for position: ChatTranscriptScrollPosition,
        frames: [ChatTranscriptRowContentFrame],
        topContentInset: Double = 0
    ) -> Double? {
        guard let frame = matchingFrame(for: position, frames: frames) else {
            return nil
        }

        let legacyRawOffsetAdjustment =
            position.coordinateSpaceVersion == nil
                ? max(0, topContentInset)
                : 0
        return frame.minY
            + position.offsetFromRowTop
            + legacyRawOffsetAdjustment
    }

    static func matchingFrame(
        for position: ChatTranscriptScrollPosition,
        frames: [ChatTranscriptRowContentFrame]
    ) -> ChatTranscriptRowContentFrame? {
        let identities = frames.map {
            ChatTranscriptRowIdentity(
                renderID: $0.renderID,
                messageID: $0.messageID
            )
        }
        guard let index = matchingRowIndex(
            for: position,
            identities: identities
        ) else {
            return nil
        }

        return frames[index]
    }

    /// A stable message identity normally survives pagination-driven render-ID
    /// changes. If upstream omitted IDs and two messages have identical
    /// fingerprints, the persisted render ID disambiguates the intended row
    /// instead of silently choosing the first duplicate.
    static func matchingRowIndex(
        for position: ChatTranscriptScrollPosition,
        identities: [ChatTranscriptRowIdentity]
    ) -> Int? {
        guard let messageID = position.messageID else {
            return identities.firstIndex {
                $0.renderID == position.renderID
            }
        }

        // Fingerprints are deterministic but not guaranteed unique. Prefer the
        // exact raw index, then tolerate only a small authoritative index shift
        // when the fingerprint is unique. Server reconciliation can insert
        // hidden tool-result rows ahead of an existing assistant; an unlimited
        // identity-only fallback could instead choose a distant duplicate.
        if messageID.hasPrefix("fingerprint:") {
            if let exactIndex = identities.firstIndex(where: {
                $0.messageID == messageID
                    && $0.renderID == position.renderID
            }) {
                return exactIndex
            }

            let matchingIndices = identities.indices.filter {
                identities[$0].messageID == messageID
            }
            guard matchingIndices.count == 1,
                  let savedAbsoluteIndex = absoluteTranscriptIndex(
                      from: position.renderID
                  ),
                  let candidateAbsoluteIndex = absoluteTranscriptIndex(
                      from: identities[matchingIndices[0]].renderID
                  ),
                  abs(candidateAbsoluteIndex - savedAbsoluteIndex) <= 50 else {
                return nil
            }
            return matchingIndices[0]
        }

        let matchingIndices = identities.indices.filter {
            identities[$0].messageID == messageID
        }
        guard matchingIndices.count != 1 else {
            return matchingIndices[0]
        }

        return matchingIndices.first {
            identities[$0].renderID == position.renderID
        }
    }

    private static func absoluteTranscriptIndex(from renderID: String) -> Int? {
        let prefix = "transcript:"
        guard renderID.hasPrefix(prefix) else { return nil }
        return Int(renderID.dropFirst(prefix.count))
    }

    /// Clamps an offset expressed in the scroll view's visible-content
    /// coordinate space. Zero is the first unobscured content point; the
    /// maximum aligns the end of content with the bottom unobscured edge.
    static func clampedVisibleContentOffsetY(
        _ proposedOffsetY: Double,
        contentHeight: Double,
        visibleContainerHeight: Double
    ) -> Double {
        let maximumOffsetY = max(
            0,
            contentHeight - max(0, visibleContainerHeight)
        )

        return min(maximumOffsetY, max(0, proposedOffsetY))
    }
}

/// Stores the exact point in a transcript row a reader was viewing when they
/// left a session.
///
/// A missing value deliberately means a session has never recorded a viewport.
/// Once a session has been viewed, every position — including the exact bottom —
/// is retained so reopening can reproduce the previous screen.
enum ChatTranscriptScrollPersistence {
    private static let keyPrefix = "chatTranscript.scrollPosition."

    static func key(for server: URL, sessionID: String) -> String {
        "\(keyPrefix)\(server.absoluteString)|\(sessionID)"
    }

    static func load(
        for server: URL,
        sessionID: String,
        defaults: UserDefaults = .standard
    ) -> ChatTranscriptScrollPosition? {
        let key = key(for: server, sessionID: sessionID)

        if let data = defaults.data(forKey: key),
           let position = try? JSONDecoder().decode(ChatTranscriptScrollPosition.self, from: data) {
            return position
        }

        // Migrate the row-only value written by the first implementation.
        if let renderID = defaults.string(forKey: key), !renderID.isEmpty {
            return ChatTranscriptScrollPosition(
                renderID: renderID,
                offsetFromRowTop: 0
            )
        }

        return nil
    }

    static func save(
        _ position: ChatTranscriptScrollPosition?,
        for server: URL,
        sessionID: String,
        defaults: UserDefaults = .standard
    ) {
        let key = key(for: server, sessionID: sessionID)

        if let position,
           !position.renderID.isEmpty,
           let data = try? JSONEncoder().encode(position) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Keeps transcript reconciliation and other state-heavy startup work out of
/// the system navigation transition. Cache preparation remains synchronous so
/// an available transcript can participate in the destination's first layout.
enum ChatInitialAppearancePolicy {
    static func shouldBeginAsyncWork(hasCompletedAppearance: Bool) -> Bool {
        hasCompletedAppearance
    }
}

/// Decides when the transcript has enough local state to restore and reveal
/// while an authoritative message refresh is still in flight.
///
/// `nil` means there is no saved row to find, so the cached transcript can use
/// its bottom anchor immediately. A saved row that is absent from the cache
/// must wait for the server response because it may exist on an older page.
enum ChatInitialScrollResolutionPolicy {
    static func shouldResolve(
        isLoading: Bool,
        requestedPositionIsDisplayed: Bool?
    ) -> Bool {
        !isLoading || requestedPositionIsDisplayed != false
    }
}

// SCROLLTRACE: temporary diagnostic tracing for the WHOOP restoration jump.
// Compile-gated to DEBUG; strip before publishing.
#if DEBUG
import os

enum ChatScrollTrace {
    static let logger = Logger(
        subsystem: "hermex.scrolltrace",
        category: "restore"
    )

    static func log(_ message: @autoclosure () -> String) {
        let text = message()
        logger.info("\(text, privacy: .public)")
    }
}
#else
enum ChatScrollTrace {
    @inline(__always)
    static func log(_ message: @autoclosure () -> String) {}
}
#endif
