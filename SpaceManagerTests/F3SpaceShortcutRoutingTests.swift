import XCTest
@testable import Space_Manager

final class F3SpaceShortcutRoutingTests: XCTestCase {
    func testNumberRowAndKeypadMapToDesktopNumbers() {
        let expected: [(Int64, Int)] = [
            (18, 1), (19, 2), (20, 3), (21, 4), (23, 5),
            (22, 6), (26, 7), (28, 8), (25, 9), (29, 10),
            (83, 1), (84, 2), (85, 3), (86, 4), (87, 5),
            (88, 6), (89, 7), (91, 8), (92, 9), (82, 10)
        ]

        for (keyCode, desktopNumber) in expected {
            XCTAssertEqual(
                F3SpaceShortcutRouting.desktopNumber(forKeyCode: keyCode),
                desktopNumber)
        }
        XCTAssertNil(F3SpaceShortcutRouting.desktopNumber(forKeyCode: 12))
    }

    func testMissionControlMediaKeyStatesAreRecognized() {
        XCTAssertEqual(F3SpaceShortcutRouting.f3MediaKeyIsPressed(data1: 0x0002_0A00), true)
        XCTAssertEqual(F3SpaceShortcutRouting.f3MediaKeyIsPressed(data1: 0x0002_0C00), true)
        XCTAssertEqual(F3SpaceShortcutRouting.f3MediaKeyIsPressed(data1: 0x0002_0B00), false)
        XCTAssertNil(F3SpaceShortcutRouting.f3MediaKeyIsPressed(data1: 0x0003_0A00))
    }
}
