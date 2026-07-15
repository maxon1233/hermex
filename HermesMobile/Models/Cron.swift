import Foundation

struct CronJobsResponse: Decodable, Equatable {
    let jobs: [CronJob]?
}

struct CronMutationResponse: Decodable, Equatable {
    let ok: Bool?
    let job: CronJob?
    let error: String?
}

struct CronStatusResponse: Decodable, Equatable {
    let jobId: String?
    let running: Bool?
    let elapsed: Double?
    let runningJobs: [String: Double]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case jobId
        case running
        case elapsed
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try container.decodeIfPresent(String.self, forKey: .jobId)
        elapsed = try container.decodeFlexibleDoubleIfPresent(forKey: .elapsed)
        error = try container.decodeIfPresent(String.self, forKey: .error)

        running = (try? container.decodeIfPresent(Bool.self, forKey: .running)) ?? nil
        runningJobs = (try? container.decodeIfPresent([String: Double].self, forKey: .running)) ?? nil
    }
}

struct CronJob: Decodable, Equatable, Identifiable {
    var id: String {
        jobId ?? name ?? UUID().uuidString
    }

    let jobId: String?
    let name: String?
    let prompt: String?
    let schedule: CronSchedule?
    let scheduleDisplay: String?
    let enabled: Bool?
    let state: String?
    let nextRunAt: CronDateValue?
    let lastRunAt: CronDateValue?
    let lastStatus: String?
    let lastError: String?
    let lastDeliveryError: String?
    let repeatInfo: CronRepeat?
    let deliver: String?
    let skills: [String]?
    let model: String?
    let provider: String?
    let profile: String?
    let toastNotifications: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case jobId
        case name
        case prompt
        case schedule
        case scheduleDisplay
        case enabled
        case state
        case nextRunAt
        case lastRunAt
        case lastStatus
        case lastError
        case lastDeliveryError
        case repeatInfo = "repeat"
        case deliver
        case skills
        case model
        case provider
        case profile
        case toastNotifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobId = container.decodeLossyStringIfPresent(forKey: .id)
            ?? container.decodeLossyStringIfPresent(forKey: .jobId)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        prompt = container.decodeLossyStringIfPresent(forKey: .prompt)
        schedule = (try? container.decodeIfPresent(CronSchedule.self, forKey: .schedule)) ?? nil
        scheduleDisplay = container.decodeLossyStringIfPresent(forKey: .scheduleDisplay)
        enabled = container.decodeLossyBoolIfPresent(forKey: .enabled)
        state = container.decodeLossyStringIfPresent(forKey: .state)
        nextRunAt = (try? container.decodeIfPresent(CronDateValue.self, forKey: .nextRunAt)) ?? nil
        lastRunAt = (try? container.decodeIfPresent(CronDateValue.self, forKey: .lastRunAt)) ?? nil
        lastStatus = container.decodeLossyStringIfPresent(forKey: .lastStatus)
        lastError = container.decodeLossyStringIfPresent(forKey: .lastError)
        lastDeliveryError = container.decodeLossyStringIfPresent(forKey: .lastDeliveryError)
        repeatInfo = (try? container.decodeIfPresent(CronRepeat.self, forKey: .repeatInfo)) ?? nil
        deliver = container.decodeLossyStringIfPresent(forKey: .deliver)
        skills = (try? container.decodeIfPresent([String].self, forKey: .skills)) ?? nil
        model = container.decodeLossyStringIfPresent(forKey: .model)
        provider = container.decodeLossyStringIfPresent(forKey: .provider)
        profile = container.decodeLossyStringIfPresent(forKey: .profile)
        toastNotifications = container.decodeLossyBoolIfPresent(forKey: .toastNotifications)
    }

    var displayName: String {
        if let name, !name.isEmpty {
            return name
        }

        if let scheduleText, !scheduleText.isEmpty {
            return scheduleText
        }

        return String(localized: "Untitled Task")
    }

    var descriptionSummary: String? {
        guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let paragraphs = prompt.components(separatedBy: "\n\n")
        var summary = paragraphs.first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) ?? prompt

        for marker in [" Run this ", " Execute this ", " Run the following ", " Use this command "] {
            if let range = summary.range(of: marker, options: .caseInsensitive),
               summary.distance(from: summary.startIndex, to: range.lowerBound) >= 24 {
                summary = String(summary[..<range.lowerBound])
                break
            }
        }

        return CronTextSummary.make(from: summary, maximumLength: 280)
    }

    var scheduleText: String? {
        scheduleDisplay ?? schedule?.displayText
    }

    var readableScheduleText: String? {
        guard let scheduleText else { return nil }
        return CronScheduleFormatter.readableText(
            for: scheduleText,
            nextRunAt: nextRunAt?.date
        ) ?? scheduleText
    }

    var editableScheduleText: String? {
        schedule?.expression ?? schedule?.expr ?? schedule?.runAt ?? schedule?.every ?? scheduleDisplay
    }

    var status: CronJobStatus {
        if isRecurring,
           repeatInfo?.times == nil,
           enabled == false,
           state == "completed",
           nextRunAt == nil {
            return .needsAttention
        }

        if isRecurring,
           nextRunAt == nil,
           state == "error" || lastStatus == "error" {
            return .needsAttention
        }

        if state == "paused" {
            return .paused
        }

        if enabled == false {
            return .off
        }

        if lastStatus == "error" {
            return .error
        }

        return .active
    }

    private var isRecurring: Bool {
        schedule?.kind == "cron" || schedule?.kind == "interval"
    }
}

