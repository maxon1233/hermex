import CoreGraphics
import UIKit
import XCTest

final class ScrollRestorationUITests: XCTestCase {
    private let maximumScrollResponseLatency: TimeInterval = 4
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments = ["--scroll-restoration-lab"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testLatestViewportReplacesPreviousViewportAcrossRepeatedReopens() throws {
        let resetButton = app.buttons["scroll-lab-reset"]
        XCTAssertTrue(
            resetButton.waitForExistence(timeout: 15),
            "The deterministic scroll-restoration lab did not launch."
        )
        resetButton.tap()

        openTranscript()
        let initialPosition = try waitForStableReadyProbe()
        let transcriptViewport =
            app.otherElements["chat-transcript-viewport"]
        XCTAssertTrue(
            transcriptViewport.waitForExistence(timeout: 10),
            "The identified transcript viewport is missing."
        )

        dragTowardOlderMessages(in: transcriptViewport)
        let positionA = try waitForStableReadyProbe(
            differentFrom: initialPosition.rawValue
        )
        let screenshotA = captureScreenshot(named: "Position A before leaving")

        leaveTranscript()
        openTranscript()
        let restoredA = try waitForStableReadyProbe()
        XCTAssertEqual(
            restoredA.rawValue,
            positionA.rawValue,
            "The first reopen did not reproduce the exact saved viewport."
        )
        let reopenedScreenshotA =
            captureScreenshot(named: "Position A after reopening")
        assertTranscriptPixelsMatch(
            screenshotA,
            reopenedScreenshotA,
            label: "position A"
        )

        let latestButton = app.buttons["Scroll to latest message"]
        XCTAssertTrue(
            latestButton.waitForExistence(timeout: 3),
            "The restored viewport incorrectly reopened at the end."
        )

        dragTowardOlderMessages(in: transcriptViewport)
        let positionB = try waitForStableReadyProbe(
            differentFrom: restoredA.rawValue
        )
        XCTAssertNotEqual(
            positionB.rawValue,
            positionA.rawValue,
            "The second user scroll did not replace the first viewport."
        )
        let screenshotB = captureScreenshot(named: "Position B before leaving")

        leaveTranscript()
        openTranscript()
        let restoredB = try waitForStableReadyProbe()
        XCTAssertEqual(
            restoredB.rawValue,
            positionB.rawValue,
            "The second reopen returned to the previous viewport."
        )
        XCTAssertNotEqual(
            restoredB.rawValue,
            positionA.rawValue,
            "The second reopen regressed to position A."
        )
        let reopenedScreenshotB =
            captureScreenshot(named: "Position B after reopening")
        assertTranscriptPixelsMatch(
            screenshotB,
            reopenedScreenshotB,
            label: "position B"
        )
    }

    func testBoundedTranscriptRevealsWhileMessageRefreshIsStillLoading() throws {
        let resetButton = app.buttons["scroll-lab-reset"]
        XCTAssertTrue(
            resetButton.waitForExistence(timeout: 15),
            "The deterministic transcript lab did not launch."
        )
        resetButton.tap()

        app.terminate()
        app.launchArguments = [
            "--scroll-restoration-lab",
            "--scroll-restoration-lab-loading",
        ]
        app.launch()

        let startedAt = Date()
        openTranscript()
        _ = try waitForStableReadyProbe(timeout: 12)

        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            12,
            "The bounded transcript did not reveal promptly while refresh remained in flight."
        )
        XCTAssertFalse(
            app.activityIndicators["Restoring conversation position"].exists,
            "Legacy restoration blocked a bounded transcript behind a spinner."
        )
    }

