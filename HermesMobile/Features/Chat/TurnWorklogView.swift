import SwiftUI

/// The single collapsed row that stands in for everything an assistant turn did
/// before answering — its reasoning and its tool calls.
///
/// Replaces the former per-message `ReasoningBlockView` + `ToolActivityGroupView`
/// pair. An agentic turn (think → tool → think → tool → …) used to stack one
/// Thinking card per hop plus an Activity card, so a single answer could sit
/// behind ten near-identical grey rows. Reasoning is now merged per turn in
/// `ChatViewModel.reasoningDisplayGroups` and tool calls in
/// `ToolCallGroup.coalescingByAssistantTurn`; both land on the same anchor, so
/// the turn renders as one line the reader can expand when they want the detail.
struct TurnWorklogView: View {
    let reasoningTexts: [String]
    let toolCallGroups: [ToolCallGroup]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(ChatTranscriptDisplaySettings.thinkingCardsStartExpandedKey)
    private var thinkingStartsExpanded = false
    @AppStorage(ChatTranscriptDisplaySettings.toolCardsStartExpandedKey)
    private var toolsStartExpanded = false
    @State private var userToggledExpansion: Bool?

    init(reasoningTexts: [String] = [], toolCallGroups: [ToolCallGroup] = []) {
        self.reasoningTexts = reasoningTexts
        self.toolCallGroups = toolCallGroups
    }

    private var isExpanded: Bool {
        ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: ChatTranscriptDisplaySettings.worklogStartsExpanded(
                thinkingCardsStartExpanded: thinkingStartsExpanded,
                toolCardsStartExpanded: toolsStartExpanded
            )
        )
    }

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
                Button {
                    withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
                        userToggledExpansion = !isExpanded
                    }
                } label: {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityLabel(activityAccessibilityLabel)
                .accessibilityHint(isExpanded ? "Double tap to collapse details." : "Double tap to expand details.")

                if isExpanded {
                    expandedDetail
                        .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .chatTimelineAccessorySurface(
                fallbackMaterial: .thinMaterial,
                cornerRadius: 10
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(trimmedReasoningTexts.enumerated()), id: \.offset) { _, text in
                Text(text)
                    .font(AppFont.caption())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(toolCalls) { toolCall in
                        ToolCallCardView(toolCall: toolCall)
                    }
                }
            }
        }
    }

    private var usesStackedHeader: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var header: some View {
        HStack(alignment: usesStackedHeader ? .top : .center, spacing: 8) {
            headerIcon

            if usesStackedHeader {
                VStack(alignment: .leading, spacing: 3) {
                    titleText
                    summaryTextView(lineLimit: 2)
                    if let collapsedStateText {
                        TranscriptStatusPill(text: collapsedStateText, color: activityColor)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    titleText
                    summaryTextView(lineLimit: 1)
                    if let collapsedStateText {
                        TranscriptStatusPill(text: collapsedStateText, color: activityColor)
                    }
                }
            }

            Spacer(minLength: 6)

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    /// The brain glyph when the turn only thought, otherwise the tool activity's
    /// state icon — running / completed / failed is the one signal worth carrying
    /// on a collapsed row.
    @ViewBuilder
    private var headerIcon: some View {
        if toolCalls.isEmpty {
            Image("LucideBrain")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: activityIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(activityColor)
                .frame(width: 18, height: 18)
        }
    }

    private var titleText: some View {
        Text(activityTitle)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    private func summaryTextView(lineLimit: Int) -> some View {
        Text(summaryText)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
    }

    private var hasContent: Bool {
        !trimmedReasoningTexts.isEmpty || !toolCalls.isEmpty
    }

    private var trimmedReasoningTexts: [String] {
        reasoningTexts.compactMap { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private var toolCalls: [ToolCall] {
        toolCallGroups.flatMap(\.toolCalls)
    }

    /// Composed from the two existing catalog keys rather than a new combined
    /// string, so the merged row stays translated in every shipped language.
    private var activityTitle: String {
        let toolCount = toolCalls.count
        guard toolCount > 0 else {
            return String(localized: "Thinking")
        }

        let toolsTitle = String(localized: "Activity: \(toolCount) tools")
        guard !trimmedReasoningTexts.isEmpty else { return toolsTitle }

        return "\(String(localized: "Thinking")) · \(toolsTitle)"
    }

    /// Tool names when the turn used any — they say more about what happened than
    /// a reasoning excerpt does. A think-only turn falls back to its opening line.
    private var summaryText: String {
        toolCalls.isEmpty ? reasoningSummary : toolNameSummary
    }

    private var toolNameSummary: String {
        let uniqueNames = toolCalls.map(\.displayName).reduce(into: [String]()) { result, name in
            if !result.contains(name) {
                result.append(name)
            }
        }

        guard !uniqueNames.isEmpty else {
            return String(localized: "No tools")
        }

        let visibleNames = uniqueNames.prefix(3)
        let remainingCount = uniqueNames.count - visibleNames.count
        let visibleSummary = visibleNames.joined(separator: ", ")

        guard remainingCount > 0 else {
            return visibleSummary
        }

        return "\(visibleSummary), +\(remainingCount)"
    }

    private var reasoningSummary: String {
        let oneLine = trimmedReasoningTexts
            .joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if oneLine.count <= 80 {
            return oneLine
        }

        return "\(oneLine.prefix(80))..."
    }

    private var isComplete: Bool {
        toolCallGroups.allSatisfy(\.isComplete)
    }

    private var hasFailedTool: Bool {
        toolCallGroups.contains(where: \.hasFailedTool)
    }

    private var activityIcon: String {
        if hasFailedTool {
            return "exclamationmark.triangle.fill"
        }

        return isComplete ? "checkmark.circle.fill" : "wrench.and.screwdriver.fill"
    }

    private var activityColor: Color {
        hasFailedTool ? .red : .secondary
    }

    private var collapsedStateText: String? {
        guard !toolCalls.isEmpty else { return nil }

        if hasFailedTool {
            return String(localized: "Failed")
        }

        return isComplete ? nil : String(localized: "Running")
    }

    private var activityAccessibilityLabel: String {
        guard !toolCalls.isEmpty else {
            return String(localized: "Thinking, \(reasoningSummary)")
        }

        return "\(activityTitle), \(activityStateText), \(summaryText)"
    }

    private var activityStateText: String {
        if hasFailedTool {
            return String(localized: "Failed")
        }

        return isComplete ? String(localized: "Completed") : String(localized: "Running")
    }
}