struct CronSchedule: Decodable, Equatable {
    let kind: String?
    let expression: String?
    let expr: String?
    let runAt: String?
    let every: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case expression
        case expr
        case runAt
        case every
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            kind = nil
            expression = value
            expr = nil
            runAt = nil
            every = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = container.decodeLossyStringIfPresent(forKey: .kind)
        expression = container.decodeLossyStringIfPresent(forKey: .expression)
        expr = container.decodeLossyStringIfPresent(forKey: .expr)
        runAt = container.decodeLossyStringIfPresent(forKey: .runAt)
        every = container.decodeLossyStringIfPresent(forKey: .every)
    }

    var displayText: String? {
        expression ?? expr ?? runAt ?? every ?? kind
    }
}

enum CronScheduleFormatter {
    static func readableText(
        for expression: String,
        nextRunAt: Date? = nil,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)

        if let interval = intervalText(trimmed) {
            return interval
        }

        switch trimmed.lowercased() {
        case "@hourly":
            return String(localized: "Every hour")
        case "@daily", "@midnight":
            return String(localized: "Every day at midnight")
        case "@weekly":
            return String(localized: "Every Sunday at midnight")
        case "@monthly":
            return String(localized: "On the first day of every month at midnight")
        case "@yearly", "@annually":
            return String(localized: "Every January 1 at midnight")
        default:
            break
        }

        let fields = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 5 else { return nil }

        let minute = fields[0]
        let hour = fields[1]
        let dayOfMonth = fields[2]
        let month = fields[3]
        let dayOfWeek = fields[4]

        if fields.allSatisfy({ $0 == "*" }) {
            return String(localized: "Every minute")
        }

        if hour == "*", dayOfMonth == "*", month == "*", dayOfWeek == "*" {
            if let interval = stepValue(minute) {
                return String(localized: "Every \(interval) minutes")
            }

            if let minuteValue = integer(minute, range: 0...59) {
                return minuteValue == 0
                    ? String(localized: "Every hour")
                    : String(localized: "Every hour at \(minuteValue) minutes past")
            }
        }

        if let hourInterval = stepValue(hour),
           let minuteValue = integer(minute, range: 0...59),
           dayOfMonth == "*", month == "*", dayOfWeek == "*" {
            if minuteValue == 0 {
                return String(localized: "Every \(hourInterval) hours")
            }
            return String(localized: "Every \(hourInterval) hours at \(minuteValue) minutes past")
        }

