import XCTest
@testable import Space_Manager

final class WindowLayoutTests: XCTestCase {
    private let adapter = MagnetShortcutEditorAdapter()

    func testBuiltInHorizontalCornersUseHalfWidthQuadrantsAndUnifiedKeys() throws {
        let source: [(String, MagnetTargetFrame, String)] = [
            ("command:default.name.topLeft", .init(x: 0, y: 0, width: 12, height: 6), "Q"),
            ("command:default.name.topRight", .init(x: 12, y: 0, width: 12, height: 6), "W"),
            ("command:default.name.bottomLeft", .init(x: 0, y: 6, width: 12, height: 6), "A"),
            ("command:default.name.bottomRight", .init(x: 12, y: 6, width: 12, height: 6), "S")
        ]
        let configuration = makeConfiguration(horizontal: source.enumerated().map { index, item in
            makeCommand(
                id: "corner-\(index)",
                name: item.0,
                orientation: .horizontal,
                frame: item.1,
                keyCode: UInt32(index))
        })

        let commands = adapter.editorCommands(from: configuration)
        XCTAssertEqual(commands.map(\.destinationKey), source.map(\.2))
        XCTAssertEqual(commands.map(\.group), Array(repeating: .halves, count: 4))
        XCTAssertEqual(commands.map(\.section), Array(repeating: "Corners", count: 4))
        XCTAssertEqual(commands.map(\.x), [0, 0.5, 0, 0.5])
        XCTAssertEqual(commands.map(\.y), [0, 0, 0.5, 0.5])
        XCTAssertEqual(commands.map(\.width), Array(repeating: 0.5, count: 4))
        XCTAssertEqual(commands.map(\.height), Array(repeating: 0.5, count: 4))
    }

    func testHorizontalQuarterColumnsUseTheirOwnPositions() throws {
        let names = ["Left 1/4", "Center Left 1/4", "Center Right 1/4", "Right 1/4"]
        let configuration = makeConfiguration(horizontal: names.enumerated().map { index, name in
            makeCommand(
                id: "quarter-\(index)",
                name: name,
                orientation: .horizontal,
                frame: .init(x: Double(index * 3), y: 0, width: 3, height: 12),
                keyCode: UInt32(18 + index),
                modifiers: 6656)
        })

        let commands = adapter.editorCommands(from: configuration)
        XCTAssertEqual(commands.map(\.x), [0, 0.25, 0.5, 0.75])
        XCTAssertEqual(commands.map(\.width), Array(repeating: 0.25, count: 4))
        XCTAssertEqual(commands.map(\.height), Array(repeating: 1, count: 4))
        XCTAssertEqual(commands.map(\.group), Array(repeating: .quarters, count: 4))
        XCTAssertEqual(commands.map(\.section), Array(repeating: "Full Height", count: 4))
    }

    func testHorizontalLeftAndRightHalvesUseArrowKeys() throws {
        let configuration = makeConfiguration(horizontal: [
            makeCommand(
                id: "left-half",
                name: "command:default.name.left",
                orientation: .horizontal,
                frame: .init(x: 0, y: 0, width: 12, height: 12),
                keyCode: 18),
            makeCommand(
                id: "right-half",
                name: "command:default.name.right",
                orientation: .horizontal,
                frame: .init(x: 12, y: 0, width: 12, height: 12),
                keyCode: 19)
        ])

        let edits = adapter.editorCommands(from: configuration)
        XCTAssertEqual(edits.map(\.destinationKey), ["←", "→"])

        let updated = try adapter.applying(edits, to: configuration)
        XCTAssertEqual(
            updated.commands(for: .horizontal).compactMap { $0.shortcut?.carbonKeyCode },
            [123, 124])
    }

    func testNumberShortcutsAcceptNumberRowAndKeypadCodes() {
        let expected: [String: [UInt32]] = [
            "0": [29, 82], "1": [18, 83], "2": [19, 84], "3": [20, 85],
            "4": [21, 86], "5": [23, 87], "6": [22, 88], "7": [26, 89],
            "8": [28, 91], "9": [25, 92]
        ]
        for (number, codes) in expected {
            XCTAssertEqual(MagnetKeyCodes.codes(for: number), codes)
            XCTAssertEqual(MagnetKeyCodes.codes(for: "KP\(number)"), codes)
        }
        XCTAssertEqual(MagnetKeyCodes.codes(for: "Q"), [12])
    }

