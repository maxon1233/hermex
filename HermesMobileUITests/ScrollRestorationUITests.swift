import CoreGraphics
import UIKit
import XCTest

final class ScrollRestorationUITests: XCTestCase {
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

        dragTowardOlderMessages()
        let positionA = try waitForStableReadyProbe(differentFrom: initialPosition.rawValue)
        let screenshotA = captureScreenshot(named: "Position A before leaving")

        leaveTranscript()
        openTranscript()
        let restoredA = try waitForStableReadyProbe()
        XCTAssertEqual(
            restoredA.rawValue,
            positionA.rawValue,
            "The first reopen did not reproduce the exact saved viewport."
        )
        let reopenedScreenshotA = captureScreenshot(named: "Position A after reopening")
        assertTranscriptPixelsMatch(
            screenshotA,
            reopenedScreenshotA,
            label: "position A"
        )

        dragTowardOlderMessages()
        let positionB = try waitForStableReadyProbe(differentFrom: restoredA.rawValue)
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
            "The second reopen returned to the previous viewport instead of the latest one."
        )
        XCTAssertNotEqual(
            restoredB.rawValue,
            positionA.rawValue,
            "The second reopen regressed to position A."
        )
        let reopenedScreenshotB = captureScreenshot(named: "Position B after reopening")
        assertTranscriptPixelsMatch(
            screenshotB,
            reopenedScreenshotB,
            label: "position B"
        )
    }

    func testWarmCachedTranscriptRevealsBeforeMessageRefreshCompletes() throws {
        let resetButton = app.buttons["scroll-lab-reset"]
        XCTAssertTrue(
            resetButton.waitForExistence(timeout: 15),
            "The deterministic scroll-restoration lab did not launch."
        )
        resetButton.tap()

        openTranscript()
        let cachedPosition = try waitForStableReadyProbe()
        leaveTranscript()

        app.terminate()
        app.launchArguments = [
            "--scroll-restoration-lab",
            "--scroll-restoration-lab-loading",
        ]
        app.launch()

        openTranscript()
        let restoredPosition = try waitForStableReadyProbe()

        XCTAssertEqual(
            restoredPosition.rawValue,
            cachedPosition.rawValue,
            "The cached transcript did not reveal at its exact saved position while the refresh remained in flight."
        )
        XCTAssertFalse(
            app.activityIndicators["Restoring conversation position"].exists,
            "The restoration spinner remained over an already-restored cached transcript."
        )
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

    private func dragTowardOlderMessages() {
        let transcriptScrollView = app.scrollViews.firstMatch
        XCTAssertTrue(
            transcriptScrollView.waitForExistence(timeout: 10),
            "The transcript scroll view is missing."
        )

        let start = transcriptScrollView.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28)
        )
        let end = transcriptScrollView.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78)
        )
        start.press(forDuration: 0.12, thenDragTo: end)
    }

    private var probeElement: XCUIElement {
        app.otherElements["scroll-position-probe"]
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
        var previousValue: String?
        var consecutiveMatches = 0

        while Date() < deadline {
            if let value = probeElement.value as? String,
               value.hasPrefix("ready|"),
               value != excludedValue {
                if value == previousValue {
                    consecutiveMatches += 1
                } else {
                    previousValue = value
                    consecutiveMatches = 1
                }

                if consecutiveMatches >= 4 {
                    print("Stable scroll probe: \(value)")
                    return try ProbeValue(rawValue: value)
                }
            } else {
                previousValue = nil
                consecutiveMatches = 0
            }

            Thread.sleep(forTimeInterval: 0.2)
        }

        let observedValue = probeElement.value as? String ?? "<missing>"
        let restorationIndicator =
            app.activityIndicators["Restoring conversation position"]
        let restorationDiagnostic =
            restorationIndicator.value as? String ?? "<missing>"
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

private struct ProbeValue {
    let rawValue: String

    init(rawValue: String) throws {
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