    func testMissingSavedAnchorFallsBackWithoutLoadingOlderPages() throws {
        app.terminate()
        app.launchArguments = [
            "--scroll-restoration-lab",
            "--scroll-restoration-lab-has-older",
        ]
        app.launch()

        let seedButton = app.buttons["scroll-lab-seed-missing-position"]
        XCTAssertTrue(
            seedButton.waitForExistence(timeout: 15),
            "The deterministic transcript lab did not launch."
        )
        seedButton.tap()

        openTranscript()
        let fallbackPosition = try waitForStableReadyProbe()
        assertInitialResolution(
            "missing-anchor-fallback",
            message: "The unavailable saved row was not classified as a fallback."
        )
        XCTAssertEqual(
            fallbackPosition.renderID,
            "transcript:1000",
            "Falling back replaced the unavailable saved reading position."
        )

        let loadProbe =
            app.otherElements["scroll-lab-older-load-count-probe"]
        XCTAssertTrue(
            loadProbe.waitForExistence(timeout: 3),
            "The older-page request probe is missing."
        )
        XCTAssertTrue(
            waitForElementValue("older-loads-0", in: loadProbe, timeout: 2),
            "Restoration paged backward to chase an anchor outside the bounded window."
        )
        let latestButton = app.buttons["Scroll to latest message"]
        let didSettleAtLatest = waitForStableNonExistence(
            latestButton,
            timeout: 3
        )
        let stateProbe = app.otherElements["scroll-lab-state-probe"]
        let stateDiagnostic =
            stateProbe.value as? String ?? "<missing state probe>"
        XCTAssertTrue(
            didSettleAtLatest,
            "Missing-anchor fallback did not leave the bounded transcript at latest"
                + " (state: \(stateDiagnostic))."
        )

        leaveTranscript()
        openTranscript()
        let reopenedFallbackPosition = try waitForStableReadyProbe()
        assertInitialResolution(
            "missing-anchor-fallback",
            message: "Repeated unavailable-row restoration changed resolution."
        )
        XCTAssertEqual(
            reopenedFallbackPosition.rawValue,
            fallbackPosition.rawValue,
            "Missing-anchor fallback overwrote the unavailable saved position."
        )
        XCTAssertTrue(
            waitForStableNonExistence(
                app.buttons["Scroll to latest message"],
                timeout: 3
            ),
            "Repeated missing-anchor fallback did not settle at latest."
        )
        XCTAssertTrue(
            waitForElementValue("older-loads-0", in: loadProbe, timeout: 2),
            "Repeated restoration paged backward instead of using one bounded fallback."
        )
    }

