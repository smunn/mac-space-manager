//
//  AISessionInspectorView.swift
//  SpaceManager
//

import AppKit
import SwiftUI

@MainActor
final class AISessionInspectorController: NSWindowController {
    init(item: AISessionHealthItem, resume: @escaping () -> Void) {
        let view = AISessionInspectorView(item: item, resume: resume)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "\(item.service.rawValue) Process Inspector"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct AISessionInspectorView: View {
    let item: AISessionHealthItem
    let resume: () -> Void
    @State private var isSampling = false
    @State private var sampleFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    processDetails
                    textSection("Current Activity", value: item.lastActivitySummary)
                    textSection("Task", value: item.taskSummary)
                    textSection("Latest Response", value: item.completionSummary)
                    sessionDetails
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actions
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
        .debugLabel("aiSessionInspectorView")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.repositoryName ?? item.service.rawValue)
                    .font(.title2.weight(.semibold))
                Text(item.projectPath ?? "Unknown working directory")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(item.statusLabels.joined(separator: " · "))
                .font(.callout.weight(.medium))
                .foregroundStyle(item.canCleanUp ? .red : .secondary)
        }
        .debugLabel("aiSessionInspectorHeader")
    }

    private var processDetails: some View {
        detailGroup("Process") {
            detailRow("PID", "\(item.processID)")
            detailRow("Parent PID", "\(item.parentProcessID)")
            detailRow("Started", processStartText(item.processStartedAt))
            detailRow("Running", compactElapsed(item.elapsedTime))
            detailRow("CPU", "\(item.cpuUsagePercent.formatted(.number.precision(.fractionLength(1))))%")
            detailRow("CPU Time", compactElapsed(item.cpuTime))
            if let lastActivityAt = item.lastActivityAt {
                detailRow("Last Activity", processStartText(lastActivityAt))
            }
        }
    }

    private var sessionDetails: some View {
        detailGroup("Session") {
            detailRow("ID", item.sessionID ?? "Unavailable")
            detailRow("State", item.completionStatus.rawValue.capitalized)
            detailRow("Standard I/O", item.hasUnavailableStandardIO ? "Unavailable" : "Connected")
            detailRow("Command", item.command)
            detailRow("Log", item.sessionLogPath ?? "Unavailable")
        }
    }

    private var actions: some View {
        HStack {
            Button("Copy Details", action: copyDetails)
            if let logPath = item.sessionLogPath {
                Button("Reveal Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: logPath)])
                }
            }
            Button(isSampling ? "Sampling…" : "Capture CPU Sample", action: captureSample)
                .disabled(isSampling)
            if sampleFailed {
                Text("Sample failed")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
            if item.sessionID != nil {
                Button("Resume in Terminal", action: resume)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .debugLabel("aiSessionInspectorActions")
    }

    @ViewBuilder
    private func detailGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                content()
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .fontDesign(label == "Command" || label == "Log" || label == "ID" ? .monospaced : .default)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func textSection(_ title: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func captureSample() {
        isSampling = true
        sampleFailed = false
        ProcessDiagnosticSampler.capture(pid: item.processID) { url in
            Task { @MainActor in
                isSampling = false
                guard let url else {
                    sampleFailed = true
                    return
                }
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func copyDetails() {
        let details = [
            "Service: \(item.service.rawValue)",
            "Repository: \(item.repositoryName ?? "Unavailable")",
            "Working directory: \(item.projectPath ?? "Unavailable")",
            "PID: \(item.processID)",
            "Parent PID: \(item.parentProcessID)",
            "CPU: \(item.cpuUsagePercent)%",
            "CPU time: \(compactElapsed(item.cpuTime))",
            "Status: \(item.statusLabels.joined(separator: ", "))",
            "Session ID: \(item.sessionID ?? "Unavailable")",
            "Last activity: \(item.lastActivitySummary ?? "Unavailable")",
            "Task: \(item.taskSummary ?? "Unavailable")",
            "Latest response: \(item.completionSummary ?? "Unavailable")",
            "Command: \(item.command)",
            "Log: \(item.sessionLogPath ?? "Unavailable")"
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details, forType: .string)
    }
}
