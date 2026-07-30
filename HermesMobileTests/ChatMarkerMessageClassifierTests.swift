import XCTest
@testable import HermesMobile

final class ChatMarkerMessageClassifierTests: XCTestCase {
    // MARK: - Context compaction

    func testBracketedCompactionPrefixMatches() {
        let message = makeMessage(role: "user", content: "[Context compaction] Summary of earlier conversation…")
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .contextCompaction)
    }

    func testUnbracketedCompactionPrefixMatches() {
        let message = makeMessage(role: "assistant", content: "Context compaction: the prior history was summarized.")
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .contextCompaction)
    }

    func testCompactionPrefixIsCaseInsensitive() {
        let message = makeMessage(role: "user", content: "[CONTEXT COMPACTION] details")
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .contextCompaction)
    }

    func testCompactionPrefixToleratesLeadingWhitespace() {
        let message = makeMessage(role: "user", content: "  \n\t[context compaction] details")
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .contextCompaction)
    }

    func testToolRoleNeverMatches() {
        let message = makeMessage(role: "tool", content: "[context compaction] details")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testMissingRoleNeverMatches() {
        let message = makeMessage(role: nil, content: "[context compaction] details")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testNonMarkerTextStartingWithContextDoesNotMatch() {
        let message = makeMessage(role: "user", content: "Context windows are interesting — explain compaction.")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    // MARK: - Preserved task list

    func testPreservedTaskListPrefixMatchesForUserRole() {
        let message = makeMessage(
            role: "user",
            content: "[Your active task list was preserved across context compression]\n1. Do the thing"
        )
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .preservedTaskList)
    }

    func testPreservedTaskListPrefixIsCaseInsensitiveAndToleratesWhitespace() {
        let message = makeMessage(
            role: "user",
            content: "   [YOUR ACTIVE TASK LIST WAS PRESERVED ACROSS CONTEXT COMPRESSION] tasks"
        )
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .preservedTaskList)
    }

    func testPreservedTaskListPrefixDoesNotMatchNonUserRoles() {
        let message = makeMessage(
            role: "assistant",
            content: "[Your active task list was preserved across context compression] tasks"
        )
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    // MARK: - Plain messages

    func testNormalUserMessageDoesNotMatch() {
        let message = makeMessage(role: "user", content: "Hey, can you check the build?")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testEmptyContentDoesNotMatch() {
        let message = makeMessage(role: "user", content: nil)
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    // MARK: - Card body

    func testCardBodyStripsPreservedTaskListMarker() {
        let body = ChatMarkerMessageClassifier.cardBody(
            for: .preservedTaskList,
            content: "[Your active task list was preserved across context compression]\n1. First task\n2. Second task"
        )
        XCTAssertEqual(body, "1. First task\n2. Second task")
    }

    func testCardBodyKeepsCompactionTextIntact() {
        let body = ChatMarkerMessageClassifier.cardBody(
            for: .contextCompaction,
            content: "  [Context compaction] Summary text  "
        )
        XCTAssertEqual(body, "[Context compaction] Summary text")
    }

    // MARK: - Helpers

    private func makeMessage(role: String?, content: String?) -> ChatMessage {
        ChatMessage(role: role, content: content, timestamp: nil, messageId: "test-id")
    }
}

final class ChatControlMessageClassifierTests: XCTestCase {
    // MARK: - Background process / subagent wakeups

    func testProcessWakeupSourceIsHidden() {
        let message = makeMessage(
            role: "user",
            content: "[IMPORTANT: Background process abc123 completed (exit_code=0).\nCommand: ls\nOutput:\n81 entries]",
            source: "process_wakeup"
        )
        XCTAssertTrue(ChatControlMessageClassifier.isProcessWakeup(message))
        XCTAssertTrue(ChatControlMessageClassifier.isHiddenControlMessage(message))
    }

    func testProcessWakeupSourceMatchIsCaseAndWhitespaceTolerant() {
        let message = makeMessage(role: "user", content: "Subagent finished.", source: "  Process_Wakeup ")
        XCTAssertTrue(ChatControlMessageClassifier.isProcessWakeup(message))
    }

    /// Settled transcripts lose `_source`, so the server's own generated prefixes
    /// are the only signal left on historical wakeups.
    func testUnflaggedWakeupPromptTextIsHidden() {
        let texts = [
            "[IMPORTANT: Background process proc_88617 completed (exit_code=0).\nCommand: make\nOutput:\n…]",
            "[IMPORTANT: Background process proc_88617 completed (exit code 1).\nCommand: make\nOutput:\n…]",
            "[IMPORTANT: Background process proc_4f2 matched watch pattern \"ERROR\".\nCommand: tail -f log]",
            "[ASYNC DELEGATION COMPLETE — t_1]\nSubagent finished: the answer is 42."
        ]

        for text in texts {
            let message = makeMessage(role: "user", content: text)
            XCTAssertTrue(
                ChatControlMessageClassifier.isHiddenControlMessage(message),
                "server-generated wakeup must be hidden even without _source: \(text.prefix(48))"
            )
        }
    }

    func testWakeupPrefixOnlyMatchesUserRole() {
        let message = makeMessage(
            role: "assistant",
            content: "[IMPORTANT: Background process proc_1 completed (exit_code=0).]"
        )
        XCTAssertFalse(ChatControlMessageClassifier.isHiddenControlMessage(message))
    }

    /// The generic watch-overflow `[IMPORTANT: …]` prefix is deliberately not
    /// claimed, and prose that merely mentions a background process stays put.
    func testUnrelatedImportantPrefixStaysVisible() {
        for text in [
            "[IMPORTANT: the watch buffer overflowed]",
            "IMPORTANT: Background process notes for later",
            "Can you check why the background process keeps dying?"
        ] {
            let message = makeMessage(role: "user", content: text)
            XCTAssertFalse(
                ChatControlMessageClassifier.isHiddenControlMessage(message),
                "must stay in the transcript: \(text)"
            )
        }
    }

    func testOtherSourcesStayVisible() {
        for source in ["webui", "cron", "mobile", "share"] {
            let message = makeMessage(role: "user", content: "Ship the release.", source: source)
            XCTAssertFalse(
                ChatControlMessageClassifier.isHiddenControlMessage(message),
                "source=\(source) is a real user turn and must stay in the transcript"
            )
        }
    }

    func testMessageWithoutSourceStaysVisible() {
        let message = makeMessage(role: "user", content: "Ship the release.")
        XCTAssertFalse(ChatControlMessageClassifier.isHiddenControlMessage(message))
    }

    // MARK: - Stream-recovery control turns

    func testRecoveryControlFlagIsHidden() {
        let message = makeMessage(role: "user", content: "Anything at all.", isRecoveryControl: true)
        XCTAssertTrue(ChatControlMessageClassifier.isRecoveryControl(message))
        XCTAssertTrue(ChatControlMessageClassifier.isHiddenControlMessage(message))
    }

    func testLegacySystemResumeTextIsHidden() {
        let message = makeMessage(
            role: "user",
            content: "[System: the run was interrupted.\n  Continue exactly where you left off.]"
        )
        XCTAssertTrue(ChatControlMessageClassifier.isRecoveryControl(message))
    }

    func testLegacyWorkerStoppedTextIsHidden() {
        let message = makeMessage(role: "assistant", content: "  The live worker stopped before this run finished.  ")
        XCTAssertTrue(ChatControlMessageClassifier.isRecoveryControl(message))
    }

    /// The inverse data-loss class the web UI guards against: a genuine
    /// interruption notice the reader should see must never be swallowed by the
    /// legacy text match.
    func testGenuineInterruptionNoticeStaysVisible() {
        let message = makeMessage(
            role: "assistant",
            content: "**Response interrupted.** The provider closed the connection before the answer finished."
        )
        XCTAssertFalse(ChatControlMessageClassifier.isHiddenControlMessage(message))
    }

    func testSystemPrefixWithoutResumePhraseStaysVisible() {
        let message = makeMessage(role: "user", content: "[System: the workspace was moved to /srv/app.]")
        XCTAssertFalse(ChatControlMessageClassifier.isHiddenControlMessage(message))
    }

    func testToolRoleIsNeverClassifiedAsRecoveryControl() {
        let message = makeMessage(role: "tool", content: "The live worker stopped before this run finished.")
        XCTAssertFalse(ChatControlMessageClassifier.isRecoveryControl(message))
    }

    // MARK: - Helpers

    private func makeMessage(
        role: String?,
        content: String?,
        source: String? = nil,
        isRecoveryControl: Bool? = nil
    ) -> ChatMessage {
        ChatMessage(
            role: role,
            content: content,
            timestamp: nil,
            messageId: "test-id",
            source: source,
            isRecoveryControl: isRecoveryControl
        )
    }
}