        guard let minuteValue = integer(minute, range: 0...59),
              let hourValue = integer(hour, range: 0...23),
              month == "*" else {
            return nil
        }

        let time = timeText(
            hour: hourValue,
            minute: minuteValue,
            nextRunAt: nextRunAt,
            locale: locale,
            timeZone: timeZone
        )

        if dayOfMonth == "*", dayOfWeek == "*" {
            return String(localized: "Every day at \(time)")
        }

        if dayOfMonth == "*", dayOfWeek == "1-5" {
            return String(localized: "Weekdays at \(time)")
        }

        if dayOfMonth == "*", let weekdays = weekdayNames(dayOfWeek) {
            return String(localized: "Every \(weekdays) at \(time)")
        }

        if dayOfWeek == "*", let day = integer(dayOfMonth, range: 1...31) {
            return String(localized: "On day \(day) of every month at \(time)")
        }

        return nil
    }

    private static func integer(_ value: String, range: ClosedRange<Int>) -> Int? {
        guard let parsed = Int(value), range.contains(parsed) else { return nil }
        return parsed
    }

    private static func intervalText(_ expression: String) -> String? {
        var value = expression.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("every ") {
            value = String(value.dropFirst("every ".count)).trimmingCharacters(in: .whitespaces)
        }

        let components = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let count: Int
        let unit: String

        if components.count == 2, let parsed = Int(components[0]) {
            count = parsed
            unit = components[1]
        } else if components.count == 1 {
            let token = components[0]
            let digits = token.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, let parsed = Int(digits) else { return nil }
            count = parsed
            unit = String(token.dropFirst(digits.count))
        } else {
            return nil
        }

        guard count > 0 else { return nil }
        switch unit {
        case "s", "sec", "secs", "second", "seconds":
            return normalizedIntervalText(count: count, unit: "seconds")
        case "m", "min", "mins", "minute", "minutes":
            return normalizedIntervalText(count: count, unit: "minutes")
        case "h", "hr", "hrs", "hour", "hours":
            return normalizedIntervalText(count: count, unit: "hours")
        case "d", "day", "days":
            return normalizedIntervalText(count: count, unit: "days")
        case "w", "wk", "wks", "week", "weeks":
            return normalizedIntervalText(count: count, unit: "weeks")
        default:
            return nil
        }
    }

    private static func normalizedIntervalText(count: Int, unit: String) -> String {
        switch unit {
        case "seconds":
            if count.isMultiple(of: 60) {
                return normalizedIntervalText(count: count / 60, unit: "minutes")
            }
            return count == 1 ? String(localized: "Every second") : String(localized: "Every \(count) seconds")
        case "minutes":
            if count.isMultiple(of: 60) {
                return normalizedIntervalText(count: count / 60, unit: "hours")
            }
            return count == 1 ? String(localized: "Every minute") : String(localized: "Every \(count) minutes")
        case "hours":
            if count.isMultiple(of: 24) {
                return normalizedIntervalText(count: count / 24, unit: "days")
            }
            return count == 1 ? String(localized: "Every hour") : String(localized: "Every \(count) hours")
        case "days":
            if count.isMultiple(of: 7) {
                return normalizedIntervalText(count: count / 7, unit: "weeks")
            }
            return count == 1 ? String(localized: "Every day") : String(localized: "Every \(count) days")
        default:
            return count == 1 ? String(localized: "Every week") : String(localized: "Every \(count) weeks")
        }
    }

    private static func stepValue(_ value: String) -> Int? {
        guard value.hasPrefix("*/"),
              let parsed = Int(value.dropFirst(2)),
              parsed > 1 else {
            return nil
        }
        return parsed
    }

    private static func weekdayNames(_ field: String) -> String? {
        let names = [
            0: String(localized: "Sunday"),
            1: String(localized: "Monday"),
            2: String(localized: "Tuesday"),
            3: String(localized: "Wednesday"),
            4: String(localized: "Thursday"),
            5: String(localized: "Friday"),
            6: String(localized: "Saturday"),
            7: String(localized: "Sunday")
        ]
        let values = field.split(separator: ",").compactMap { Int($0) }
        guard !values.isEmpty,
              values.count == field.split(separator: ",").count,
              values.allSatisfy({ names[$0] != nil }) else {
            return nil
        }
        return values.compactMap { names[$0] }.joined(separator: String(localized: ", "))
    }

    private static func timeText(
        hour: Int,
        minute: Int,
        nextRunAt: Date?,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        if let nextRunAt {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: nextRunAt)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute))!
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct CronRepeat: Decodable, Equatable {
    let times: Int?
    let completed: Int?
}

