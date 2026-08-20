//
//  AILimitsMenuView.swift
//  SpaceManager
//

import SwiftUI

enum AILimitsResetFormatter {
    private static let chicagoTimeZone = TimeZone(identifier: "America/Chicago")!
    private static let weekdayLetters = ["U", "M", "T", "W", "R", "F", "S"]

    static func compact(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicagoTimeZone
        let cutoff = calendar.date(byAdding: .month, value: -11, to: now) ?? .distantPast
        let weekday = calendar.component(.weekday, from: date)
        let dayLetter = weekdayLetters.indices.contains(weekday - 1)
            ? weekdayLetters[weekday - 1]
            : ""
        let dateFormat = date < cutoff ? "M-d-yy" : "M-d"
        let cleanDate = formatted(date, format: dateFormat)
        let time = formatted(date, format: "h:mm a").lowercased()
        return "\(dayLetter) \(cleanDate) · \(time)"
    }

    private static func formatted(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = chicagoTimeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

enum AILimitsDisplayFormatter {
    static func resetText(
        for value: AILimitValue?,
        expiresAt: Date?,
        now: Date = Date()
    ) -> String {
        if let expiresAt,
           let resetsAt = value?.resetsAt,
           expiresAt < resetsAt {
            return "Expires \(AILimitsResetFormatter.compact(expiresAt, now: now))"
        }
        return AILimitsResetFormatter.compact(value?.resetsAt, now: now)
    }
}

@MainActor
final class AILimitsMenuViewModel: ObservableObject {
    @Published var snapshot: AILimitsSnapshot?
    @Published var source: AILimitsSnapshotSource?
    @Published var displayedAt = Date()
}

struct AILimitsMenuView: View {
    @ObservedObject var model: AILimitsMenuViewModel

    var body: some View {
        VStack(spacing: 3) {
            serviceRow(
                emoji: "✴️",
                name: "Claude",
                limits: model.snapshot?.claude,
                includesFable: true)
            serviceRow(
                emoji: "🌀",
                name: "Codex",
                limits: model.snapshot?.codex,
                includesFable: false)
        }
        .debugLabel("aiLimitsMenu")
    }

    private func serviceRow(
        emoji: String,
        name: String,
        limits: AIServiceLimitsSnapshot?,
        includesFable: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(emoji)
                .font(.system(size: 13))
                .frame(width: 18)
                .accessibilityLabel(name)
            limitCell("5h", value: limits?.fiveHour)
            limitCell(
                "wk",
                value: limits?.weekly,
                expiresAt: includesFable ? nil : limits?.billingPeriodEndsAt)
            if includesFable {
                limitCell("Fable", value: limits?.fable)
            } else {
                Spacer()
                    .frame(width: 126)
            }
        }
        .frame(maxWidth: .infinity)
        .debugLabel("\(name.lowercased())LimitsRow")
    }

    private func limitCell(
        _ label: String,
        value: AILimitValue?,
        expiresAt: Date? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(percentText(value?.percentUsed))
                .foregroundStyle(limitColor(value?.percentUsed))
            Text(AILimitsDisplayFormatter.resetText(
                for: value,
                expiresAt: expiresAt,
                now: model.displayedAt))
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(.white)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(width: 126, alignment: .leading)
        .help(resetHelp(value?.resetsAt))
    }

    private func percentText(_ percent: Int?) -> String {
        percent.map { "\($0)%" } ?? "—"
    }

    private func limitColor(_ percent: Int?) -> Color {
        guard let percent else { return Color(nsColor: .tertiaryLabelColor) }
        if percent >= 80 { return Color(nsColor: .systemRed) }
        if percent >= 50 { return Color(nsColor: .systemOrange) }
        return Color(nsColor: .labelColor)
    }

    private func resetHelp(_ date: Date?) -> String {
        guard let date else { return "Reset unavailable" }
        return "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