    func testSavedAnchorOutsideLatestTailUsesOneTargetedWindowAndRestoresExactly()
        throws
    {
        app.terminate()
        app.launchArguments = [
            "--scroll-restoration-lab",
            "--scroll-restoration-lab-targeted-history",
        ]
        app.launch()

        let seedButton = app.buttons["scroll-lab-seed-targeted-position"]
        XCTAssertTrue(
            seedButton.waitForExistence(timeout: 15),
            "The deterministic transcript lab did not launch."
        )
        seedButton.tap()

        openTranscript()
        let racePhaseProbe =
            app.otherElements["scroll-lab-latest-before-target-probe"]
        XCTAssertTrue(
            racePhaseProbe.waitForExistence(timeout: 2),
            "The latest-before-target timing probe is missing."
        )
        XCTAssertTrue(
            waitForElementValue(
                "latest-before-target-pending",
                in: racePhaseProbe,
                timeout: 3
            ),
            "The test did not observe latest arriving while the saved window was still pending."
        )
        XCTAssertTrue(
            app.otherElements["chat-transcript-loading-skeleton"]
                .waitForExistence(timeout: 2),
            "The pending saved-window state became a blank transcript instead of a loading skeleton."
        )
        let raceTailFlashProbe =
            app.otherElements["scroll-lab-tail-flash-probe"]
        XCTAssertEqual(
            raceTailFlashProbe.value as? String,
            "tail-flash-0",
            "The newest tail flashed before the saved historical window arrived."
        )

        let restoredPosition = try waitForStableReadyProbe()
        assertInitialResolution(
            "restored",
            message: "The targeted historical row fell back instead of restoring."
        )
        XCTAssertEqual(
            restoredPosition.rawValue,
            "ready|transcript:2092|scroll-lab-message-81|42.000",
            "The targeted historical window did not restore the exact saved viewport."
        )
        XCTAssertTrue(
            app.buttons["Scroll to latest message"].waitForExistence(timeout: 3),
            "A targeted historical restoration incorrectly appeared at latest."
        )
        let loadProbe =
            app.otherElements["scroll-lab-targeted-load-count-probe"]
        XCTAssertTrue(
            loadProbe.waitForExistence(timeout: 3),
            "The targeted-load request probe is missing."
        )
        XCTAssertTrue(
            waitForElementValue("targeted-loads-1", in: loadProbe, timeout: 2),
            "Restoration made more or fewer than one targeted historical load."
        )
        let latestLoadProbe =
            app.otherElements["scroll-lab-latest-load-count-probe"]
        XCTAssertTrue(
            latestLoadProbe.waitForExistence(timeout: 3),
            "The concurrent latest-load probe is missing."
        )
        XCTAssertTrue(
            waitForElementValue(
                "latest-loads-1",
                in: latestLoadProbe,
                timeout: 2
            ),
            "The lab did not deliver latest before checking for a tail flash."
        )
        let tailFlashProbe =
            app.otherElements["scroll-lab-tail-flash-probe"]
        XCTAssertTrue(
            tailFlashProbe.waitForExistence(timeout: 3),
            "The unrelated-tail exposure probe is missing."
        )
        XCTAssertTrue(
            waitForElementValue(
                "tail-flash-0",
                in: tailFlashProbe,
                timeout: 2
            ),
            "The newest tail was presented before the saved historical window."
        )
        let beforeReopen =
            captureScreenshot(named: "Targeted position before reopening")

        leaveTranscript()
        openTranscript()
        let reopenedPosition = try waitForStableReadyProbe()
        assertInitialResolution(
            "restored",
            message: "Reopening the targeted row fell back instead of restoring."
        )
        XCTAssertEqual(
            reopenedPosition.rawValue,
            restoredPosition.rawValue,
            "Reopening did not reproduce the targeted saved viewport."
        )
        XCTAssertTrue(
            waitForElementValue("targeted-loads-1", in: loadProbe, timeout: 2),
            "Reopening did not use exactly one targeted historical load."
        )
        XCTAssertTrue(
            waitForElementValue(
                "latest-loads-1",
                in: latestLoadProbe,
                timeout: 2
            ),
            "Reopening did not exercise a concurrent latest response."
        )
        XCTAssertTrue(
            waitForElementValue(
                "tail-flash-0",
                in: tailFlashProbe,
                timeout: 2
            ),
            "Reopening exposed the newest tail before the saved window."
        )
        let afterReopen =
            captureScreenshot(named: "Targeted position after reopening")
        assertTranscriptPixelsMatch(
            beforeReopen,
            afterReopen,
            label: "targeted historical position"
        )
    }

    func testMissingAnchorFallbackTracksDelayedLayoutBeforeReleasingBottomLock()
        throws
    {
        app.terminate()
        app.launchArguments = [
            "--scroll-restoration-lab",
            "--scroll-restoration-lab-has-older",
            "--scroll-restoration-lab-delayed-fallback-layout",
        ]
        app.launch()

        let seedButton = app.buttons["scroll-lab-seed-missing-position"]
        XCTAssertTrue(
            seedButton.waitForExistence(timeout: 15),
            "The deterministic transcript lab did not launch."
        )
        seedButton.tap()

        openTranscript()
        _ = try waitForStableReadyProbe()
        assertInitialResolution(
            "missing-anchor-fallback",
            message: "The unavailable saved row was not classified as a fallback."
        )

        let layoutProbe =
            app.otherElements["scroll-lab-delayed-layout-probe"]
        XCTAssertTrue(
            layoutProbe.waitForExistence(timeout: 3),
            "The delayed-layout probe is missing."
        )
        XCTAssertTrue(
            waitForElementValue(
                "layout-expanded",
                in: layoutProbe,
                timeout: 4
            ),
            "The deterministic delayed transcript expansion did not run."
        )

        // Let the size change propagate beyond the old ~200 ms early-release
        // window, then prove the bounded lock followed the new true bottom.
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(
            waitForStableNonExistence(
                app.buttons["Scroll to latest message"],
                timeout: 3
            ),
            "Delayed row growth stranded missing-anchor fallback above latest."
        )

        let transcriptViewport =
            app.otherElements["chat-transcript-viewport"]
        XCTAssertTrue(
            transcriptViewport.waitForExistence(timeout: 10),
            "The identified transcript viewport is missing."
        )
        dragTowardOlderMessages(in: transcriptViewport)
        XCTAssertTrue(
            app.buttons["Scroll to latest message"].waitForExistence(
                timeout: 3
            ),
            "A real user scroll did not take control after fallback settlement."
        )
    }

