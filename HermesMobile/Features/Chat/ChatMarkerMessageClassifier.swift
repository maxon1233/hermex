import Foundation

/// Marker messages the agent emits around context compaction. The server sends
/// them as plain role-based messages with no structured flag, so — like the web
/// UI (`_isContextCompactionMessage` / `_isPreservedCompressionTaskListMessage`
/// in `ui.js`) — we detect them by content prefix.
enum ChatMarkerMessageKind: Equatable {
    case contextCompaction
    case preservedTaskList
    /// Synthesized "Context compaction · Reference only" anchor card built from
    /// session-level `compression_anchor_*` metadata — never produced by
    /// `classify`, which only sees literal marker messages.
    case compressionReference

    var title: String {
        switch self {
        case .contextCompaction, .compressionReference:
            return String(localized: "Context compaction")
        case .preservedTaskList:
            return String(localized: "Preserved task list")
        }
    }
}

enum ChatMarkerMessageClassifier {
    private static let preservedTaskListPrefix = "[your active task list was preserved across context compression]"
    private static let contextCompactionPrefixes = ["[context compaction", "context compaction"]

    static func classify(_ message: ChatMessage) -> ChatMarkerMessageKind? {
        guard let role = message.role, role != "tool" else { return nil }

        let text = trimmedContent(of: message)

        if role == "user", hasCaseInsensitivePrefix(text, preservedTaskListPrefix) {
            return .preservedTaskList
        }

        if isContextCompactionText(text) {
            return .contextCompaction
        }

        return nil
    }

    /// Mirrors the web UI's `_isContextCompactionText`: true when the text is
    /// itself a literal compaction marker (used both for classification and to
    /// gate the synthesized reference card).
    static func isContextCompactionText(_ text: String?) -> Bool {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return contextCompactionPrefixes.contains { hasCaseInsensitivePrefix(trimmed, $0) }
    }

    /// The card body with the preserved-task-list marker line stripped, so the
    /// preview/expanded text starts at the actual task list (mirrors the web
    /// UI's `_preservedCompressionTaskListPreview`).
    static func cardBody(for kind: ChatMarkerMessageKind, content: String?) -> String {
        let text = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard kind == .preservedTaskList,
              let markerRange = text.range(
                of: preservedTaskListPrefix,
                options: [.caseInsensitive, .anchored]
              )
        else {
            return text
        }

        return String(text[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedContent(of message: ChatMessage) -> String {
        (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasCaseInsensitivePrefix(_ text: String, _ prefix: String) -> Bool {
        text.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }
}

/// Synthetic turns the server injects for its own bookkeeping rather than as
/// part of the conversation: background-process and delegated-subagent wakeups
/// (`_source == "process_wakeup"`, built by `format_wakeup_prompt` in
/// `api/background_process.py`) and stream-recovery control turns
/// (`recovery_control`, `api/routes.py`). Both arrive as `role: "user"` messages,
/// so without this gate they render as bubbles the reader appears to have sent —
/// a wakeup carries up to 4 KB of raw process output. The web UI drops
/// recovery-control rows outright and gives wakeups their own muted notice
/// (`_messageIsRenderable` in `static/ui.js`); Hermex hides both.
enum ChatControlMessageClassifier {
    static func isHiddenControlMessage(_ message: ChatMessage) -> Bool {
        isProcessWakeup(message) || isRecoveryControl(message)
    }

    static func isProcessWakeup(_ message: ChatMessage) -> Bool {
        if message.source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "process_wakeup" {
            return true
        }

        return isWakeupPromptText(message)
    }

    /// `_source` only rides the *live* turn: the settled transcript is written
    /// through `persist_user_message` (`api/streaming.py`), which drops the
    /// marker, so historical wakeups arrive unflagged and would still render as
    /// user bubbles. Match the server's own generated prefixes instead — the same
    /// content-prefix approach `ChatMarkerMessageClassifier` uses for compaction
    /// markers, and anchored tightly enough that ordinary prose cannot collide.
    private static func isWakeupPromptText(_ message: ChatMessage) -> Bool {
        guard message.role == "user" else { return false }

        let text = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        return wakeupPromptPrefixes.contains { prefix in
            text.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
        }
    }

    /// `[IMPORTANT: Background process …]` covers both completion formatters
    /// (`api/background_process.py` writes `exit_code=`, `api/streaming.py`
    /// writes `exit code `) and the watch-pattern variant. `[ASYNC DELEGATION`
    /// is the delegated-subagent completion re-entering the parent conversation
    /// (upstream #4912). The bare `[IMPORTANT: …]` watch-overflow notices are
    /// deliberately *not* matched — that prefix is too generic to claim.
    private static let wakeupPromptPrefixes = [
        "[IMPORTANT: Background process ",
        "[ASYNC DELEGATION"
    ]

    static func isRecoveryControl(_ message: ChatMessage) -> Bool {
        guard message.role != "tool" else { return false }

        if message.isRecoveryControl == true {
            return true
        }

        return isLegacyRecoveryControlText(message.content)
    }

    /// Backward compatibility only, for sessions persisted before the server
    /// stamped `recovery_control`. Mirrors `_isRecoveryControlMessageText` in
    /// `ui.js`: strictly anchored matches, never a loose "interrupted" test — a
    /// genuine interruption notice the reader *should* see must stay visible.
    private static func isLegacyRecoveryControlText(_ text: String?) -> Bool {
        let normalized = (text ?? "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        guard !normalized.isEmpty else { return false }

        if normalized == "the live worker stopped before this run finished"
            || normalized == "the live worker stopped before this run finished." {
            return true
        }

        guard normalized.hasPrefix("[system:") else { return false }

        return normalized.contains("continue exactly where you left off")
            || normalized.contains("do not retry the same tool call")
    }
}
