//
//  SystemPerformanceMonitor.swift
//  SpaceManager
//
//  Collects short-lived system performance samples only while the status menu
//  is open. CPU and throughput values are deltas between consecutive samples;
//  no background polling continues after the menu closes.
//

import Darwin
import Foundation
import IOKit
import IOKit.ps

struct SystemPerformanceSnapshot: Sendable {
    let cpuUsage: Double?
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    let networkDownloadRate: Double?
    let networkUploadRate: Double?
    let diskReadRate: Double?
    let diskWriteRate: Double?
    let thermalState: ProcessInfo.ThermalState
    let batteryPercent: Int?
    let batteryIsCharging: Bool
    let batteryTemperatureCelsius: Double?
}

final class SystemPerformanceMonitor: @unchecked Sendable {
    private struct Counters {
        let date: Date
        let cpuTicks: [UInt64]
        let networkReceived: UInt64
        let networkSent: UInt64
        let diskRead: UInt64
        let diskWritten: UInt64
    }

    private let queue = DispatchQueue(label: "com.smunn.SpaceManager.performance", qos: .utility)
    private var previousCounters: Counters?
    private var generation = 0

    func start(completion: @escaping @Sendable (SystemPerformanceSnapshot) -> Void) {
        queue.async {
            self.generation += 1
            self.previousCounters = nil
            let generation = self.generation
            self.collect(generation: generation, completion: completion)
        }
    }

    func sample(completion: @escaping @Sendable (SystemPerformanceSnapshot) -> Void) {
        queue.async {
            self.collect(generation: self.generation, completion: completion)
        }
    }

    func stop() {
        queue.async {
            self.generation += 1
            self.previousCounters = nil
        }
    }

    private func collect(
        generation expectedGeneration: Int,
        completion: @escaping @Sendable (SystemPerformanceSnapshot) -> Void
    ) {
        guard expectedGeneration == generation else { return }

        let network = Self.networkCounters()
        let disk = Self.diskCounters()
        let counters = Counters(
            date: Date(),
            cpuTicks: Self.cpuTicks(),
            networkReceived: network.received,
            networkSent: network.sent,
            diskRead: disk.read,
            diskWritten: disk.written)
        let previous = previousCounters
        previousCounters = counters

        let memory = Self.memoryUsage()
        let battery = Self.batteryStatus()
        let interval = previous.map { counters.date.timeIntervalSince($0.date) }

        let snapshot = SystemPerformanceSnapshot(
            cpuUsage: previous.flatMap { Self.cpuUsage(from: $0.cpuTicks, to: counters.cpuTicks) },
            memoryUsed: memory.used,
            memoryTotal: memory.total,
            networkDownloadRate: Self.rate(
                current: counters.networkReceived,
                previous: previous?.networkReceived,
                interval: interval),
            networkUploadRate: Self.rate(
                current: counters.networkSent,
                previous: previous?.networkSent,
                interval: interval),
            diskReadRate: Self.rate(
                current: counters.diskRead,
                previous: previous?.diskRead,
                interval: interval),
            diskWriteRate: Self.rate(
                current: counters.diskWritten,
                previous: previous?.diskWritten,
                interval: interval),
            thermalState: ProcessInfo.processInfo.thermalState,
            batteryPercent: battery.percent,
            batteryIsCharging: battery.isCharging,
            batteryTemperatureCelsius: Self.batteryTemperature())

        guard expectedGeneration == generation else { return }
        completion(snapshot)
    }

    private static func cpuTicks() -> [UInt64] {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return [] }

        return withUnsafePointer(to: info.cpu_ticks) { pointer in
            pointer.withMemoryRebound(to: UInt32.self, capacity: Int(CPU_STATE_MAX)) {
                let ticks = $0
                return (0..<Int(CPU_STATE_MAX)).map { index in UInt64(ticks[index]) }
            }
        }
    }

    private static func cpuUsage(from previous: [UInt64], to current: [UInt64]) -> Double? {
        guard previous.count == Int(CPU_STATE_MAX), current.count == Int(CPU_STATE_MAX) else { return nil }
        let deltas = zip(current, previous).map { current, previous in
            current >= previous ? current - previous : 0
        }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return nil }
        let idle = deltas[Int(CPU_STATE_IDLE)]
        return Double(total - idle) / Double(total)
    }

    private static func memoryUsage() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return (0, total) }
        let pageSize = UInt64(vm_kernel_page_size)
        let availablePages = UInt64(stats.free_count) + UInt64(stats.speculative_count)
        let available = min(total, availablePages * pageSize)
        return (total - available, total)
    }

    private static func networkCounters() -> (received: UInt64, sent: UInt64) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let address = current {
            let flags = Int32(address.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let family = address.pointee.ifa_addr?.pointee.sa_family
            let name = String(cString: address.pointee.ifa_name)
            // Count physical Ethernet-style interfaces only. VPN and peer
            // interfaces report the same bytes again and would inflate totals.
            if isUp,
               !isLoopback,
               family == UInt8(AF_LINK),
               name.hasPrefix("en"),
               let data = address.pointee.ifa_data
            {
                let interfaceData = data.assumingMemoryBound(to: if_data.self).pointee
                received += UInt64(interfaceData.ifi_ibytes)
                sent += UInt64(interfaceData.ifi_obytes)
            }
            current = address.pointee.ifa_next
        }
        return (received, sent)
    }

    private static func diskCounters() -> (read: UInt64, written: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator) == KERN_SUCCESS
        else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var written: UInt64 = 0
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let properties = IORegistryEntryCreateCFProperty(
                service,
                "Statistics" as CFString,
                kCFAllocatorDefault,
                0)?.takeRetainedValue() as? [String: Any]
            else { continue }
            read += (properties["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written += (properties["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, written)
    }

    private static func batteryStatus() -> (percent: Int?, isCharging: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, false) }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }
            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
            let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
            let percent = current.flatMap { value in
                maximum.flatMap { $0 > 0 ? Int((value / $0 * 100).rounded()) : nil }
            }
            return (percent, (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false)
        }
        return (nil, false)
    }

    private static func batteryTemperature() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "Temperature" as CFString,
            kCFAllocatorDefault,
            0)?.takeRetainedValue() as? NSNumber
        else { return nil }
        let rawValue = value.doubleValue
        return rawValue > 1_000 ? rawValue / 100 : rawValue / 10
    }

    private static func rate(current: UInt64, previous: UInt64?, interval: TimeInterval?) -> Double? {
        guard let previous, let interval, interval > 0, current >= previous else { return nil }
        return Double(current - previous) / interval
    }
}
