import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class CronManagementModelTests: XCTestCase {
    func testCronMutationResponseDecodesAliasesAndStringSchedule() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(
            CronMutationResponse.self,
            from: Data("""
            {
              "ok": true,
              "job": {
                "job_id": "job-aliased",
                "name": "Aliased task",
                "prompt": 42,
                "schedule": "0 9 * * *",
                "enabled": "true",
                "state": "scheduled",
                "model": "@openai:gpt-5.5",
                "profile": "work",
                "toast_notifications": "yes"
              }
            }
            """.utf8)
        )

        let job = try XCTUnwrap(response.job)
        XCTAssertEqual(job.jobId, "job-aliased")
        XCTAssertEqual(job.prompt, "42")
        XCTAssertEqual(job.scheduleText, "0 9 * * *")
        XCTAssertTrue(try XCTUnwrap(job.readableScheduleText).hasPrefix("Every day at "))
        XCTAssertNotEqual(job.readableScheduleText, job.scheduleText)
        XCTAssertEqual(job.status, .active)
        XCTAssertEqual(job.model, "@openai:gpt-5.5")
        XCTAssertEqual(job.profile, "work")
        XCTAssertEqual(job.toastNotifications, true)
    }

    func testCronJobEditorDraftNormalizesFieldsAndSkills() {
        let draft = CronJobEditorDraft(
            name: "  Morning digest  ",
            prompt: "  Summarize updates  ",
            schedule: "  0 7 * * *  ",
            deliver: "  local  ",
            skillsText: "summarize, notify\nswift",
            model: "  @openai:gpt-5.5  ",
            provider: "  openai  ",
            profile: "  work  ",
            toastNotifications: true
        )

        XCTAssertEqual(draft.trimmedName, "Morning digest")
        XCTAssertEqual(draft.trimmedPrompt, "Summarize updates")
        XCTAssertEqual(draft.trimmedSchedule, "0 7 * * *")
        XCTAssertEqual(draft.trimmedDeliver, "local")
        XCTAssertEqual(draft.skills, ["summarize", "notify", "swift"])
        XCTAssertEqual(draft.trimmedModel, "@openai:gpt-5.5")
        XCTAssertEqual(draft.trimmedProvider, "openai")
        XCTAssertEqual(draft.trimmedProfile, "work")
        XCTAssertNil(draft.validationMessage)
    }

    func testCronJobEditorDraftRoundTripsUnknownDeliverAndProvider() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let job = try decoder.decode(
            CronJob.self,
            from: Data("""
            {
              "id": "job-legacy",
              "prompt": "Run it",
              "schedule": "0 7 * * *",
              "deliver": "legacy-target",
              "provider": "openai"
            }
            """.utf8)
        )

        let draft = CronJobEditorDraft(job: job)

        XCTAssertEqual(draft.deliver, "legacy-target")
        XCTAssertEqual(draft.trimmedDeliver, "legacy-target")
        XCTAssertEqual(draft.provider, "openai")
    }

    func testCronDeliverPickerFallsBackWithoutUsableOptions() {
        XCTAssertNil(CronDeliverPicker.options(serverOptions: nil, currentValue: "local"))
        XCTAssertNil(CronDeliverPicker.options(serverOptions: [], currentValue: "local"))
        XCTAssertNil(
            CronDeliverPicker.options(
                serverOptions: [CronDeliveryOption(value: "  ", label: "Blank"), CronDeliveryOption(value: nil, label: "No value")],
                currentValue: "local"
            )
        )
        XCTAssertNil(
            CronDeliverPicker.options(
                serverOptions: [CronDeliveryOption(value: "local", label: "Local")],
                currentValue: "   "
            ),
            "A blank draft value has nothing safe to select, so free text is kept."
        )
    }

    func testCronDeliverPickerKeepsUnknownValueAsCustomRow() throws {
        let serverOptions = [
            CronDeliveryOption(value: "local", label: "Local (save output only)"),
            CronDeliveryOption(value: "origin", label: "Origin (reply to creator)"),
            CronDeliveryOption(value: "origin", label: "Duplicate ignored"),
            CronDeliveryOption(value: "telegram", label: nil)
        ]

        let options = try XCTUnwrap(
            CronDeliverPicker.options(serverOptions: serverOptions, currentValue: "legacy-target")
        )

        XCTAssertEqual(options.map(\.value), ["local", "origin", "telegram", "legacy-target"])
        XCTAssertEqual(options.map(\.isCustom), [false, false, false, true])
        XCTAssertEqual(options.first?.label, "Local (save output only)")
        XCTAssertEqual(options[2].label, "telegram", "Missing labels fall back to the raw value.")

        let knownValue = try XCTUnwrap(
            CronDeliverPicker.options(serverOptions: serverOptions, currentValue: "origin")
        )
        XCTAssertEqual(knownValue.map(\.value), ["local", "origin", "telegram"])
        XCTAssertFalse(knownValue.contains(where: \.isCustom))
    }

    func testCronDeliverPickerPreservesInitialAndLiveCustomValues() throws {
        let serverOptions = [
            CronDeliveryOption(value: "local", label: "Local"),
            CronDeliveryOption(value: "telegram", label: "Telegram")
        ]

        // The editor's initial legacy value keeps its custom row even after
        // the user selects a server option (currentValue moved on).
        let afterSelection = try XCTUnwrap(
            CronDeliverPicker.options(
                serverOptions: serverOptions,
                currentValue: "telegram",
                initialValue: "legacy-target"
            )
        )
        XCTAssertEqual(afterSelection.map(\.value), ["local", "telegram", "legacy-target"])
        XCTAssertEqual(afterSelection.map(\.isCustom), [false, false, true])

        // A value typed into the free-text fallback while options were still
        // loading gets its own row alongside the initial value's row, so the
        // picker selection always has a matching tag.
        let typedWhileLoading = try XCTUnwrap(
            CronDeliverPicker.options(
                serverOptions: serverOptions,
                currentValue: "typed-target",
                initialValue: "local"
            )
        )
        XCTAssertEqual(typedWhileLoading.map(\.value), ["local", "telegram", "typed-target"])
        XCTAssertEqual(typedWhileLoading.map(\.isCustom), [false, false, true])

        // Identical initial and current custom values collapse to one row.
        let sameCustom = try XCTUnwrap(
            CronDeliverPicker.options(
                serverOptions: serverOptions,
                currentValue: "legacy-target",
                initialValue: "legacy-target"
            )
        )
        XCTAssertEqual(sameCustom.map(\.value), ["local", "telegram", "legacy-target"])
        XCTAssertEqual(sameCustom.filter(\.isCustom).count, 1)

        // A blank initial value adds no row.
        let blankInitial = try XCTUnwrap(
            CronDeliverPicker.options(
                serverOptions: serverOptions,
                currentValue: "local",
                initialValue: "   "
            )
        )
        XCTAssertEqual(blankInitial.map(\.value), ["local", "telegram"])
    }

    func testCronJobEditorDraftRequiresPromptAndSchedule() {
        XCTAssertEqual(
            CronJobEditorDraft(prompt: "", schedule: "0 7 * * *").validationMessage,
            "Prompt is required."
        )
        XCTAssertEqual(
            CronJobEditorDraft(prompt: "Run it", schedule: "   ").validationMessage,
            "Schedule is required."
        )
    }

    func testCronScheduleFormatterMakesCommonExpressionsReadable() {
        let locale = Locale(identifier: "en_US")
        func normalized(_ value: String?) -> String? {
            value?.replacingOccurrences(of: "\u{202F}", with: " ")
        }

        XCTAssertEqual(normalized(CronScheduleFormatter.readableText(for: "0 16 * * *", locale: locale)), "Every day at 4:00 PM")
        XCTAssertEqual(normalized(CronScheduleFormatter.readableText(for: "30 8 * * 1-5", locale: locale)), "Weekdays at 8:30 AM")
        XCTAssertEqual(CronScheduleFormatter.readableText(for: "*/15 * * * *", locale: locale), "Every 15 minutes")
        XCTAssertEqual(CronScheduleFormatter.readableText(for: "every 2h", locale: locale), "Every 2 hours")
        XCTAssertEqual(CronScheduleFormatter.readableText(for: "30m", locale: locale), "Every 30 minutes")
        XCTAssertEqual(CronScheduleFormatter.readableText(for: "every 60m", locale: locale), "Every hour")
        XCTAssertEqual(CronScheduleFormatter.readableText(for: "every 360m", locale: locale), "Every 6 hours")
        XCTAssertNil(CronScheduleFormatter.readableText(for: "0 9 1 1 *", locale: locale))
    }

    func testCronScheduleFormatterUsesNextRunForLocalTime() throws {
        let nextRun = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-15T16:00:00Z"))
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let result = CronScheduleFormatter.readableText(
            for: "0 16 * * *",
            nextRunAt: nextRun,
            locale: Locale(identifier: "en_US"),
            timeZone: timeZone
        )?.replacingOccurrences(of: "\u{202F}", with: " ")

        XCTAssertEqual(result, "Every day at 9:00 AM")
    }

    func testCronOutputResultKeepsOnlyResponseSection() throws {
        let output = try decodeCronOutput(
            filename: "2026-07-13_16-04-29.md",
            content: """
            # Cron Job: Refund Monitor

            **Run Time:** 2026-07-13 16:04:29

            ## Prompt

            [IMPORTANT: scheduled cron boilerplate]

            Check the refund and report the result.

            ## Response

            Refund has **not** arrived yet.
            """
        )

        XCTAssertEqual(output.resultText, "Refund has **not** arrived yet.")
        XCTAssertFalse(try XCTUnwrap(output.formattedRunTime).contains(".md"))
    }

    func testCronOutputFilenameIsInterpretedAsUTC() throws {
        let output = try decodeCronOutput(filename: "2026-07-13_16-04-29.md", content: "All clear.")
        let date = try XCTUnwrap(output.runDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))

        XCTAssertEqual(calendar.component(.hour, from: date), 9)
    }

    func testCronOutputResultFallsBackForLegacyPlainText() throws {
        let output = try decodeCronOutput(filename: "legacy.md", content: "All clear.")

        XCTAssertEqual(output.resultText, "All clear.")
        XCTAssertNil(output.formattedRunTime)
    }

    func testCronOutputResultMakesSilentSentinelReadable() throws {
        let output = try decodeCronOutput(filename: "2026-07-13_16-04-29.md", content: "## Response\n\n[SILENT]")

        XCTAssertEqual(output.resultText, "No new update.")
    }

    func testCronOutputResultHidesSilentScriptMetadata() throws {
        let output = try decodeCronOutput(
            filename: "2026-07-14_17-53-21.md",
            content: """
            # Cron Job: Grade A Tools Tracking Monitor

            **Job ID:** 9b3738a7bbb2
            **Run Time:** 2026-07-14 17:53:21
            **Mode:** no_agent (script)
            **Status:** silent (empty output)
            """
        )

        XCTAssertEqual(output.resultText, "No new update.")
    }

    func testCronOutputResultKeepsOnlyScriptStdout() throws {
        let output = try decodeCronOutput(
            filename: "2026-07-14_17-53-21.md",
            content: """
            # Cron Job: Tracking Monitor

            **Job ID:** abc123
            **Run Time:** 2026-07-14 17:53:21
            **Mode:** no_agent (script)

            ---

            Shipment **delivered** today.
            """
        )

        XCTAssertEqual(output.resultText, "Shipment **delivered** today.")
    }

    func testCronOutputResultKeepsScriptFailureWithoutMetadata() throws {
        let output = try decodeCronOutput(
            filename: "2026-07-14_17-53-21.md",
            content: """
            # Cron Job: Tracking Monitor

            **Job ID:** abc123
            **Run Time:** 2026-07-14 17:53:21
            **Mode:** no_agent (script)
            **Status:** script failed

            FedEx API timed out.
            """
        )

        XCTAssertEqual(output.resultText, "FedEx API timed out.")
    }

    func testCronOutputResultRecognizesDocumentedSilenceVariants() throws {
        for marker in ["SILENT", "NO_REPLY", "No reply", "[SILENT] Nothing changed"] {
            let output = try decodeCronOutput(filename: "2026-07-14_17-53-21.md", content: marker)
            XCTAssertEqual(output.resultText, "No new update.")
        }
    }

    func testCronDescriptionSummaryKeepsFullPromptSeparate() throws {
        let job = try decodeCronJob(
            """
            {
              "id": "refund",
              "name": "Refund monitor",
              "prompt": "Check the status of return #20374. Run this shell command and report the result:\\n\\nssh example"
            }
            """
        )

        XCTAssertEqual(job.descriptionSummary, "Check the status of return #20374.")
        XCTAssertTrue(try XCTUnwrap(job.prompt).contains("ssh example"))
    }

    func testCronTaskHistoryKeepsChangesAndSkipsSilentOrDuplicateRuns() throws {
        let oldest = try decodeCronOutput(filename: "2026-07-11_16-00-00.md", content: "## Response\nStatus A")
        let duplicate = try decodeCronOutput(filename: "2026-07-12_16-00-00.md", content: "## Response\nStatus A")
        let silent = try decodeCronOutput(filename: "2026-07-13_16-00-00.md", content: "## Response\n[SILENT]")
        let newest = try decodeCronOutput(filename: "2026-07-14_16-00-00.md", content: "## Response\nStatus B")

        let updates = CronTaskHistory.statusUpdates(from: [newest, silent, duplicate, oldest])

        XCTAssertEqual(updates.map(\.resultText), ["Status B", "Status A"])
    }

    func testCronRunSessionResolverMatchesEachAgentRunToItsExistingSession() throws {
        let job = try decodeCronJob(#"{"id": "job123", "name": "Digest", "profile": "work"}"#)
        let oldest = try decodeCronOutput(
            filename: "2026-07-14_08-03-00.md",
            content: "## Response\nFirst update"
        )
        let scriptOnly = try decodeCronOutput(
            filename: "2026-07-14_09-01-00.md",
            content: """
            # Cron Job: Digest
            **Mode:** no_agent (script)
            **Status:** completed
            ---
            Script update
            """
        )
        let latest = try decodeCronOutput(
            filename: "2026-07-14_10-05-00.md",
            content: "## Response\nLatest update"
        )
        let sessions = [
            SessionSummary(sessionId: "cron_job123_20260714_100000", profile: "work"),
            SessionSummary(sessionId: "cron_other_20260714_090000", profile: "work"),
            SessionSummary(sessionId: "cron_job123_20260714_080000", profile: "work")
        ]

        let resolved = CronRunSessionResolver.sessionsByOutputID(
            job: job,
            outputs: [latest, scriptOnly, oldest],
            sessions: sessions
        )

        XCTAssertEqual(resolved[oldest.id]?.sessionId, "cron_job123_20260714_080000")
        XCTAssertNil(resolved[scriptOnly.id], "Script-only runs do not create chat sessions.")
        XCTAssertEqual(resolved[latest.id]?.sessionId, "cron_job123_20260714_100000")
    }

    func testCronRunSessionResolverSkipsBlockedRunsAndOtherProfiles() throws {
        let job = try decodeCronJob(#"{"id": "job123", "name": "Digest", "profile": "work"}"#)
        let blocked = try decodeCronOutput(
            filename: "2026-07-14_11-01-00.md",
            content: """
            # Cron Job: Digest
            **Status:** blocked
            Request was rejected before an agent session started.
            """
        )
        let completed = try decodeCronOutput(
            filename: "2026-07-14_12-05-00.md",
            content: "## Response\nCompleted"
        )
        let sessions = [
            SessionSummary(sessionId: "cron_job123_20260714_120000", profile: "personal"),
            SessionSummary(sessionId: "cron_job123_20260714_110000", profile: "work")
        ]

        let resolved = CronRunSessionResolver.sessionsByOutputID(
            job: job,
            outputs: [completed, blocked],
            sessions: sessions
        )

        XCTAssertNil(resolved[blocked.id])
        XCTAssertNil(resolved[completed.id], "A session from a different profile must not be opened.")
    }

    func testCronSessionContextIncludesTaskSelectedRunAndCurrentStatus() throws {
        let job = try decodeCronJob(
            """
            {
              "id": "refund",
              "name": "Refund monitor",
              "prompt": "Check refund #20374 and contact support if needed.",
              "schedule": "0 16 * * *",
              "next_run_at": "2026-07-15T16:00:00Z"
            }
            """
        )
        let selected = try decodeCronOutput(filename: "2026-07-13_16-00-00.md", content: "## Response\nRefund missing for 32 days.")
        let latest = try decodeCronOutput(filename: "2026-07-14_16-00-00.md", content: "## Response\nRefund missing for 33 days.")

        let draft = CronSessionContextBuilder.draft(
            job: job,
            outputs: [latest, selected],
            selectedOutput: selected,
            momentTitle: "Status update"
        )

        XCTAssertTrue(draft.contains("Check refund #20374 and contact support if needed."))
        XCTAssertTrue(draft.contains("Refund missing for 32 days."))
        XCTAssertTrue(draft.contains("Refund missing for 33 days."))
        XCTAssertTrue(draft.contains("Help me decide or perform the next action"))
    }

    private func decodeCronJob(_ json: String) throws -> CronJob {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CronJob.self, from: Data(json.utf8))
    }

    private func decodeCronOutput(filename: String, content: String) throws -> CronOutputItem {
        let data = try JSONSerialization.data(withJSONObject: ["filename": filename, "content": content])
        return try JSONDecoder().decode(CronOutputItem.self, from: data)
    }
}