    func testKeyboardHighlightsShowBothNumberLocations() {
        let highlights = WindowLayoutCommandColors.keyboardHighlights(for: [("3", .blue)])
        XCTAssertNotNil(highlights["3"])
        XCTAssertNotNil(highlights["kp3"])

        let keypadHighlights = WindowLayoutCommandColors.keyboardHighlights(for: [("KP8", .red)])
        XCTAssertNotNil(keypadHighlights["8"])
        XCTAssertNotNil(keypadHighlights["kp8"])
    }

    func testEveryShortcutInAGroupGetsItsOwnColorToken() {
        for orientation in MagnetDisplayOrientation.allCases {
            for group in MagnetShortcutGroup.allCases {
                let commands = MagnetShortcutCommand.standardSet.filter {
                    $0.orientation == orientation && $0.group == group
                }
                let tokens = commands.map {
                    WindowLayoutCommandColors.token(for: $0, among: commands)
                }
                XCTAssertEqual(
                    Set(tokens).count,
                    commands.count,
                    "Duplicate color token in \(orientation.rawValue) \(group.title)")
            }
        }
    }

    func testShortcutStoreMirrorsPortableConfigurationIntoProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let store = WindowLayoutShortcutStore(homeDirectory: home, projectRoot: project)
        let commands = Array(MagnetShortcutCommand.standardSet.prefix(3))

