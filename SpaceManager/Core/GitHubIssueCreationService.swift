//
//  GitHubIssueCreationService.swift
//  SpaceManager
//

import Foundation
import UniformTypeIdentifiers

actor GitHubIssueCreationService {
    static let shared = GitHubIssueCreationService()

    static let commonLabels = [
        "needs-review",
        "in-progress",
        "enhancement",
        "waiting",
        "needs-confirmation",
        "bug",
        "blocked",
        "needs-testing",
        "needs-verification"
    ]

    private let githubAPIBaseURL = URL(string: "https://api.github.com")!
    private let attachmentUploadURL = URL(
        string: "https://smt-web-services.netlify.app/api/issue-attachments")!
    private var cachedToken: String?

    func repositories() async throws -> [GitHubRepositoryOption] {
        var result: [GitHubRepositoryOption] = []
        var page = 1

        while true {
            var components = URLComponents(
                url: githubAPIBaseURL.appendingPathComponent("user/repos"),
                resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
                URLQueryItem(name: "sort", value: "pushed"),
                URLQueryItem(name: "direction", value: "desc"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ]
            let pageItems: [GitHubRepositoryOption] = try await request(components.url!)
            result.append(contentsOf: pageItems)
            if pageItems.count < 100 { break }
            page += 1
        }

        return result.filter { !$0.archived && ($0.permissions?.push ?? false) }
    }

    func labels(for repository: String) async throws -> [GitHubLabelOption] {
        var result: [GitHubLabelOption] = []
        var page = 1

        while true {
            let url = try repositoryURL(repository, suffix: "labels", queryItems: [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ])
            let pageItems: [GitHubLabelOption] = try await request(url)
            result.append(contentsOf: pageItems)
            if pageItems.count < 100 { break }
            page += 1
        }

        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func createIssue(
        repository: String,
        title: String,
        body: String,
        labels selectedLabels: Set<String>,
        dueDate: Date?,
        onDate: Date?,
        attachments: [IssueAttachment]
    ) async throws -> CreatedGitHubIssue {
        var labelNames = selectedLabels.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        var colorsByLabel = Dictionary(
            uniqueKeysWithValues: try await labels(for: repository).map { ($0.name, $0.color) })

        if let dueDate {
            let name = "due:\(Self.storedDateString(dueDate))"
            labelNames.append(name)
            colorsByLabel[name] = Self.weekdayColor(for: dueDate)
        }
        if let onDate {
            let name = "on:\(Self.storedDateString(onDate))"
            labelNames.append(name)
            colorsByLabel[name] = Self.weekdayColor(for: onDate)
        }

        for labelName in labelNames where colorsByLabel[labelName] == nil {
            try await createLabel(
                labelName,
                color: Self.commonLabelColors[labelName] ?? "ededed",
                in: repository)
            colorsByLabel[labelName] = Self.commonLabelColors[labelName] ?? "ededed"
        }

        var submittedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var finalBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if submittedTitle.count > 256 {
            let fullTitle = submittedTitle
            submittedTitle = String(submittedTitle.prefix(253)) + "..."
            finalBody = finalBody.isEmpty ? fullTitle : "\(fullTitle)\n\n\(finalBody)"
        }
        if !attachments.isEmpty {
            let markdown = try await upload(attachments: attachments, repository: repository)
                .joined(separator: "\n")
            finalBody = finalBody.isEmpty ? markdown : "\(finalBody)\n\n\(markdown)"
        }

        let payload = CreateIssuePayload(
            title: submittedTitle,
            body: finalBody.isEmpty ? nil : finalBody,
            labels: labelNames)
        let url = try repositoryURL(repository, suffix: "issues")
        return try await request(url, method: "POST", body: payload)
    }

    private func upload(
        attachments: [IssueAttachment],
        repository: String
    ) async throws -> [String] {
        let coordinates = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard coordinates.count == 2 else { throw ServiceError.invalidRepository }
        let token = try await githubToken()
        var markdown: [String] = []

        for attachment in attachments {
            let data = try Data(contentsOf: attachment.url, options: .mappedIfSafe)
            guard data.count <= 5 * 1024 * 1024 else {
                throw ServiceError.attachmentTooLarge(attachment.filename)
            }

            var request = URLRequest(url: attachmentUploadURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(coordinates[0], forHTTPHeaderField: "X-Repository-Owner")
            request.setValue(coordinates[1], forHTTPHeaderField: "X-Repository-Name")
            request.setValue(Self.safeFilename(attachment.filename), forHTTPHeaderField: "X-Filename")
            request.setValue(attachment.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = data

            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else { throw Self.apiError(from: responseData, fallback: "Attachment upload failed") }

            let uploaded = try JSONDecoder().decode(UploadedAttachment.self, from: responseData)
            let escapedName = uploaded.filename.replacingOccurrences(of: "]", with: "\\]")
            if uploaded.contentType.hasPrefix("image/") {
                markdown.append("![\(escapedName)](\(uploaded.url.absoluteString))")
            } else {
                markdown.append("[\(escapedName)](\(uploaded.url.absoluteString))")
            }
        }
        return markdown
    }

    private func createLabel(_ name: String, color: String, in repository: String) async throws {
        let url = try repositoryURL(repository, suffix: "labels")
        let payload = CreateLabelPayload(name: name, color: color)
        let _: GitHubLabelOption = try await request(url, method: "POST", body: payload)
    }

    private func repositoryURL(
        _ repository: String,
        suffix: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        let coordinates = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard coordinates.count == 2 else { throw ServiceError.invalidRepository }
        var components = URLComponents(
            url: githubAPIBaseURL
                .appendingPathComponent("repos")
                .appendingPathComponent(coordinates[0])
                .appendingPathComponent(coordinates[1])
                .appendingPathComponent(suffix),
            resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url!
    }

    private func request<Response: Decodable & Sendable>(
        _ url: URL,
        method: String = "GET"
    ) async throws -> Response {
        try await request(url, method: method, bodyData: nil)
    }

    private func request<Response: Decodable & Sendable, Body: Encodable>(
        _ url: URL,
        method: String,
        body: Body
    ) async throws -> Response {
        try await request(url, method: method, bodyData: JSONEncoder().encode(body))
    }

    private func request<Response: Decodable & Sendable>(
        _ url: URL,
        method: String,
        bodyData: Data?
    ) async throws -> Response {
        let token = try await githubToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else { throw Self.apiError(from: data, fallback: "GitHub request failed") }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func githubToken() async throws -> String {
        if let cachedToken { return cachedToken }
        let token = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "gh auth token"]
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ServiceError.githubAuthenticationRequired
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty
            else { throw ServiceError.githubAuthenticationRequired }
            return token
        }.value
        cachedToken = token
        return token
    }

    private static func apiError(from data: Data, fallback: String) -> Error {
        if let response = try? JSONDecoder().decode(APIErrorResponse.self, from: data),
           let message = response.message ?? response.error,
           !message.isEmpty {
            return ServiceError.api(message)
        }
        return ServiceError.api(fallback)
    }

    private static func storedDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func safeFilename(_ filename: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = filename.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(scalars).prefix(120)
        return result.isEmpty ? "attachment" : String(result)
    }

    private static func weekdayColor(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return weekdayColors[calendar.component(.weekday, from: date)] ?? "ededed"
    }

    private static let weekdayColors = [
        1: "fdf3d0",
        2: "d3dfe2",
        3: "eecdcd",
        4: "f8e6d0",
        5: "ccdaf5",
        6: "dce9d5",
        7: "d8d2e7"
    ]

    private static let commonLabelColors = [
        "bug": "d73a4a",
        "enhancement": "a2eeef"
    ]
}

private extension GitHubIssueCreationService {
    struct CreateIssuePayload: Encodable {
        let title: String
        let body: String?
        let labels: [String]
    }

    struct CreateLabelPayload: Encodable {
        let name: String
        let color: String
    }

    struct UploadedAttachment: Decodable {
        let url: URL
        let filename: String
        let contentType: String
    }

    struct APIErrorResponse: Decodable {
        let message: String?
        let error: String?
    }

    enum ServiceError: LocalizedError {
        case invalidRepository
        case githubAuthenticationRequired
        case attachmentTooLarge(String)
        case api(String)

        var errorDescription: String? {
            switch self {
            case .invalidRepository: "Select a repository"
            case .githubAuthenticationRequired: "Sign in with gh to create issues"
            case .attachmentTooLarge(let filename): "\(filename) exceeds 5 MB"
            case .api(let message): message
            }
        }
    }
}

extension IssueAttachment {
    init(url: URL) throws {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        self.init(
            url: url,
            byteCount: Int64(resourceValues.fileSize ?? 0),
            contentType: resourceValues.contentType?.preferredMIMEType ?? "application/octet-stream")
    }
}
