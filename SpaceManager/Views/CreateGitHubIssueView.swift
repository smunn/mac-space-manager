//
//  CreateGitHubIssueView.swift
//  SpaceManager
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CreateGitHubIssueViewModel: ObservableObject {
    @Published var repositories: [GitHubRepositoryOption] = []
    @Published var selectedRepository = ""
    @Published var repositorySearchText = ""
    @Published var title = ""
    @Published var body = ""
    @Published var labels: [GitHubLabelOption] = []
    @Published var selectedLabels = Set<String>()
    @Published var customLabelText = ""
    @Published var hasDueDate = false
    @Published var dueDate = Date()
    @Published var hasOnDate = false
    @Published var onDate = Date()
    @Published var attachments: [IssueAttachment] = []
    @Published var automationOptions = IssueAutomationOptions()
    @Published var isLoadingRepositories = false
    @Published var isLoadingLabels = false
    @Published var isCreating = false
    @Published var createAnother = false
    @Published var errorMessage: String?

    private let service = GitHubIssueCreationService.shared

    var canCreate: Bool {
        !selectedRepository.isEmpty &&
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isCreating
    }

    var hasPendingChanges: Bool {
        !title.isEmpty ||
        !body.isEmpty ||
        !selectedLabels.isEmpty ||
        !customLabelText.isEmpty ||
        hasDueDate ||
        hasOnDate ||
        !attachments.isEmpty ||
        automationOptions.isEnabled
    }

    var repositoryLabels: [GitHubLabelOption] {
        let common = Set(GitHubIssueCreationService.commonLabels)
        return labels.filter {
            !$0.isDateLabel &&
            !common.contains($0.name) &&
            !IssueAutomationOptions.isAutomationLabel($0.name)
        }
    }

    var filteredRepositories: [GitHubRepositoryOption] {
        let query = repositorySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return repositories }
        return repositories.filter {
            $0.nameWithOwner.localizedCaseInsensitiveContains(query) ||
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    var hasExactRepositorySelection: Bool {
        !selectedRepository.isEmpty &&
        repositorySearchText.caseInsensitiveCompare(selectedRepository) == .orderedSame
    }

    func load() async {
        guard repositories.isEmpty, !isLoadingRepositories else { return }
        isLoadingRepositories = true
        errorMessage = nil
        do {
            repositories = try await service.repositories()
            let previous = UserDefaults.standard.string(forKey: "createIssueLastRepository")
            if let previous, repositories.contains(where: { $0.nameWithOwner == previous }) {
                selectedRepository = previous
            } else if let first = repositories.first {
                selectedRepository = first.nameWithOwner
            }
            repositorySearchText = selectedRepository
            await loadLabels()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingRepositories = false
    }

    func selectRepository(_ repository: String) async {
        selectedRepository = repository
        repositorySearchText = repository
        UserDefaults.standard.set(repository, forKey: "createIssueLastRepository")
        selectedLabels.removeAll()
        await loadLabels()
    }

    func repositorySearchChanged() {
        let exactMatch = repositories.first {
            $0.nameWithOwner.caseInsensitiveCompare(repositorySearchText) == .orderedSame
        }
        if let exactMatch {
            guard selectedRepository != exactMatch.nameWithOwner else { return }
            Task { await selectRepository(exactMatch.nameWithOwner) }
        } else if !selectedRepository.isEmpty {
            selectedRepository = ""
            labels = []
            selectedLabels.removeAll()
        }
    }

    @discardableResult
    func moveTitleOverflowToDescription() -> Bool {
        guard title.count > 256 else { return false }
        let fullTitle = title
        title = String(fullTitle.prefix(253)) + "..."
        body = body.isEmpty ? fullTitle : "\(fullTitle)\n\n\(body)"
        return true
    }

    func loadLabels() async {
        guard !selectedRepository.isEmpty else {
            labels = []
            return
        }
        let repository = selectedRepository
        isLoadingLabels = true
        do {
            let loadedLabels = try await service.labels(for: repository)
            guard selectedRepository == repository else { return }
            labels = loadedLabels
        } catch {
            guard selectedRepository == repository else { return }
            errorMessage = error.localizedDescription
            labels = []
        }
        if selectedRepository == repository {
            isLoadingLabels = false
        }
    }

    func toggleLabel(_ name: String) {
        if selectedLabels.contains(name) {
            selectedLabels.remove(name)
        } else {
            selectedLabels.insert(name)
        }
    }

    func addCustomLabel() {
        let label = customLabelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        let normalized = label.lowercased()
        guard !normalized.hasPrefix("due:"), !normalized.hasPrefix("on:") else {
            errorMessage = "Use the date controls for due: and on:"
            return
        }
        guard !IssueAutomationOptions.isAutomationLabel(normalized) else {
            errorMessage = "Use the Automation controls for auto labels"
            return
        }
        if !labels.contains(where: { $0.name.caseInsensitiveCompare(label) == .orderedSame }) {
            labels.append(GitHubLabelOption(name: label, color: "ededed"))
        }
        selectedLabels.insert(label)
        customLabelText = ""
        errorMessage = nil
    }

    func addAttachments(_ urls: [URL]) {
        errorMessage = nil
        for url in urls where !attachments.contains(where: { $0.url == url }) {
            do {
                let attachment = try IssueAttachment(url: url)
                guard attachment.byteCount <= 5 * 1024 * 1024 else {
                    errorMessage = "\(attachment.filename) exceeds 5 MB"
                    continue
                }
                attachments.append(attachment)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func create() async -> CreatedGitHubIssue? {
        guard canCreate else { return nil }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        do {
            return try await service.createIssue(
                repository: selectedRepository,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: body,
                labels: selectedLabels.union(automationOptions.labels),
                dueDate: hasDueDate ? dueDate : nil,
                onDate: hasOnDate ? onDate : nil,
                attachments: attachments)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func resetAfterCreation() {
        title = ""
        body = ""
        selectedLabels.removeAll()
        customLabelText = ""
        hasDueDate = false
        dueDate = Date()
        hasOnDate = false
        onDate = Date()
        attachments.removeAll()
        automationOptions = IssueAutomationOptions()
        createAnother = false
        errorMessage = nil
    }
}

struct CreateGitHubIssueView: View {
    @StateObject private var model = CreateGitHubIssueViewModel()
    @State private var showFileImporter = false
    @State private var showAutomationConfirmation = false
    @State private var isDropTargeted = false
    @FocusState private var focusedField: Field?

    let onCancel: () -> Void
    let onCreated: (CreatedGitHubIssue, String, Bool) -> Void
    let onPendingChangesChanged: (Bool) -> Void

    private enum Field {
        case repository
        case title
        case body
    }

    private let formColumns = [
        GridItem(.flexible(minimum: 120), spacing: 8),
        GridItem(.flexible(minimum: 120), spacing: 8),
        GridItem(.flexible(minimum: 120), spacing: 8)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Repository", text: $model.repositorySearchText)
                        .focused($focusedField, equals: .repository)
                        .onChange(of: model.repositorySearchText) { _ in
                            model.repositorySearchChanged()
                        }

                    if focusedField == .repository && !model.hasExactRepositorySelection {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(model.filteredRepositories.prefix(50)) { repository in
                                    Button {
                                        Task {
                                            await model.selectRepository(repository.nameWithOwner)
                                            focusedField = .title
                                        }
                                    } label: {
                                        Text(repository.nameWithOwner)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 5)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxHeight: 170)
                    }
                }

                Section("Automation") {
                    Toggle("Automatically work on this", isOn: $model.automationOptions.isEnabled)
                        .toggleStyle(.checkbox)

                    if model.automationOptions.isEnabled {
                        Picker("Agent", selection: $model.automationOptions.agent) {
                            ForEach(IssueAutomationOptions.Agent.allCases) { agent in
                                Text(agent.title).tag(agent)
                            }
                        }
                        .pickerStyle(.segmented)

                        Picker("Finish with", selection: $model.automationOptions.result) {
                            ForEach(IssueAutomationOptions.Result.allCases) { result in
                                Text(result.title).tag(result)
                            }
                        }

                        if model.automationOptions.result == .workBranch ||
                            model.automationOptions.result == .workMain {
                            Picker("Commit Changes", selection: $model.automationOptions.commitChanges) {
                                ForEach(IssueAutomationOptions.CommitChanges.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        if model.automationOptions.result == .pullRequest {
                            Picker("Pull Request", selection: $model.automationOptions.pullRequestState) {
                                ForEach(IssueAutomationOptions.PullRequestState.allCases) { state in
                                    Text(state.title).tag(state)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Picker("Launch", selection: $model.automationOptions.launch) {
                            ForEach(IssueAutomationOptions.Launch.allCases) { launch in
                                Text(launch.title).tag(launch)
                            }
                        }
                        .pickerStyle(.segmented)

                        Picker(
                            "Terminate when done",
                            selection: $model.automationOptions.terminateWhenDone
                        ) {
                            ForEach(IssueAutomationOptions.TerminateWhenDone.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .debugLabel("issueAutomationSection")

                TextField("Title", text: $model.title)
                    .focused($focusedField, equals: .title)
                    .onChange(of: model.title) { _ in
                        if model.moveTitleOverflowToDescription() {
                            focusedField = .body
                        }
                    }

                TextEditor(text: $model.body)
                    .font(.body)
                    .frame(minHeight: 110)
                    .focused($focusedField, equals: .body)
                    .overlay(alignment: .topLeading) {
                        if model.body.isEmpty {
                            Text("Description")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }

                Section("Dates") {
                    HStack {
                        Toggle("Due", isOn: $model.hasDueDate)
                            .toggleStyle(.checkbox)
                        DatePicker(
                            "",
                            selection: $model.dueDate,
                            displayedComponents: .date)
                            .labelsHidden()
                            .disabled(!model.hasDueDate)
                        Spacer()
                        Toggle("On", isOn: $model.hasOnDate)
                            .toggleStyle(.checkbox)
                        DatePicker(
                            "",
                            selection: $model.onDate,
                            displayedComponents: .date)
                            .labelsHidden()
                            .disabled(!model.hasOnDate)
                    }
                }

                Section("Common Labels") {
                    LazyVGrid(columns: formColumns, alignment: .leading, spacing: 8) {
                        ForEach(GitHubIssueCreationService.commonLabels, id: \.self) { label in
                            labelButton(label)
                        }
                    }
                }

                Section("Repository Labels") {
                    if model.isLoadingLabels {
                        ProgressView()
                    } else {
                        if !model.repositoryLabels.isEmpty {
                            LazyVGrid(columns: formColumns, alignment: .leading, spacing: 8) {
                                ForEach(model.repositoryLabels) { label in
                                    labelButton(label.name)
                                }
                            }
                        }

                        HStack {
                            TextField("Label", text: $model.customLabelText)
                                .onSubmit { model.addCustomLabel() }
                            Button("Add") { model.addCustomLabel() }
                                .disabled(model.customLabelText
                                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                Section("Attachments") {
                    Button("Add Files…") { showFileImporter = true }

                    ForEach(model.attachments) { attachment in
                        HStack {
                            Image(systemName: attachment.isImage ? "photo" : "doc")
                            Text(attachment.filename)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(ByteCountFormatter.string(
                                fromByteCount: attachment.byteCount,
                                countStyle: .file))
                                .foregroundStyle(.secondary)
                            Button {
                                model.attachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1, dash: [5]))
                        .frame(height: 54)
                        .overlay {
                            Image(systemName: "arrow.down.doc")
                                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                        }
                        .debugLabel("attachmentDropTarget")
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Toggle("Create Another", isOn: $model.createAnother)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Cancel", action: onCancel)
                Button(model.isCreating ? "Creating…" : "Create Issue") {
                    if model.automationOptions.isEnabled {
                        showAutomationConfirmation = true
                    } else {
                        createIssue()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCreate)
            }
            .padding(16)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): model.addAttachments(urls)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .alert("Start Automation?", isPresented: $showAutomationConfirmation) {
            Button("Create & Start") { createIssue() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.automationOptions.confirmationMessage)
        }
        .task {
            await model.load()
            focusedField = .title
        }
        .onChange(of: model.hasPendingChanges) { hasPendingChanges in
            onPendingChangesChanged(hasPendingChanges)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addAttachments(urls)
            return !urls.isEmpty
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .debugLabel("createGitHubIssueView")
    }

    private func createIssue() {
        Task {
            if let issue = await model.create() {
                let repository = model.selectedRepository
                let createAnother = model.createAnother
                onCreated(issue, repository, createAnother)
                if createAnother {
                    model.resetAfterCreation()
                    focusedField = .title
                }
            }
        }
    }

    private func labelButton(_ label: String) -> some View {
        let isSelected = model.selectedLabels.contains(label)
        return Button {
            model.toggleLabel(label)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                Text(label)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
    }
}
