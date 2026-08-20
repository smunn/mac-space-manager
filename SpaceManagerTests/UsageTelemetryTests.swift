import AppKit
import XCTest
@testable import Space_Manager

final class UsageTelemetryTests: XCTestCase {
    func testRecorderWritesMatchedMenuSessionAndDuration() throws {
        let store = InMemoryUsageTelemetryStore()
        var dates = [
            Date(timeIntervalSince1970: 100),
            Date(timeIntervalSince1970: 104.25)
        ]
        let recorder = UsageTelemetryRecorder(
            store: store,
            now: { dates.removeFirst() })
        let identifier = TelemetryIdentifier(rawValue: "menu.performance")

        recorder.menuOpened(identifier)
        recorder.menuClosed(identifier)

        let events = try store.loadEvents()
        XCTAssertEqual(events.map(\.kind), [.menuOpened, .menuClosed])
        XCTAssertEqual(events[0].sessionID, events[1].sessionID)
        XCTAssertEqual(events[1].durationSeconds, 4.25)
    }

    func testRecorderIgnoresDuplicateOpenAndUnmatchedClose() throws {
        let store = InMemoryUsageTelemetryStore()
        let recorder = UsageTelemetryRecorder(
            store: store,
            now: { Date(timeIntervalSince1970: 100) })
        let identifier = TelemetryIdentifier(rawValue: "menu.close")

        recorder.menuOpened(identifier)
        recorder.menuOpened(identifier)
        recorder.menuClosed(identifier)
        recorder.menuClosed(identifier)

        XCTAssertEqual(try store.loadEvents().map(\.kind), [.menuOpened, .menuClosed])
    }

    func testJSONLinesStorePreservesValidEventsAroundMalformedLine() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("state/events.jsonl")
        let store = JSONLinesUsageTelemetryStore(fileURL: fileURL)
        let event = UsageTelemetryEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            kind: .actionSelected,
            identifier: TelemetryIdentifier(rawValue: "action.new_space"))

        try store.append(event)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        try store.append(event)

        XCTAssertEqual(try store.loadEvents(), [event, event])
    }

    @MainActor
    func testObserverRecordsForwardedSubmenuCallbacksAndSelectorActions() throws {
        let store = InMemoryUsageTelemetryStore()
        let recorder = UsageTelemetryRecorder(store: store)
        let center = NotificationCenter()
        let observer = MenuTelemetryObserver(recorder: recorder, notificationCenter: center)
        let menu = NSMenu()
        let identifier = TelemetryIdentifier(rawValue: "menu.root")
        let item = NSMenuItem(
            title: "Private content is not recorded",
            action: #selector(ActionTarget.openSettings(_:)),
            keyEquivalent: "")

        observer.register(menu: menu, identifier: identifier)
        observer.menuWillOpen(menu)
        center.post(
            name: NSMenu.didSendActionNotification,
            object: menu,
            userInfo: ["MenuItem": item])
        observer.menuDidClose(menu)

        let events = try store.loadEvents()
        XCTAssertEqual(events.map(\.kind), [.menuOpened, .actionSelected, .menuClosed])
        XCTAssertEqual(events[1].identifier.rawValue, "action.openSettings")
        XCTAssertEqual(events[1].parentIdentifier, identifier)
        XCTAssertEqual(events[1].sessionID, events[0].sessionID)
        XCTAssertFalse(events[1].identifier.rawValue.contains(item.title))
    }

    @MainActor
    func testObserverUnregisterAllStopsNotifications() throws {
        let store = InMemoryUsageTelemetryStore()
        let center = NotificationCenter()
        let observer = MenuTelemetryObserver(
            recorder: UsageTelemetryRecorder(store: store),
            notificationCenter: center)
        let menu = NSMenu()
        observer.register(
            menu: menu,
            identifier: TelemetryIdentifier(rawValue: "menu.disposable"))

        observer.unregisterAll()
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)

        XCTAssertTrue(try store.loadEvents().isEmpty)
    }

    @MainActor
    func testUnregisterAllClosesSessionsSoRebuiltMenusCanOpenAgain() throws {
        let store = InMemoryUsageTelemetryStore()
        let observer = MenuTelemetryObserver(
            recorder: UsageTelemetryRecorder(store: store),
            notificationCenter: NotificationCenter())
        let originalMenu = NSMenu()
        let rebuiltMenu = NSMenu()
        let identifier = TelemetryIdentifier(rawValue: "menu.current_space")
        observer.register(menu: originalMenu, identifier: identifier)
        observer.menuWillOpen(originalMenu)

        observer.unregisterAll()
        observer.register(menu: rebuiltMenu, identifier: identifier)
        observer.menuWillOpen(rebuiltMenu)

        let events = try store.loadEvents()
        XCTAssertEqual(events.map(\.kind), [.menuOpened, .menuClosed, .menuOpened])
        XCTAssertNotEqual(events[0].sessionID, events[2].sessionID)
    }

    @MainActor
    func testRootEndTrackingClosesEveryOpenSubmenuSession() throws {
        let store = InMemoryUsageTelemetryStore()
        let center = NotificationCenter()
        let observer = MenuTelemetryObserver(
            recorder: UsageTelemetryRecorder(store: store),
            notificationCenter: center)
        let rootMenu = NSMenu()
        let submenu = NSMenu()
        observer.register(
            menu: rootMenu,
            identifier: TelemetryIdentifier(rawValue: "menu.root"))
        observer.register(
            menu: submenu,
            identifier: TelemetryIdentifier(rawValue: "menu.performance"))

        observer.menuWillOpen(rootMenu)
        observer.menuWillOpen(submenu)
        center.post(name: NSMenu.didEndTrackingNotification, object: rootMenu)

        let events = try store.loadEvents()
        XCTAssertEqual(events.filter { $0.kind == .menuOpened }.count, 2)
        XCTAssertEqual(events.filter { $0.kind == .menuClosed }.count, 2)
        XCTAssertEqual(
            Set(events.filter { $0.kind == .menuClosed }.map(\.identifier.rawValue)),
            ["menu.root", "menu.performance"])
    }

    func testExporterWritesRawEventsAndAnalysisPrompt() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryUsageTelemetryStore()
        try store.append(UsageTelemetryEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            kind: .actionSelected,
            identifier: TelemetryIdentifier(rawValue: "action.switch_space")))
        let exporter = UsageTelemetryReportExporter(
            store: store,
            now: { Date(timeIntervalSince1970: 200) })

        let result = try exporter.export(to: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.rawDataURL.path))
        let prompt = try String(contentsOf: result.analysisPromptURL)
        XCTAssertTrue(prompt.contains("propose a specific top-to-bottom order"))
        XCTAssertTrue(prompt.contains("space-manager-telemetry.json"))
        let raw = try JSONDecoder.telemetryDecoder.decode(
            [UsageTelemetryEvent].self,
            from: Data(contentsOf: result.rawDataURL))
        XCTAssertEqual(raw.first?.identifier.rawValue, "action.switch_space")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private final class InMemoryUsageTelemetryStore: UsageTelemetryStoring {
    private var events: [UsageTelemetryEvent] = []

    func append(_ event: UsageTelemetryEvent) throws {
        events.append(event)
    }

    func loadEvents() throws -> [UsageTelemetryEvent] {
        events
    }
}

private final class ActionTarget: NSObject {
    @objc func openSettings(_ sender: Any?) {}
}

private extension JSONDecoder {
    static var telemetryDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