struct CronOutputResponse: Decodable, Equatable {
    let jobId: String?
    let outputs: [CronOutputItem]?

    enum CodingKeys: String, CodingKey {
        case jobId
        case outputs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try container.decodeIfPresent(String.self, forKey: .jobId)
        outputs = (try? container.decodeIfPresent([CronOutputItem].self, forKey: .outputs)) ?? nil
    }
}

struct CronOutputItem: Decodable, Equatable, Identifiable {
    var id: String { filename ?? UUID().uuidString }

    let filename: String?
    let content: String?

    enum CodingKeys: String, CodingKey {
        case filename
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        content = try container.decodeIfPresent(String.self, forKey: .content)
    }

    var resultText: String? {
        guard let content else { return nil }
        let lines = content.components(separatedBy: .newlines)
        let responseIndex = lines.firstIndex { line in
            let heading = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return heading == "## Response" || heading == "# Response"
        }

        if let responseIndex {
            return Self.normalizedResult(lines.dropFirst(responseIndex + 1).joined(separator: "\n"))
        }

        if Self.isScriptOutputDocument(lines) {
            return Self.scriptResult(from: lines)
        }

        return Self.normalizedResult(content)
    }

    private static func normalizedResult(_ result: String) -> String? {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isSilenceResponse(trimmed) {
            return String(localized: "No new update.")
        }
        return trimmed
    }

    private static func isSilenceResponse(_ result: String) -> Bool {
        let tokens = Set(["[SILENT]", "SILENT", "NO_REPLY", "NO REPLY"])
        let normalized = result.uppercased()
        if tokens.contains(normalized) || normalized.hasPrefix("[SILENT]") {
            return true
        }

        let nonEmptyLines = normalized.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let first = nonEmptyLines.first, let last = nonEmptyLines.last else { return false }
        return tokens.contains(first.trimmingCharacters(in: .whitespacesAndNewlines))
            || tokens.contains(last.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isScriptOutputDocument(_ lines: [String]) -> Bool {
        lines.contains { line in
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.hasPrefix("**mode:**") && normalized.contains("no_agent")
        }
    }

    private static func scriptResult(from lines: [String]) -> String? {
        if let statusLine = lines.first(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("**status:**")
        }) {
            let status = statusLine.lowercased()
            if status.contains("silent") {
                return String(localized: "No new update.")
            }
        }

        if let separatorIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }) {
            return normalizedResult(lines.dropFirst(separatorIndex + 1).joined(separator: "\n"))
        }

        let metadataEnd = lines.lastIndex(where: isScriptMetadataLine)
        if let metadataEnd,
           let body = normalizedResult(lines.dropFirst(metadataEnd + 1).joined(separator: "\n")) {
            return body
        }

