import AppKit
import XCTest
@testable import Space_Manager

@MainActor
final class IssueMenuItemTests: XCTestCase {
    func testNormalClickOpensBrowserAndOptionClickLaunchesProject() throws {
        let issue = GitHubIssue(
            number: 8,
            title: "Issue row action",
            url: "https://github.com/smunn/mac-space-manager/issues/8",
            updatedAt: "2026-08-20T12:00:00Z",
            repository: .init(
                name: "mac-space-manager",
                nameWithOwner: "smunn/mac-space-manager"),
            labels: [])
        let items = StatusBarController.makeIssueMenuItems(
            for: issue,
            includesRepository: true,
            target: NSObject())

        XCTAssertEqual(items.count, 2)

        let browserItem = items[0]
        XCTAssertEqual(browserItem.action, NSSelectorFromString("openIssueInBrowser:"))
        XCTAssertFalse(browserItem.isAlternate)
        XCTAssertTrue(try XCTUnwrap(browserItem.attributedTitle).string.hasSuffix("  ↗"))

        let projectItem = items[1]
        XCTAssertEqual(projectItem.action, NSSelectorFromString("openIssueProject:"))
        XCTAssertTrue(projectItem.isAlternate)
        XCTAssertEqual(projectItem.keyEquivalentModifierMask, .option)
        XCTAssertFalse(try XCTUnwrap(projectItem.attributedTitle).string.contains("↗"))

        let browserInfo = try XCTUnwrap(browserItem.representedObject as? [String: Any])
        XCTAssertEqual(browserInfo["url"] as? String, issue.url)

        let projectInfo = try XCTUnwrap(projectItem.representedObject as? [String: Any])
        XCTAssertEqual(projectInfo["repoFullName"] as? String, issue.repoFullName)
        XCTAssertEqual(projectInfo["number"] as? Int, issue.number)
    }
}
