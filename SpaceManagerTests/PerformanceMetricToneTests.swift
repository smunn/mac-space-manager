import XCTest
@testable import Space_Manager

final class PerformanceMetricToneTests: XCTestCase {
    func testCPUThresholds() {
        XCTAssertEqual(PerformanceMetricTone.cpu(0.2), .excellent)
        XCTAssertEqual(PerformanceMetricTone.cpu(0.4), .good)
        XCTAssertEqual(PerformanceMetricTone.cpu(0.6), .moderate)
        XCTAssertEqual(PerformanceMetricTone.cpu(0.8), .elevated)
        XCTAssertEqual(PerformanceMetricTone.cpu(0.95), .critical)
    }

    func testMemoryThresholds() {
        XCTAssertEqual(PerformanceMetricTone.memory(0.5), .excellent)
        XCTAssertEqual(PerformanceMetricTone.memory(0.7), .good)
        XCTAssertEqual(PerformanceMetricTone.memory(0.8), .moderate)
        XCTAssertEqual(PerformanceMetricTone.memory(0.9), .elevated)
        XCTAssertEqual(PerformanceMetricTone.memory(0.98), .critical)
    }

    func testBatteryThresholdsAndCharging() {
        XCTAssertEqual(PerformanceMetricTone.battery(0.9, isCharging: false), .excellent)
        XCTAssertEqual(PerformanceMetricTone.battery(0.5, isCharging: false), .good)
        XCTAssertEqual(PerformanceMetricTone.battery(0.3, isCharging: false), .moderate)
        XCTAssertEqual(PerformanceMetricTone.battery(0.15, isCharging: false), .elevated)
        XCTAssertEqual(PerformanceMetricTone.battery(0.05, isCharging: false), .critical)
        XCTAssertEqual(PerformanceMetricTone.battery(0.05, isCharging: true), .good)
    }

    func testThermalThresholds() {
        XCTAssertEqual(PerformanceMetricTone.thermal(.nominal), .excellent)
        XCTAssertEqual(PerformanceMetricTone.thermal(.fair), .moderate)
        XCTAssertEqual(PerformanceMetricTone.thermal(.serious), .elevated)
        XCTAssertEqual(PerformanceMetricTone.thermal(.critical), .critical)
    }
}