        let failed = lines.contains {
            let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.hasPrefix("**status:**") && normalized.contains("failed")
        }
        return failed ? String(localized: "Script failed.") : nil
    }

    private static func isScriptMetadataLine(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("# cron job:")
            || normalized.hasPrefix("**job id:**")
            || normalized.hasPrefix("**run time:**")
            || normalized.hasPrefix("**mode:**")
            || normalized.hasPrefix("**status:**")
            || normalized == "---"
    }

    var runDate: Date? {
        guard let filename else { return nil }
        let sourceFormatter = DateFormatter()
        sourceFormatter.locale = Locale(identifier: "en_US_POSIX")
        sourceFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        sourceFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss'.md'"
        return sourceFormatter.date(from: filename)
    }

    var formattedRunTime: String? {
        guard let date = runDate else { return nil }

        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        displayFormatter.timeStyle = .short
        return displayFormatter.string(from: date)
    }

    var summaryText: String {
        guard let resultText else { return String(localized: "No update recorded.") }
        return CronTextSummary.make(from: resultText, maximumLength: 220)
    }

    var representsNoUpdate: Bool {
        resultText == String(localized: "No new update.")
    }

    var createsAgentSession: Bool {
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let lines = content.components(separatedBy: .newlines)
        if Self.isScriptOutputDocument(lines) {
            return false
        }

        return !lines.contains { line in
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.hasPrefix("**status:**") && normalized.contains("blocked")
        }
    }
}

enum CronRunSessionResolver {
    static func sessionsByOutputID(
        job: CronJob,
        outputs: [CronOutputItem],
        sessions: [SessionSummary]
    ) -> [String: SessionSummary] {
        guard let jobID = normalized(job.jobId) else { return [:] }

        let sessionPrefix = "cron_\(jobID)_"
        let jobProfile = normalized(job.profile)
        let candidateSessions = sessions.compactMap { session -> (SessionSummary, Date)? in
            guard let sessionID = session.sessionId,
                  sessionID.hasPrefix(sessionPrefix),
                  let startedAt = sessionStartDate(sessionID: sessionID, prefix: sessionPrefix)
            else {
                return nil
            }

            if let jobProfile,
               let sessionProfile = normalized(session.profile),
               sessionProfile != jobProfile {
                return nil
            }
            return (session, startedAt)
        }
        .sorted { $0.1 < $1.1 }

        let chronologicalOutputs = outputs
            .filter { $0.runDate != nil }
            .sorted { ($0.runDate ?? .distantPast) < ($1.runDate ?? .distantPast) }

        var previousOutputDate: Date?
        var usedSessionIDs = Set<String>()
        var resolved: [String: SessionSummary] = [:]

        for output in chronologicalOutputs {
            guard let outputDate = output.runDate else { continue }
            defer { previousOutputDate = outputDate }
            guard output.createsAgentSession else { continue }

            let match = candidateSessions.last { session, startedAt in
                guard let sessionID = session.sessionId,
                      !usedSessionIDs.contains(sessionID),
                      startedAt <= outputDate else {
                    return false
                }
                if let previousOutputDate {
                    return startedAt >= previousOutputDate
                }
                return true
            }

            guard let (session, _) = match, let sessionID = session.sessionId else { continue }
            resolved[output.id] = session
            usedSessionIDs.insert(sessionID)
        }

        return resolved
    }

