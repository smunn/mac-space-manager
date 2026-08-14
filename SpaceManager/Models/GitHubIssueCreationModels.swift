//
//  GitHubIssueCreationModels.swift
//  SpaceManager
//

import Foundation

struct GitHubRepositoryOption: Codable, Identifiable, Sendable {
    let nameWithOwner: String
    let archived: Bool
    let pushedAt: String?
    let permissions: Permissions?

    struct Permissions: Codable, Sendable {
        let push: Bool
    }

    enum CodingKeys: String, CodingKey {
        case nameWithOwner = "full_name"
        case archived
        case pushedAt = "pushed_at"
        case permissions
    }

    var id: String { nameWithOwner }
    var name: String { nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner }
}

struct GitHubLabelOption: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let color: String

    var id: String { name }
    var isDateLabel: Bool {
        let normalized = name.lowercased()
        return normalized.hasPrefix("due:") || normalized.hasPrefix("on:")
    }
}

struct CreatedGitHubIssue: Codable, Sendable {
    let number: Int
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case number
        case htmlURL = "html_url"
    }
}

struct IssueAutomationOptions: Equatable {
    enum Agent: String, CaseIterable, Identifiable {
        case defaultAgent, claude, codex
        var id: Self { self }
        var title: String {
            switch self {
            case .defaultAgent: "Default"
            case .claude: "Claude"
            case .codex: "Codex"
            }
        }
        var triggerLabel: String {
            switch self {
            case .defaultAgent: "auto-work"
            case .claude: "auto-work:claude"
            case .codex: "auto-work:codex"
            }
        }
    }

    enum Result: String, CaseIterable, Identifiable {
        case workBranch, workMain, pullRequest, shipMain
        var id: Self { self }
        var title: String {
            switch self {
            case .workBranch: "Work on Branch"
            case .workMain: "Work on Main"
            case .pullRequest: "Pull Request"
            case .shipMain: "Ship to Main"
            }
        }
        var label: String {
            switch self {
            case .workBranch: "auto-result:work-branch"
            case .workMain: "auto-result:work-main"
            case .pullRequest: "auto-result:pr"
            case .shipMain: "auto-result:ship-main"
            }
        }
    }

    enum CommitChanges: String, CaseIterable, Identifiable {
        case agent, always, never
        var id: Self { self }
        var title: String {
            switch self {
            case .agent: "Agent Decides"
            case .always: "Always"
            case .never: "Never"
            }
        }
        var label: String { "auto-commit:\(rawValue)" }
    }

    enum PullRequestState: String, CaseIterable, Identifiable {
        case draft, ready
        var id: Self { self }
        var title: String { self == .draft ? "Draft PR" : "Ready for Review" }
        var label: String { "auto-pr:\(rawValue)" }
    }

    enum Launch: String, CaseIterable, Identifiable {
        case terminal, headless
        var id: Self { self }
        var title: String { self == .terminal ? "Launch Terminal" : "Headless" }
        var label: String { "auto-launch:\(rawValue)" }
    }

    enum TerminateWhenDone: String, CaseIterable, Identifiable {
        case yes, no
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var label: String { "auto-terminate:\(rawValue)" }
    }

    var isEnabled = false
    var agent = Agent.defaultAgent
    var result = Result.pullRequest
    var commitChanges = CommitChanges.agent
    var pullRequestState = PullRequestState.draft
    var launch = Launch.terminal
    var terminateWhenDone = TerminateWhenDone.yes

    var labels: Set<String> {
        guard isEnabled else { return [] }
        var labels: Set<String> = [
            agent.triggerLabel, "auto-run:local", result.label,
            launch.label, terminateWhenDone.label
        ]
        if result == .pullRequest { labels.insert(pullRequestState.label) }
        if result == .workBranch || result == .workMain { labels.insert(commitChanges.label) }
        return labels
    }

    var confirmationMessage: String {
        let start = launch == .terminal ? "Dispatcher will launch Terminal" : "Dispatcher will run headlessly"
        let finish = terminateWhenDone == .yes
            ? "The agent session will terminate when it finishes."
            : "The agent session will remain available when it finishes."
        let commit: String
        switch commitChanges {
        case .agent: commit = "The agent will decide whether to commit the changes."
        case .always: commit = "The changes will be committed when the work finishes."
        case .never: commit = "The changes will remain uncommitted."
        }

        switch result {
        case .pullRequest:
            let state = pullRequestState == .draft ? "a draft pull request" : "a pull request ready for review"
            return "\(start) on its next check (within about five minutes), work in an isolated worktree, and create \(state). \(finish)"
        case .workBranch:
            return "\(start) on its next check (within about five minutes) and work in an isolated worktree without pushing. \(commit) \(finish)"
        case .workMain:
            return "\(start) on its next check (within about five minutes) and work on main only if the repository is clean and can update safely. Otherwise, it will stop and notify you in Slack. \(commit) \(finish)"
        case .shipMain:
            return "\(start) on its next check (within about five minutes), work in an isolated worktree, and push to main only after safely updating from origin. If it cannot proceed safely, it will stop and notify you in Slack. \(finish)"
        }
    }

    static func isAutomationLabel(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized == "auto-work" || normalized.hasPrefix("auto-work:") ||
            normalized.hasPrefix("auto-run:") || normalized.hasPrefix("auto-result:") ||
            normalized.hasPrefix("auto-pr:") || normalized.hasPrefix("auto-launch:") ||
            normalized.hasPrefix("auto-commit:") || normalized.hasPrefix("auto-terminate:")
    }
}

struct IssueAttachment: Identifiable, Hashable {
    let url: URL
    let byteCount: Int64
    let contentType: String

    var id: URL { url }
    var filename: String { url.lastPathComponent }
    var isImage: Bool { contentType.hasPrefix("image/") }
}
