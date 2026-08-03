//
//  PerformanceMenuView.swift
//  SpaceManager
//

import SwiftUI

@MainActor
final class PerformanceMenuViewModel: ObservableObject {
    @Published var snapshot: SystemPerformanceSnapshot?
    @Published var processHealthSnapshot: ProcessHealthSnapshot = .empty
    @Published var isRefreshingProcessHealth = false
    @Published var terminatingAISessionIDs: Set<String> = []
    @Published var processActionStatus: ProcessActionStatus?

    var reviewSimulator: ((SimulatorHealthItem) -> Void)?
    var shutDownSimulator: ((SimulatorHealthItem) -> Void)?
    var reviewAISession: ((AISessionHealthItem) -> Void)?
    var cleanUpAISession: ((AISessionHealthItem) -> Void)?
    var cleanUpRecommendedAISessions: (([AISessionHealthItem]) -> Void)?
}

struct ProcessActionStatus: Equatable {
    let message: String
    let succeeded: Bool?
}

struct PerformanceMenuView: View {
    @ObservedObject var model: PerformanceMenuViewModel

    var body: some View {
        VStack(spacing: 8) {
            header

            HStack(spacing: 8) {
                metricCell(
                    label: "CPU",
                    value: cpuText,
                    detail: nil,
                    fraction: model.snapshot?.cpuUsage,
                    tone: PerformanceMetricTone.cpu(model.snapshot?.cpuUsage))
                    .frame(width: 52, alignment: .leading)
                metricCell(
                    label: "Memory",
                    value: memoryText,
                    detail: memoryDetail,
                    fraction: memoryFraction,
                    tone: PerformanceMetricTone.memory(memoryFraction))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                metricCell(
                    label: "Battery",
                    value: batteryText,
                    detail: batteryDetail,
                    fraction: batteryFraction,
                    tone: PerformanceMetricTone.battery(
                        batteryFraction,
                        isCharging: model.snapshot?.batteryIsCharging == true))
                    .frame(width: 54, alignment: .leading)
                metricCell(
                    label: "Heat",
                    value: thermalText,
                    detail: nil,
                    fraction: thermalFraction,
                    tone: PerformanceMetricTone.thermal(model.snapshot?.thermalState))
                    .frame(width: 66, alignment: .leading)
            }

            Divider()

            PerformanceThroughputRow(
                label: "Network",
                leadingLabel: "↓",
                leadingValue: rateText(model.snapshot?.networkDownloadRate),
                trailingLabel: "↑",
                trailingValue: rateText(model.snapshot?.networkUploadRate))
            PerformanceThroughputRow(
                label: "Disk",
                leadingLabel: "R",
                leadingValue: rateText(model.snapshot?.diskReadRate),
                trailingLabel: "W",
                trailingValue: rateText(model.snapshot?.diskWriteRate))

            Divider()

            processHealth
        }
        .padding(10)
        .frame(width: 440, height: processHealthItemsAreEmpty ? 172 : 310)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.52))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .debugLabel("PerformanceMenuView")
    }

    private var processHealth: some View {
        Group {
            if processHealthItemsAreEmpty {
                processHealthStatus
            } else {
                processHealthIssues
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .debugLabel("processHealth")
    }

    private var processHealthStatus: some View {
        HStack {
            Text("Process Health")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if model.isRefreshingProcessHealth {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.isRefreshingProcessHealth ? "Scanning" : "No issues")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var processHealthIssues: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Process Health")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.isRefreshingProcessHealth {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.processHealthSnapshot.simulators) { simulator in
                        SimulatorHealthRow(
                            item: simulator,
                            review: { model.reviewSimulator?(simulator) },
                            shutDown: { model.shutDownSimulator?(simulator) })
                    }
                    aiSessionSection(.codex)
                    aiSessionSection(.claude)
                }
            }

            if let status = model.processActionStatus {
                Text(status.message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(actionStatusColor(status))
                    .lineLimit(2)
                    .debugLabel("processActionStatus")
            }
        }
    }

    @ViewBuilder
    private func aiSessionSection(_ service: AISessionService) -> some View {
        let sessions = model.processHealthSnapshot.aiSessions.filter { $0.service == service }
        if !sessions.isEmpty {
            let recommended = sessions.filter(\.canCleanUp)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(service.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(sessions.count) \(sessions.count == 1 ? "process" : "processes") · \(recommended.count) recommended")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !recommended.isEmpty {
                        Button("Terminate All Recommended") {
                            model.cleanUpRecommendedAISessions?(recommended)
                        }
                        .controlSize(.mini)
                        .disabled(recommended.allSatisfy {
                            model.terminatingAISessionIDs.contains($0.id)
                        })
                    }
                }
                .debugLabel("\(service.rawValue.lowercased())ProcessHeader")

                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    AISessionHealthRow(
                        item: session,
                        rowNumber: index + 1,
                        isStriped: index.isMultiple(of: 2),
                        isTerminating: model.terminatingAISessionIDs.contains(session.id),
                        review: { model.reviewAISession?(session) },
                        cleanUp: { model.cleanUpAISession?(session) })
                }
            }
            .debugLabel("\(service.rawValue)ProcessSection")
        }
    }

    private func actionStatusColor(_ status: ProcessActionStatus) -> Color {
        switch status.succeeded {
        case true: return .green
        case false: return .red
        case nil: return .secondary
        }
    }

    private var processHealthItemsAreEmpty: Bool {
        model.processHealthSnapshot.simulators.isEmpty && model.processHealthSnapshot.aiSessions.isEmpty
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Performance")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()
        }
    }

    private func metricCell(
        label: String,
        value: String,
        detail: String?,
        fraction: Double?,
        tone: PerformanceMetricTone?
    ) -> some View {
        PerformanceMetricCell(
            label: label,
            value: value,
            detail: detail,
            fraction: fraction,
            tone: tone)
    }

    private var cpuText: String {
        guard let usage = model.snapshot?.cpuUsage else { return "—" }
        return usage.formatted(.percent.precision(.fractionLength(0)))
    }

    private var memoryText: String {
        guard let snapshot = model.snapshot else { return "—" }
        return Self.compactBytes.string(fromByteCount: Int64(snapshot.memoryUsed))
    }

    private var memoryDetail: String? {
        guard let total = model.snapshot?.memoryTotal else { return nil }
        return "/ \(Self.compactBytes.string(fromByteCount: Int64(total)))"
    }

    private var memoryFraction: Double? {
        guard let snapshot = model.snapshot, snapshot.memoryTotal > 0 else { return nil }
        return Double(snapshot.memoryUsed) / Double(snapshot.memoryTotal)
    }

    private var batteryText: String {
        guard let percent = model.snapshot?.batteryPercent else { return "—" }
        return "\(percent)%"
    }

    private var batteryDetail: String? {
        model.snapshot?.batteryIsCharging == true ? "AC" : nil
    }

    private var batteryFraction: Double? {
        model.snapshot?.batteryPercent.map { Double($0) / 100 }
    }

    private var thermalText: String {
        guard let state = model.snapshot?.thermalState else { return "Measuring" }
        switch state {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private var thermalFraction: Double? {
        guard let state = model.snapshot?.thermalState else { return nil }
        switch state {
        case .nominal: return 0.25
        case .fair: return 0.5
        case .serious: return 0.75
        case .critical: return 1
        @unknown default: return nil
        }
    }

    private func rateText(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        return Self.rateFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    private static let compactBytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = false
        return formatter
    }()

    private static let rateFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()
}

private struct SimulatorHealthRow: View {
    let item: SimulatorHealthItem
    let review: () -> Void
    let shutDown: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(item.deviceName) · \(item.isActivelyUsed ? "Active" : Self.elapsed(item.bootDuration))")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Text("\(item.runtimeName) · \(item.deviceUUID.uuidString)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Review", action: review)
                .controlSize(.mini)
            Button("Shut Down", action: shutDown)
                .controlSize(.mini)
                .disabled(!item.canCleanUp)
        }
        .debugLabel("SimulatorHealthRow")
    }

    private static func elapsed(_ interval: TimeInterval) -> String {
        compactElapsed(interval)
    }
}