    private static func sessionStartDate(sessionID: String, prefix: String) -> Date? {
        let timestamp = String(sessionID.dropFirst(prefix.count))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Session IDs and output filenames both use the configured Hermes
        // wall clock. A fixed zone preserves their relative ordering without
        // pretending either identifier carries an absolute timezone.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.date(from: timestamp)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CronTaskHistory {
    static func statusUpdates(from outputs: [CronOutputItem]) -> [CronOutputItem] {
        var previousFingerprint: String?
        var chronologicalUpdates: [CronOutputItem] = []

        for output in outputs.reversed() {
            guard output.resultText != nil, !output.representsNoUpdate else { continue }
            let fingerprint = output.summaryText.lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            guard fingerprint != previousFingerprint else { continue }
            chronologicalUpdates.append(output)
            previousFingerprint = fingerprint
        }

        return Array(chronologicalUpdates.reversed())
    }
}

enum CronSessionContextBuilder {
    static func draft(
        job: CronJob,
        outputs: [CronOutputItem],
        selectedOutput: CronOutputItem?,
        momentTitle: String
    ) -> String {
        let firstRunOutput = outputs
            .filter { $0.runDate != nil }
            .min { ($0.runDate ?? .distantFuture) < ($1.runDate ?? .distantFuture) }
        let firstRun = firstRunOutput?.formattedRunTime ?? String(localized: "Not recorded")
        let latestOutput = outputs.first
        let updates = CronTaskHistory.statusUpdates(from: outputs)
        let timeline = updates.prefix(50).map {
            "- [\($0.formattedRunTime ?? String(localized: "Unknown time"))] \($0.summaryText)"
        }.joined(separator: "\n")

        var sections = [
            String(localized: "I want to continue working on this scheduled task. Use the full task context below."),
            "## Task\nName: \(job.displayName)\nStatus: \(job.status.label)\nSchedule: \(job.readableScheduleText ?? job.scheduleText ?? String(localized: "Not available"))\nNext run: \(job.nextRunAt?.formatted ?? String(localized: "Not available"))\nFirst recorded run: \(firstRun)",
            "## Full task description\n\(job.prompt ?? String(localized: "No description provided."))",
            "## Selected moment\n\(momentTitle)"
        ]

        if let selectedOutput {
            sections.append(
                "### Selected run — \(selectedOutput.formattedRunTime ?? String(localized: "Unknown time"))\n\(selectedOutput.resultText ?? String(localized: "No update recorded."))"
            )
        }

        if let latestOutput, latestOutput.id != selectedOutput?.id {
            sections.append(
                "## Current status — \(latestOutput.formattedRunTime ?? String(localized: "Unknown time"))\n\(latestOutput.resultText ?? String(localized: "No update recorded."))"
            )
        }

        if !timeline.isEmpty {
            sections.append("## Update timeline\n\(timeline)")
        }

        sections.append(
            String(localized: "## Next action\nHelp me decide or perform the next action for this task. If my desired outcome is unclear, ask me what I want to do.")
        )
        return sections.joined(separator: "\n\n")
    }
}

private enum CronTextSummary {
    static func make(from text: String, maximumLength: Int) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        let paragraph = paragraphs.first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) ?? text
        var plain = paragraph
            .replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")

        plain = plain.components(separatedBy: .newlines).map { line in
            var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = value.first, "#*-•>".contains(first) {
                value.removeFirst()
                value = value.trimmingCharacters(in: .whitespaces)
            }
            return value
        }.filter { !$0.isEmpty }.joined(separator: " ")
        plain = plain.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")

        guard plain.count > maximumLength else { return plain }
        let prefix = String(plain.prefix(maximumLength))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return prefix + "…"
    }
}

struct CronDeliveryOptionsResponse: Decodable, Equatable {
    let platforms: [CronDeliveryOption]?

    enum CodingKeys: String, CodingKey {
        case platforms
    }

    init(platforms: [CronDeliveryOption]?) {
        self.platforms = platforms
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platforms = (try? container.decodeIfPresent([CronDeliveryOption].self, forKey: .platforms)) ?? nil
    }
}

struct CronDeliveryOption: Decodable, Equatable, Identifiable {
    var id: String { value ?? label ?? UUID().uuidString }

    let value: String?
    let label: String?

    enum CodingKeys: String, CodingKey {
        case value
        case label
    }

    init(value: String?, label: String?) {
        self.value = value
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = container.decodeLossyStringIfPresent(forKey: .value)
        label = container.decodeLossyStringIfPresent(forKey: .label)
    }
}

/// One selectable row in the cron deliver picker.
struct CronDeliverPickerOption: Equatable, Identifiable {
    let value: String
    let label: String
    /// `true` when the row exists only to round-trip a draft value that the
    /// server did not list (unknown/legacy deliver target).
    let isCustom: Bool

    var id: String { value }
}

