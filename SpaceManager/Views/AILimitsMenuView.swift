//
//  AILimitsMenuView.swift
//  SpaceManager
//

import SwiftUI

enum AILimitsResetFormatter {
    private static let chicagoTimeZone = TimeZone(identifier: "America/Chicago")!

    static func compact(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicagoTimeZone
        let time = formatted(date, format: "h:mm a")
        if calendar.isDate(date, inSameDayAs: now) {
            return time
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        return "\(formatted(date, format: "EEE")) \(time)"
    }

    private static func formatted(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = chicagoTimeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

@MainActor
final class AILimitsMenuViewModel: ObservableObject {
    @Published var snapshot: AILimitsSnapshot?
    @Published var displayedAt = Date()
}

struct AILimitsMenuView: View {
    @ObservedObject var model: AILimitsMenuViewModel

    var body: some View {
        VStack(spacing: 5) {
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
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 440)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.52))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .debugLabel("aiLimitsMenu")
    }

    private func serviceRow(
        emoji: String,
        name: String,
        limits: AIServiceLimitsSnapshot?,
        includesFable: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(emoji)
                .font(.system(size: 11))
                .frame(width: 14)
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 45, alignment: .leading)
            limitCell("5h", value: limits?.fiveHour, width: 76)
            limitCell("wk", value: limits?.weekly, width: 76)
            if includesFable {
                limitCell("Fable", value: limits?.fable, width: 76)
            }
            Spacer(minLength: 4)
            Text(ageText(limits?.collectedAt))
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(ageColor(limits?.collectedAt))
        }
        .frame(maxWidth: .infinity)
        .debugLabel("\(name.lowercased())LimitsRow")
    }

    private func limitCell(_ label: String, value: AILimitValue?, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Text(label)
                    .foregroundStyle(.secondary)
                Text(percentText(value?.percentUsed))
                    .foregroundStyle(limitColor(value?.percentUsed))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())

            Text(AILimitsResetFormatter.compact(value?.resetsAt, now: model.displayedAt))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
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

    private func ageText(_ date: Date?) -> String {
        guard let date else { return "unavailable" }
        let seconds = max(0, Int(model.displayedAt.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s old" }
        if seconds < 3_600 { return "\(seconds / 60)m old" }
        if seconds < 86_400 { return "\(seconds / 3_600)h old" }
        return "\(seconds / 86_400)d old"
    }

    private func ageColor(_ date: Date?) -> Color {
        guard let date else { return Color(nsColor: .tertiaryLabelColor) }
        return model.displayedAt.timeIntervalSince(date) >= 300
            ? Color(nsColor: .systemOrange)
            : Color(nsColor: .secondaryLabelColor)
    }

    private func resetHelp(_ date: Date?) -> String {
        guard let date else { return "Reset unavailable" }
        return "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