        try store.save(commands)

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.applicationSupportURL.path))
        let projectURL = try XCTUnwrap(store.projectURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
        XCTAssertEqual(
            try Data(contentsOf: store.applicationSupportURL),
            try Data(contentsOf: projectURL))
        XCTAssertEqual(try store.load(), commands)
    }

    @MainActor
    func testOnlyExactWindowActionNamesReceiveSpecialRouting() {
        XCTAssertEqual(WindowLayoutManager.operation(for: "Center"), .center)
        XCTAssertEqual(WindowLayoutManager.operation(for: "Center Left 1/4"), .frame)
        XCTAssertEqual(WindowLayoutManager.operation(for: "Center Right 1/4"), .frame)
        XCTAssertEqual(WindowLayoutManager.operation(for: "Center Third"), .frame)
        XCTAssertEqual(WindowLayoutManager.operation(for: "Center Two Thirds"), .frame)
        XCTAssertEqual(WindowLayoutManager.operation(for: "Maximize"), .maximize)
        XCTAssertEqual(WindowLayoutManager.operation(for: "Restore"), .restore)
        XCTAssertEqual(WindowLayoutManager.operation(for: "Next Display"), .nextDisplay)
        XCTAssertEqual(WindowLayoutManager.operation(for: "Previous Display"), .previousDisplay)
    }

    func testPortraitCenterThirdIsVisibleInFullWidthThirds() throws {
        let configuration = makeConfiguration(vertical: [
            makeCommand(
                id: "center-third",
                name: "command:default.name.centerThird",
                orientation: .vertical,
                frame: .init(x: 0, y: 8, width: 12, height: 8),
                keyCode: 19,
                modifiers: 4352)
        ])

        let command = try XCTUnwrap(adapter.editorCommands(from: configuration).first)
        XCTAssertEqual(command.name, "Center Third")
        XCTAssertEqual(command.group, .thirds)
        XCTAssertEqual(command.section, "Full Width")
        XCTAssertEqual(command.x, 0)
        XCTAssertEqual(command.y, 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(command.width, 1)
        XCTAssertEqual(command.height, 1.0 / 3.0, accuracy: 0.000_001)
    }

    func testKnownMalformedPortraitEighthIsCorrected() throws {
        let configuration = makeConfiguration(vertical: [
            makeCommand(
                id: "top-three-eighths-left",
                name: "Top 3/8 Left",
                orientation: .vertical,
                frame: .init(x: 0, y: 5, width: 6, height: 4),
                keyCode: 14,
                modifiers: 6912)
        ])

        let command = try XCTUnwrap(adapter.editorCommands(from: configuration).first)
        XCTAssertEqual(command.x, 0)
        XCTAssertEqual(command.y, 0.25)
        XCTAssertEqual(command.width, 0.5)
        XCTAssertEqual(command.height, 0.125)
    }

    func testFallbackCatalogIsCompleteBoundedAndCollisionFree() {
        let commands = MagnetShortcutCommand.standardSet
        let expected: [MagnetDisplayOrientation: [MagnetShortcutGroup: Int]] = [
            .portrait: [.basics: 8, .halves: 8, .thirds: 9, .quarters: 12, .sixths: 18, .eighths: 24],
            .horizontal: [.basics: 8, .halves: 8, .thirds: 3, .quarters: 4, .sixths: 6, .eighths: 8]
        ]

        for orientation in MagnetDisplayOrientation.allCases {
            let oriented = commands.filter { $0.orientation == orientation }
            XCTAssertEqual(oriented.count, expected[orientation]?.values.reduce(0, +))
            for group in MagnetShortcutGroup.allCases {
                XCTAssertEqual(
                    oriented.filter { $0.group == group }.count,
                    expected[orientation]?[group] ?? 0,
                    "Unexpected \(orientation.rawValue) \(group.title) count")
            }

            let activeChords = oriented.filter(\.isEnabled).map(\.shortcutText)
            XCTAssertEqual(Set(activeChords).count, activeChords.count, "Duplicate \(orientation.rawValue) shortcuts")

            for command in oriented {
                XCTAssertGreaterThan(command.width, 0, command.name)
                XCTAssertGreaterThan(command.height, 0, command.name)
                XCTAssertGreaterThanOrEqual(command.x, 0, command.name)
                XCTAssertGreaterThanOrEqual(command.y, 0, command.name)
                XCTAssertLessThanOrEqual(command.x + command.width, 1.000_001, command.name)
                XCTAssertLessThanOrEqual(command.y + command.height, 1.000_001, command.name)
            }
        }
    }

    func testEveryOfferedExtendedKeyRoundTripsThroughMagnetConfiguration() throws {
        let keys: [(String, UInt32)] = [
            ("Clear", 71), ("KP Enter", 76), ("F17", 64), ("F18", 79), ("F19", 80)
        ]
        let configuration = makeConfiguration(vertical: keys.enumerated().map { index, _ in
            makeCommand(
                id: "key-\(index)",
                name: "Key \(index)",
                orientation: .vertical,
                frame: .init(x: 0, y: Double(index), width: 1, height: 1),
                keyCode: 18 + UInt32(index))
        })
        var edits = adapter.editorCommands(from: configuration)
        for index in edits.indices {
            edits[index].destinationKey = keys[index].0
        }

        let updated = try adapter.applying(edits, to: configuration)
        XCTAssertEqual(
            updated.commands(for: .vertical).compactMap { $0.shortcut?.carbonKeyCode },
            keys.map(\.1))
        for (name, code) in keys {
            XCTAssertEqual(MagnetKeyCodes.code(for: name), code)
            XCTAssertEqual(MagnetKeyCodes.name(for: code), name)
        }
    }

    @MainActor
    func testScreenSelectionUsesIntersectionThenNearestScreen() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: 1000, y: 0, width: 1000, height: 800),
            CGRect(x: -800, y: 100, width: 800, height: 1200)
        ]
        XCTAssertEqual(
            WindowLayoutManager.bestScreenIndex(
                for: CGRect(x: 900, y: 100, width: 400, height: 400),
                screenFrames: screens),
            1)
        XCTAssertEqual(
            WindowLayoutManager.bestScreenIndex(
                for: CGRect(x: 2200, y: 200, width: 100, height: 100),
                screenFrames: screens),
            1)
        XCTAssertEqual(
            WindowLayoutManager.bestScreenIndex(
                for: CGRect(x: -1000, y: 600, width: 50, height: 50),
                screenFrames: screens),
            2)
    }

    private func makeConfiguration(
        vertical: [MagnetCommand] = [],
        horizontal: [MagnetCommand] = []
    ) -> MagnetShortcutConfiguration {
        MagnetShortcutConfiguration(
            verticalCommands: vertical,
            horizontalCommands: horizontal,
            sourcePropertyList: Data(),
            importedAt: Date())
    }

    private func makeCommand(
        id: String,
        name: String,
        orientation: MagnetOrientation,
        frame: MagnetTargetFrame,
        keyCode: UInt32,
        modifiers: UInt32 = 6144
    ) -> MagnetCommand {
        MagnetCommand(rawObject: [
            "id": .string(id),
            "name": .string(name),
            "axis": .string(orientation.rawValue),
            "category": .string("custom"),
            "keyboardShortcut": .object([
                "available": .bool(true),
                "enabled": .bool(true),
                "shortcut": .object([
                    "carbonKeyCode": .number(Double(keyCode)),
                    "carbonModifiers": .number(Double(modifiers))
                ])
            ]),
            "targetArea": .object([
                "available": .bool(true),
                "area": .object([
                    "segments": .array([
                        .object([
                            "id": .string("segment-\(id)"),
                            "frame": .array([
                                .array([.number(frame.x), .number(frame.y)]),
                                .array([.number(frame.width), .number(frame.height)])
                            ])
                        ])
                    ])
                ])
            ])
        ])
    }
}