enum CronDeliverPicker {
    /// Builds picker rows from server-provided delivery options.
    ///
    /// Returns `nil` when the picker should fall back to free-text entry:
    /// options missing/empty (endpoint failed or returned nothing usable) or
    /// the current draft value is blank (nothing safe to select).
    /// A current value outside the server list is preserved as an extra
    /// custom row instead of being clobbered. `initialValue` (the draft's
    /// deliver value when the editor opened) also keeps its custom row so an
    /// unknown/legacy value can be re-selected after choosing another option.
    static func options(
        serverOptions: [CronDeliveryOption]?,
        currentValue: String,
        initialValue: String? = nil
    ) -> [CronDeliverPickerOption]? {
        var seenValues = Set<String>()
        let valid: [CronDeliverPickerOption] = (serverOptions ?? []).compactMap { option in
            guard let value = option.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  seenValues.insert(value).inserted else {
                return nil
            }

            let label = option.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CronDeliverPickerOption(
                value: value,
                label: (label?.isEmpty == false ? label : nil) ?? value,
                isCustom: false
            )
        }

        guard !valid.isEmpty else {
            return nil
        }

        let current = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else {
            return nil
        }

        var options = valid
        var knownValues = Set(valid.map(\.value))
        let initial = initialValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !initial.isEmpty, knownValues.insert(initial).inserted {
            options.append(CronDeliverPickerOption(value: initial, label: initial, isCustom: true))
        }
        if knownValues.insert(current).inserted {
            options.append(CronDeliverPickerOption(value: current, label: current, isCustom: true))
        }
        return options
    }
}

enum CronJobStatus: Equatable {
    case active
    case paused
    case off
    case error
    case needsAttention

    var label: String {
        switch self {
        case .active:
            return String(localized: "Active")
        case .paused:
            return String(localized: "Paused")
        case .off:
            return String(localized: "Off")
        case .error:
            return String(localized: "Error")
        case .needsAttention:
            return String(localized: "Needs Attention")
        }
    }
}

struct CronJobEditorDraft: Equatable {
    var name: String
    var prompt: String
    var schedule: String
    var deliver: String
    var skillsText: String
    var model: String
    var provider: String
    var profile: String
    var toastNotifications: Bool

    init(
        name: String = "",
        prompt: String = "",
        schedule: String = "",
        deliver: String = "local",
        skillsText: String = "",
        model: String = "",
        provider: String = "",
        profile: String = "",
        toastNotifications: Bool = true
    ) {
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.deliver = deliver
        self.skillsText = skillsText
        self.model = model
        self.provider = provider
        self.profile = profile
        self.toastNotifications = toastNotifications
    }

    init(job: CronJob) {
        self.init(
            name: job.name ?? "",
            prompt: job.prompt ?? "",
            schedule: job.editableScheduleText ?? "",
            deliver: job.deliver ?? "local",
            skillsText: job.skills?.joined(separator: ", ") ?? "",
            model: job.model ?? "",
            provider: job.provider ?? "",
            profile: job.profile ?? "",
            toastNotifications: job.toastNotifications ?? true
        )
    }

    var trimmedName: String? {
        Self.nonEmpty(name)
    }

    var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedSchedule: String {
        schedule.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedDeliver: String? {
        Self.nonEmpty(deliver)
    }

    var trimmedModel: String? {
        Self.nonEmpty(model)
    }

    var trimmedProvider: String? {
        Self.nonEmpty(provider)
    }

    var trimmedProfile: String? {
        Self.nonEmpty(profile)
    }

    var skills: [String] {
        skillsText
            .split { character in
                character == "," || character == "\n"
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var validationMessage: String? {
        if trimmedPrompt.isEmpty {
            return String(localized: "Prompt is required.")
        }

        if trimmedSchedule.isEmpty {
            return String(localized: "Schedule is required.")
        }

        return nil
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CronDateValue: Decodable, Equatable {
    let date: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let timestamp = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: timestamp)
            return
        }

        let stringValue = try container.decode(String.self)
        if let timestamp = Double(stringValue) {
            date = Date(timeIntervalSince1970: timestamp)
            return
        }

        if let parsed = Self.isoFormatter.date(from: stringValue)
            ?? Self.fractionalISOFormatter.date(from: stringValue) {
            date = parsed
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported cron date value"
        )
    }

    var formatted: String {
        Self.displayFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

extension KeyedDecodingContainer {
    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }

        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }

        if let stringValue = try? decodeIfPresent(String.self, forKey: key) {
            return Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }
}