    func testFallbackWindowSwapDoesNotOverwriteUnavailableSavedPosition()
        throws
    {
        app.terminate()
        app.launchArguments = [
            "--scroll-restoration-lab",
            "--scroll-restoration-lab-has-older",
            "--scroll-restoration-lab-fallback-window-swap",
        ]
        app.launch()

        let seedButton = app.buttons["scroll-lab-seed-missing-position"]
        XCTAssertTrue(
            seedButton.waitForExistence(timeout: 15),
            "The deterministic transcript lab did not launch."
        )
        seedButton.tap()

        openTranscript()
        let expectedPosition = try waitForStableReadyProbe()
        assertInitialResolution(
            "missing-anchor-fallback",
            message: "The unavailable saved row was not classified as a fallback."
        )
        XCTAssertEqual(
            expectedPosition.rawValue,
            "ready|transcript:1000|scroll-lab-message-outside-window|42.000"
        )

        let countProbe =
            app.otherElements["scroll-lab-message-count-probe"]
        XCTAssertTrue(
            waitForElementValue("messages-50", in: countProbe, timeout: 3),
            "Fallback did not swap the historical page back to the latest tail."
        )

        // Wait beyond the bounded fallback lock and its reading-position
        // commit debounce. An automatic 400 -> 50 count transition must not
        // turn the latest tail into reader intent.
        Thread.sleep(forTimeInterval: 2.0)
        let settledPosition = try ProbeValue(
            rawValue: probeElement.value as? String ?? "<missing>"
        )
        XCTAssertEqual(
            settledPosition.rawValue,
            expectedPosition.rawValue,
            "Fallback's automatic latest-window swap overwrote the saved anchor."
        )

        leaveTranscript()
        openTranscript()
        let reopenedPosition = try waitForStableReadyProbe()
        assertInitialResolution(
            "missing-anchor-fallback",
            message: "Reopening the unavailable row changed resolution."
        )
        XCTAssertEqual(
            reopenedPosition.rawValue,
            expectedPosition.rawValue,
            "Reopening proved fallback persisted the latest tail instead of the saved anchor."
        )
    }

    func testComposerKeepsFocusWhileBoundedResponseChangesTranscript() throws {
        let resetButton = app.buttons["scroll-lab-reset"]
        XCTAssertTrue(
            resetButton.waitForExistence(timeout: 15),
            "The deterministic transcript lab did not launch."
        )
        resetButton.tap()

        openTranscript()
        _ = try waitForStableReadyProbe()
        XCTAssertFalse(
            app.buttons["Scroll to latest message"].exists,
            "The keyboard test must begin at latest to exercise bottom anchoring."
        )

        let sendResult = sendSimulatedMessage("Mem0 bounded-response question")
        let composer = sendResult.composer
        let focusProbe = app.otherElements["scroll-lab-composer-focus-probe"]
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(
            waitForStableNonExistence(
                app.buttons["Scroll to latest message"],
                timeout: 3
            ),
            "Response completion left the focused transcript away from latest."
        )

        // The production failure resigned a newly focused UITextView while the
        // response completion changed transcript size.
        guard focusProbe.value as? String == "focused" else {
            XCTFail("The composer lost keyboard focus during response completion.")
            return
        }
        if sendResult.observedSoftwareKeyboard {
            XCTAssertTrue(
                keyboard.exists || keyboard.waitForExistence(timeout: 1),
                "The software keyboard closed during response completion."
            )
        }

        let message = "Mem0 composer remains usable"
        composer.typeText(message)
        XCTAssertTrue(
            waitForElementValue(message, in: composer, timeout: 3),
            "Typing did not reach the focused composer."
        )

        XCTAssertEqual(
            focusProbe.value as? String,
            "focused",
            "The composer lost focus while the keyboard remained in use."
        )
    }