final class CronManagementViewModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testTasksViewModelCreateInsertsReturnedJob() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/create")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "job": {
                "id": "job-created",
                "name": "Created",
                "prompt": "Run it",
                "schedule": {"kind": "cron", "expr": "0 7 * * *"},
                "enabled": true,
                "state": "scheduled"
              }
            }
            """, for: request)
        }
        let viewModel = TasksViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        let didCreate = await viewModel.create(
            from: CronJobEditorDraft(
                name: "Created",
                prompt: "Run it",
                schedule: "0 7 * * *"
            )
        )

        XCTAssertTrue(didCreate)
        XCTAssertEqual(viewModel.jobs.map(\.jobId), ["job-created"])
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testTasksViewModelUpsertKeepsOneStableRowPerCronJob() throws {
        let viewModel = TasksViewModel(server: try XCTUnwrap(URL(string: "https://example.test")))
        let original = try decodeCronJob(
            #"{"id":"job123","name":"Digest","last_status":"ok","last_run_at":100}"#
        )
        let refreshed = try decodeCronJob(
            #"{"id":"job123","name":"Digest","last_status":"error","last_run_at":200}"#
        )

        viewModel.apply(.upsert(original))
        viewModel.apply(.upsert(refreshed))

        XCTAssertEqual(viewModel.jobs.count, 1)
        XCTAssertEqual(viewModel.jobs.first?.jobId, "job123")
        XCTAssertEqual(viewModel.jobs.first?.lastStatus, "error")
        XCTAssertEqual(viewModel.jobs.first?.lastRunAt?.date.timeIntervalSince1970, 200)
    }

    @MainActor
    func testTasksViewModelLoadPopulatesDeliveryOptions() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/crons":
                return apiTestJSONResponse(#"{"jobs": []}"#, for: request)
            case "/api/crons/status":
                return apiTestJSONResponse(#"{"running": {}}"#, for: request)
            case "/api/crons/delivery-options":
                return apiTestJSONResponse(
                    #"{"platforms": [{"value": "local", "label": "Local (save output only)"}]}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = TasksViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        await viewModel.load()

        XCTAssertEqual(viewModel.deliveryOptions?.count, 1)
        XCTAssertEqual(viewModel.deliveryOptions?.first?.value, "local")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testTasksViewModelLoadToleratesDeliveryOptionsFailure() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/crons":
                return apiTestJSONResponse(#"{"jobs": [{"id": "job123", "name": "Digest"}]}"#, for: request)
            case "/api/crons/status":
                return apiTestJSONResponse(#"{"running": {}}"#, for: request)
            case "/api/crons/delivery-options":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error": "not found"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = TasksViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        await viewModel.load()

        XCTAssertNil(viewModel.deliveryOptions, "Endpoint failure must fall back to free-text deliver entry.")
        XCTAssertEqual(viewModel.jobs.map(\.jobId), ["job123"], "Jobs must still load when delivery options fail.")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testTaskDetailViewModelLoadsExtendedRunHistory() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/crons/output":
                let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
                let query = Dictionary(uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value) } ?? [])
                XCTAssertEqual(query["job_id"] ?? nil, "job123")
                XCTAssertEqual(query["limit"] ?? nil, "500")
                return apiTestJSONResponse(
                    """
                    {"job_id":"job123","outputs":[{"filename":"2026-07-14_16-00-00.md","content":"## Response\\nLatest update"}]}
                    """,
                    for: request
                )
            case "/api/crons/delivery-options":
                return apiTestJSONResponse(#"{"platforms": []}"#, for: request)
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = TaskDetailViewModel(
            job: try decodeCronJob(#"{"id": "job123", "name": "Digest"}"#),
            runningElapsed: nil,
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.outputs.first?.resultText, "Latest update")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testTaskDetailViewModelPauseUpdatesJobAndPublishesMutation() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/pause")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "job": {
                "id": "job123",
                "name": "Digest",
                "prompt": "Run it",
                "schedule": {"kind": "cron", "expr": "0 7 * * *"},
                "enabled": true,
                "state": "paused"
              }
            }
            """, for: request)
        }
        let viewModel = TaskDetailViewModel(
            job: try decodeCronJob("""
            {
              "id": "job123",
              "name": "Digest",
              "prompt": "Run it",
              "schedule": {"kind": "cron", "expr": "0 7 * * *"},
              "enabled": true,
              "state": "scheduled"
            }
            """),
            runningElapsed: 12,
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        let didPause = await viewModel.pause()

        XCTAssertTrue(didPause)
        XCTAssertEqual(viewModel.job.status, .paused)
        XCTAssertNil(viewModel.runningElapsed)
        guard case .upsert(let updatedJob) = viewModel.lastMutation else {
            XCTFail("Expected upsert mutation.")
            return
        }
        XCTAssertEqual(updatedJob.jobId, "job123")
    }

    @MainActor
    func testTaskDetailViewModelDeletePublishesDeleteMutation() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/delete")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "job": {"id": "job123"}
            }
            """, for: request)
        }
        let viewModel = TaskDetailViewModel(
            job: try decodeCronJob(#"{"id": "job123", "name": "Digest"}"#),
            runningElapsed: nil,
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        let didDelete = await viewModel.delete()

        XCTAssertTrue(didDelete)
        XCTAssertEqual(viewModel.lastMutation, .delete(jobID: "job123"))
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        return APIClient(baseURL: URL(string: "https://example.test")!, session: session)
    }

    private func decodeCronJob(_ json: String) throws -> CronJob {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CronJob.self, from: Data(json.utf8))
    }
}