private struct AISessionHealthRow: View {
    let item: AISessionHealthItem
    let rowNumber: Int
    let isStriped: Bool
    let isTerminating: Bool
    let review: () -> Void
    let cleanUp: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(rowNumber).")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.detail ?? "Unknown working directory")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.detail ?? item.command)
                Text("Started \(processStartText(item.processStartedAt)) · Running \(compactElapsed(item.elapsedTime)) · CPU \(item.cpuUsagePercent.formatted(.number.precision(.fractionLength(0))))%")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Text("\(item.statusLabels.joined(separator: " · ")) · PID \(item.processID) · CPU time \(compactElapsed(item.cpuTime))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Show in Finder", action: review)
                .controlSize(.mini)
            if item.canCleanUp {
                Button(isTerminating ? "Terminating…" : "Terminate", action: cleanUp)
                    .controlSize(.mini)
                    .disabled(isTerminating)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            if isStriped {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
        }
        .help(item.command)
        .debugLabel("AISessionHealthRow")
    }

    private var statusColor: Color {
        if item.isDetached || item.isHighCPU { return .red }
        if item.isLongRunning { return .orange }
        return .green
    }
}

func compactElapsed(_ interval: TimeInterval) -> String {
    let minutes = max(0, Int(interval / 60))
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if hours < 24 { return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m" }
    let days = hours / 24
    return "\(days)d \(hours % 24)h"
}

func processStartText(
    _ date: Date,
    now: Date = Date(),
    calendar: Calendar = .current,
    timeZone: TimeZone = .current
) -> String {
    let weekdayLetters = ["U", "M", "T", "W", "R", "F", "S"]
    let weekday = calendar.component(.weekday, from: date)
    let cutoff = calendar.date(byAdding: .month, value: -11, to: now) ?? .distantPast

    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = timeZone
    dateFormatter.dateFormat = date < cutoff ? "M-d-yy" : "M-d"

    let timeFormatter = DateFormatter()
    timeFormatter.locale = Locale(identifier: "en_US_POSIX")
    timeFormatter.timeZone = timeZone
    timeFormatter.dateFormat = "h:mm a"

    let dayLetter = weekdayLetters.indices.contains(weekday - 1)
        ? weekdayLetters[weekday - 1]
        : ""
    return "\(dayLetter) \(dateFormatter.string(from: date)) · \(timeFormatter.string(from: date).lowercased())"
}

enum PerformanceMetricTone: Equatable {
    case excellent
    case good
    case moderate
    case elevated
    case critical

    var color: Color {
        switch self {
        case .excellent: Color(nsColor: .systemGreen)
        case .good: Color(nsColor: .systemTeal)
        case .moderate: Color(nsColor: .systemYellow)
        case .elevated: Color(nsColor: .systemOrange)
        case .critical: Color(nsColor: .systemRed)
        }
    }

    static func cpu(_ fraction: Double?) -> Self? {
        guard let fraction else { return nil }
        if fraction <= 0.25 { return .excellent }
        if fraction <= 0.5 { return .good }
        if fraction <= 0.7 { return .moderate }
        if fraction <= 0.85 { return .elevated }
        return .critical
    }

    static func memory(_ fraction: Double?) -> Self? {
        guard let fraction else { return nil }
        if fraction <= 0.6 { return .excellent }
        if fraction <= 0.75 { return .good }
        if fraction <= 0.85 { return .moderate }
        if fraction <= 0.93 { return .elevated }
        return .critical
    }

    static func battery(_ fraction: Double?, isCharging: Bool) -> Self? {
        guard let fraction else { return nil }
        if isCharging { return .good }
        if fraction >= 0.7 { return .excellent }
        if fraction >= 0.45 { return .good }
        if fraction >= 0.25 { return .moderate }
        if fraction >= 0.1 { return .elevated }
        return .critical
    }

    static func thermal(_ state: ProcessInfo.ThermalState?) -> Self? {
        guard let state else { return nil }
        switch state {
        case .nominal: return .excellent
        case .fair: return .moderate
        case .serious: return .elevated
        case .critical: return .critical
        @unknown default: return nil
        }
    }
}

private struct PerformanceMetricCell: View {
    let label: String
    let value: String
    let detail: String?
    let fraction: Double?
    let tone: PerformanceMetricTone?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.35)
                .foregroundStyle(.tertiary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: true, vertical: false)
                if let detail {
                    Text(detail)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill((tone?.color ?? Color(nsColor: .separatorColor)).opacity(0.18))
                    if let fraction, let tone {
                        Capsule()
                            .fill(tone.color.opacity(0.9))
                            .frame(width: max(2, proxy.size.width * min(max(fraction, 0), 1)))
                    }
                }
            }
            .frame(height: 2)
        }
        .debugLabel("PerformanceMetricCell")
    }
}

private struct PerformanceThroughputRow: View {
    let label: String
    let leadingLabel: String
    let leadingValue: String
    let trailingLabel: String
    let trailingValue: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.35)
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)

            rate(label: leadingLabel, value: leadingValue)
            rate(label: trailingLabel, value: trailingValue)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .debugLabel("PerformanceThroughputRow")
    }

    private func rate(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.system(size: 10, weight: .medium))
        .frame(width: 108, alignment: .leading)
    }
}