    func testTranscriptRemainsScrollableAfterBoundedResponseCompletion() throws {
        let resetButton = app.buttons["scroll-lab-reset"]
        XCTAssertTrue(
            resetButton.waitForExistence(timeout: 15),
            "The deterministic transcript lab did not launch."
        )
        resetButton.tap()

        openTranscript()
        _ = try waitForStableReadyProbe()

        _ = sendSimulatedMessage("Exercise post-completion scrolling")
        let latestButton = app.buttons["Scroll to latest message"]
        XCTAssertTrue(
            waitForStableNonExistence(latestButton, timeout: 3),
            "Response completion did not settle at latest before scrolling."
        )
        let transcriptViewport =
            app.otherElements["chat-transcript-viewport"]
        XCTAssertTrue(
            transcriptViewport.waitForExistence(timeout: 10),
            "The identified transcript viewport is missing."
        )
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            // The focus test separately proves that completion preserves the
            // keyboard. Settle it before measuring transcript gestures.
            transcriptViewport.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)
            ).tap()
            XCTAssertTrue(
                waitForStableNonExistence(keyboard, timeout: 3),
                "The software keyboard did not dismiss before scroll timing."
            )
        }
        var previousScreenshot =
            captureScreenshot(named: "Post-completion scroll start")

        for cycle in 1...2 {
            let dragStartedAt = Date()
            dragTowardOlderMessages(in: transcriptViewport)
            XCTAssertLessThan(
                Date().timeIntervalSince(dragStartedAt),
                maximumScrollResponseLatency,
                "Scroll cycle \(cycle) responded too slowly for usable interaction."
            )
            XCTAssertTrue(
                latestButton.waitForExistence(timeout: 3),
                "Scroll cycle \(cycle) did not move the transcript away from latest."
            )
            let currentScreenshot =
                captureScreenshot(named: "Post-completion scroll cycle \(cycle)")
            assertTranscriptPixelsDiffer(
                previousScreenshot,
                currentScreenshot,
                label: "scroll cycle \(cycle)"
            )
            previousScreenshot = currentScreenshot
        }
    }

    private func openTranscript() {
        let openButton = app.buttons["scroll-lab-open"]
        XCTAssertTrue(
            openButton.waitForExistence(timeout: 10),
            "The scroll lab's Open Transcript button is missing."
        )
        openButton.tap()

        XCTAssertTrue(
            probeElement.waitForExistence(timeout: 10),
            "The transcript position probe did not appear."
        )
    }

    private func leaveTranscript() {
        let navigationBar = app.navigationBars["Deterministic Transcript"]
        XCTAssertTrue(
            navigationBar.waitForExistence(timeout: 10),
            "The deterministic transcript navigation bar is missing."
        )

        let backButton = navigationBar.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.exists, "The transcript Back button is missing.")
        backButton.tap()

        XCTAssertTrue(
            app.buttons["scroll-lab-open"].waitForExistence(timeout: 10),
            "The scroll lab did not reappear after leaving the transcript."
        )
    }

    private func dragTowardOlderMessages(in transcriptViewport: XCUIElement) {
        // A focused UITextView is itself exposed as a ScrollView. Target the
        // production transcript container explicitly so this gesture cannot
        // be redirected into the composer after a response completes.
        transcriptViewport.swipeDown(velocity: .fast)
    }

    @discardableResult
    private func sendSimulatedMessage(
        _ message: String
    ) -> SimulatedSendResult {
        let composer = app.textViews.firstMatch
        XCTAssertTrue(
            composer.waitForExistence(timeout: 10),
            "The deterministic composer text view is missing."
        )
        composer.tap()

        let focusProbe = app.otherElements["scroll-lab-composer-focus-probe"]
        XCTAssertTrue(
            waitForElementValue("focused", in: focusProbe, timeout: 3),
            "The composer did not gain keyboard focus."
        )

        let keyboard = app.keyboards.firstMatch
        // Some Simulator hosts route typing through a connected hardware
        // keyboard. When the software keyboard is present, assert that it
        // survives completion; first-responder typing below remains mandatory
        // in either configuration.
        let observedSoftwareKeyboard =
            keyboard.waitForExistence(timeout: 1)

        composer.typeText(message)
        XCTAssertTrue(
            waitForElementValue(message, in: composer, timeout: 3),
            "The simulated outgoing message did not reach the composer."
        )

        let sendButton = app.buttons["scroll-lab-send"]
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 3),
            "The deterministic send button is missing."
        )
        XCTAssertTrue(
            waitForElementToBecomeEnabled(sendButton, timeout: 3),
            "The deterministic send button did not enable for a non-empty draft."
        )
        sendButton.tap()

        let responseProbe = app.otherElements["scroll-lab-response-probe"]
        XCTAssertTrue(
            waitForElementValue("complete", in: responseProbe, timeout: 10),
            "The simulated bounded response did not complete."
        )

        return SimulatedSendResult(
            composer: composer,
            observedSoftwareKeyboard: observedSoftwareKeyboard
        )
    }

    private var probeElement: XCUIElement {
        app.otherElements["scroll-position-probe"]
    }

    private func assertInitialResolution(
        _ expectedValue: String,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolutionProbe =
            app.otherElements["scroll-lab-initial-resolution-probe"]
        XCTAssertTrue(
            resolutionProbe.waitForExistence(timeout: 3),
            "The initial-resolution probe is missing.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            waitForElementValue(
                expectedValue,
                in: resolutionProbe,
                timeout: 3
            ),
            message,
            file: file,
            line: line
        )
    }

    private func waitForElementValue(
        _ expectedValue: String,
        in element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if element.value as? String == expectedValue {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        return element.value as? String == expectedValue
    }

    private func waitForElementToBecomeEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if element.isEnabled {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        return element.isEnabled
    }

    private func waitForStableNonExistence(
        _ element: XCUIElement,
        stableFor stableDuration: TimeInterval = 0.35,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var absentSince: Date?

        while Date() < deadline {
            if element.exists {
                absentSince = nil
            } else if let absentSince {
                if Date().timeIntervalSince(absentSince) >= stableDuration {
                    return true
                }
            } else {
                absentSince = Date()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        return false
    }

    private func waitForStableReadyProbe(
        differentFrom excludedValue: String? = nil,
        timeout: TimeInterval = 15
    ) throws -> ProbeValue {
        // Accessibility snapshots can themselves trigger SwiftUI layout work.
        // Leave the production restoration verifier an untouched quiet window
        // before polling its diagnostic value.
        Thread.sleep(forTimeInterval: 2.0)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = probeElement.value as? String,
               value.hasPrefix("ready|"),
               value != excludedValue {
                // `ready` is emitted only after the production transcript
                // shell has resolved its initial state. A second full-tree
                // accessibility snapshot can take longer than the interaction
                // latency under test for the 400-row fixture.
                print("Ready scroll probe: \(value)")
                let stateProbe = app.otherElements["scroll-lab-state-probe"]
                print(
                    "Scroll state probe: "
                        + (stateProbe.value as? String ?? "<missing>")
                )
                return try ProbeValue(rawValue: value)
            }

            Thread.sleep(forTimeInterval: 0.2)
        }

        let observedValue = probeElement.value as? String ?? "<missing>"
        let restorationIndicator =
            app.activityIndicators["Restoring conversation position"]
        let restorationDiagnostic: String
        if restorationIndicator.exists {
            restorationDiagnostic =
                restorationIndicator.value as? String ?? "<missing value>"
        } else {
            restorationDiagnostic = "<missing>"
        }
        XCTFail(
            "The scroll position probe did not stabilize"
                + (excludedValue.map { " at a value different from \($0)" } ?? "")
                + ". Last value: \(observedValue)."
                + " Restoration diagnostic: \(restorationDiagnostic)"
        )
        throw ProbeError.didNotStabilize
    }

    private func captureScreenshot(named name: String) -> XCUIScreenshot {
        // Let the transient scroll indicator disappear before comparing the
        // conversation pixels.
        Thread.sleep(forTimeInterval: 0.8)

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
        return screenshot
    }

    private func assertTranscriptPixelsMatch(
        _ before: XCUIScreenshot,
        _ after: XCUIScreenshot,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let beforeCrop = transcriptCrop(from: before.image),
              let afterCrop = transcriptCrop(from: after.image) else {
            XCTFail(
                "Could not crop the \(label) transcript screenshots.",
                file: file,
                line: line
            )
            return
        }

        guard let mismatchRatio = pixelMismatchRatio(
            beforeCrop,
            afterCrop,
            channelTolerance: 3
        ) else {
            XCTFail(
                "Could not compare the \(label) transcript screenshots.",
                file: file,
                line: line
            )
            return
        }

        XCTAssertLessThanOrEqual(
            mismatchRatio,
            0.001,
            "The visible transcript pixels changed after reopening \(label)"
                + " (mismatch ratio \(mismatchRatio)).",
            file: file,
            line: line
        )
    }

    private func assertTranscriptPixelsDiffer(
        _ before: XCUIScreenshot,
        _ after: XCUIScreenshot,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let beforeCrop = transcriptCrop(from: before.image),
              let afterCrop = transcriptCrop(from: after.image) else {
            XCTFail(
                "Could not crop the \(label) transcript screenshots.",
                file: file,
                line: line
            )
            return
        }

        guard let mismatchRatio = pixelMismatchRatio(
            beforeCrop,
            afterCrop,
            channelTolerance: 3
        ) else {
            XCTFail(
                "Could not compare the \(label) transcript screenshots.",
                file: file,
                line: line
            )
            return
        }

        XCTAssertGreaterThan(
            mismatchRatio,
            0.01,
            "The visible transcript did not move during \(label)"
                + " (mismatch ratio \(mismatchRatio)).",
            file: file,
            line: line
        )
    }

    private func transcriptCrop(from image: UIImage) -> CGImage? {
        guard let cgImage = image.cgImage else { return nil }

        // Exclude the status/navigation chrome and home-indicator region. The
        // remaining central band is entirely transcript content on every
        // supported iPhone size.
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let cropRect = CGRect(
            x: width * 0.03,
            y: height * 0.16,
            width: width * 0.94,
            height: height * 0.66
        ).integral

        return cgImage.cropping(to: cropRect)
    }

    private func pixelMismatchRatio(
        _ lhs: CGImage,
        _ rhs: CGImage,
        channelTolerance: UInt8
    ) -> Double? {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              let lhsPixels = rgbaPixels(from: lhs),
              let rhsPixels = rgbaPixels(from: rhs),
              lhsPixels.count == rhsPixels.count else {
            return nil
        }

        let tolerance = Int(channelTolerance)
        var mismatchedPixels = 0
        let pixelCount = lhs.width * lhs.height

        for pixelIndex in 0..<pixelCount {
            let byteIndex = pixelIndex * 4
            let redDifference = abs(
                Int(lhsPixels[byteIndex]) - Int(rhsPixels[byteIndex])
            )
            let greenDifference = abs(
                Int(lhsPixels[byteIndex + 1]) - Int(rhsPixels[byteIndex + 1])
            )
            let blueDifference = abs(
                Int(lhsPixels[byteIndex + 2]) - Int(rhsPixels[byteIndex + 2])
            )

            if max(redDifference, greenDifference, blueDifference) > tolerance {
                mismatchedPixels += 1
            }
        }

        return Double(mismatchedPixels) / Double(pixelCount)
    }

    private func rgbaPixels(from image: CGImage) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = image.width * bytesPerPixel
        var pixels = [UInt8](
            repeating: 0,
            count: image.height * bytesPerRow
        )

        guard let context = CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return pixels
    }
}

private struct SimulatedSendResult {
    let composer: XCUIElement
    let observedSoftwareKeyboard: Bool
}

private struct ProbeValue {
    let rawValue: String

    var renderID: String? {
        let components = rawValue.split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        guard components.count == 4 else { return nil }
        return String(components[1])
    }

    init(rawValue: String) throws {
        if rawValue == "ready|none" {
            self.rawValue = rawValue
            return
        }

        let components = rawValue.split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        guard components.count == 4,
              components[0] == "ready",
              components[1].hasPrefix("transcript:"),
              Double(components[3]) != nil else {
            throw ProbeError.malformedValue(rawValue)
        }

        self.rawValue = rawValue
    }
}

private enum ProbeError: Error {
    case didNotStabilize
    case malformedValue(String)
}
