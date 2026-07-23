//
//  KeyboardInputDeviceMonitor.swift
//  Space Manager
//
//  CGEvent and Carbon hot-key callbacks omit the originating physical device.
//  This narrowly scoped monitor observes Slash on extended Apple keyboards.
//  A cheatsheet trigger without that external match is treated as built-in.
//

import CoreHID
import IOKit.hid

final class KeyboardInputDeviceMonitor {
    var onSlashStyle: ((MacKeyboardStyle) -> Void)?

    private let legacyManager = IOHIDManagerCreate(
        kCFAllocatorDefault,
        IOOptionBits(kIOHIDOptionsTypeNone))
    private let lock = NSLock()
    private var latestSlash: (style: MacKeyboardStyle, timestamp: TimeInterval)?
    private var coreHIDTask: Task<Void, Never>?
    private var coreHIDDeviceTasks: [UInt64: Task<Void, Never>] = [:]
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if #available(macOS 15, *) {
            SpaceOperationLog.write("Keyboard monitor starting with CoreHID")
            coreHIDTask = Task { [weak self] in
                await self?.monitorCoreHIDDevices()
            }
        } else {
            startLegacyMonitor()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        coreHIDTask?.cancel()
        coreHIDTask = nil
        let tasks = lock.withLock {
            let tasks = Array(coreHIDDeviceTasks.values)
            coreHIDDeviceTasks.removeAll()
            latestSlash = nil
            return tasks
        }
        tasks.forEach { $0.cancel() }

        if #unavailable(macOS 15) {
            IOHIDManagerRegisterInputValueCallback(legacyManager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(
                legacyManager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(legacyManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    func recentSlashStyle(maxAge: TimeInterval = 0.25) -> MacKeyboardStyle? {
        let detectedStyle: MacKeyboardStyle? = lock.withLock {
            guard let latestSlash,
                  ProcessInfo.processInfo.systemUptime - latestSlash.timestamp <= maxAge
            else { return nil }
            return latestSlash.style
        }
        return detectedStyle ?? KarabinerKeyboardSource.currentStyle(maxAge: maxAge)
    }

    private func recordSlash(style: MacKeyboardStyle) {
        lock.withLock {
            latestSlash = (style, ProcessInfo.processInfo.systemUptime)
        }
        SpaceOperationLog.write("Keyboard monitor Slash style=\(style.rawValue)")
        onSlashStyle?(style)
    }

    @available(macOS 15, *)
    private func monitorCoreHIDDevices() async {
        let manager = HIDDeviceManager()
        let criteria = Self.extendedAppleKeyboardIDs.map { vendorID, productID in
            HIDDeviceManager.DeviceMatchingCriteria(
                primaryUsage: .genericDesktop(.keyboard),
                vendorID: vendorID,
                productID: productID)
        }

        do {
            for try await notification in await manager.monitorNotifications(
                matchingCriteria: criteria)
            {
                guard !Task.isCancelled else { return }
                switch notification {
                case .deviceMatched(let reference):
                    let task = Task { [weak self] in
                        guard let self else { return }
                        await self.monitorCoreHIDDevice(reference)
                    }
                    lock.withLock {
                        coreHIDDeviceTasks[reference.deviceID]?.cancel()
                        coreHIDDeviceTasks[reference.deviceID] = task
                    }
                case .deviceRemoved(let reference):
                    lock.withLock {
                        coreHIDDeviceTasks.removeValue(forKey: reference.deviceID)?.cancel()
                    }
                @unknown default:
                    break
                }
            }
        } catch where error is CancellationError {
            return
        } catch {
            SpaceOperationLog.write("CoreHID keyboard monitor failed: \(error)")
        }
    }

    @available(macOS 15, *)
    private func monitorCoreHIDDevice(
        _ reference: HIDDeviceClient.DeviceReference
    ) async {
        guard let client = HIDDeviceClient(deviceReference: reference) else {
            SpaceOperationLog.write("CoreHID could not open keyboard device \(reference.deviceID)")
            return
        }
        let slashUsage = HIDUsage.keyboardOrKeypad(.keyboardForwardSlashAndQuestionMark)
        let slashElements = await client.elements.filter { $0.usage == slashUsage }
        SpaceOperationLog.write(
            "CoreHID monitoring keyboard device=\(reference.deviceID) slashElements=\(slashElements.count)")

        do {
            for try await notification in await client.monitorNotifications(
                reportIDsToMonitor: [HIDReportID.allReports],
                elementsToMonitor: slashElements)
            {
                guard !Task.isCancelled else { return }
                switch notification {
                case .inputReport(_, let data, _):
                    if data.contains(0x38) {
                        recordSlash(style: .numericKeypad)
                    }
                case .elementUpdates(let values) where values.contains(where: {
                    $0.integerValue(asTypeTruncatingIfNeeded: Int.self) != 0
                }):
                    recordSlash(style: .numericKeypad)
                case .deviceSeized:
                    SpaceOperationLog.write(
                        "CoreHID keyboard device \(reference.deviceID) seized by another client")
                case .deviceUnseized:
                    SpaceOperationLog.write(
                        "CoreHID keyboard device \(reference.deviceID) unseized")
                case .deviceRemoved:
                    return
                default:
                    break
                }
            }
        } catch where error is CancellationError {
            return
        } catch {
            SpaceOperationLog.write(
                "CoreHID keyboard device \(reference.deviceID) failed: \(error)")
        }
    }

    private func startLegacyMonitor() {
        let matching = Self.extendedAppleKeyboardIDs.map { vendorID, productID in
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
                kIOHIDVendorIDKey: vendorID,
                kIOHIDProductIDKey: productID
            ] as [String: Any]
        }
        IOHIDManagerSetDeviceMatchingMultiple(legacyManager, matching as CFArray)
        IOHIDManagerRegisterInputValueCallback(
            legacyManager,
            legacyKeyboardInputValueCallback,
            Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(
            legacyManager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(
            legacyManager,
            IOOptionBits(kIOHIDOptionsTypeNone))
        SpaceOperationLog.write("Legacy keyboard monitor openResult=\(result)")
    }

    fileprivate func recordLegacySlash(from device: IOHIDDevice) {
        guard let style = KeyboardHardwareDetector.style(for: device) else { return }
        recordSlash(style: style)
    }

    private static let extendedAppleKeyboardIDs: [(UInt32, UInt32)] = {
        let vendors: [UInt32] = [0x004C, 0x05AC]
        let products: [UInt32] = [0x026C, 0x026D, 0x026E]
        return vendors.flatMap { vendor in products.map { (vendor, $0) } }
    }()
}

enum KarabinerKeyboardSource {
    // This path must exactly match the non-sandboxed Karabiner shell action.
    // NSTemporaryDirectory() points into /var/folders for the app and would
    // not read the marker Karabiner writes in /tmp.
    static let sourceURL = URL(
        fileURLWithPath: "/tmp/com.smunn.SpaceManager.keyboard-source")

    static func currentStyle(
        sourceURL: URL = sourceURL,
        maxAge: TimeInterval = 0.25,
        now: Date = Date()
    ) -> MacKeyboardStyle? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            guard let modificationDate = attributes[.modificationDate] as? Date,
                  now.timeIntervalSince(modificationDate) <= maxAge
            else { return nil }
            let value = try String(contentsOf: sourceURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MacKeyboardStyle(rawValue: value)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            SpaceOperationLog.write("Karabiner keyboard source read failed: \(error)")
            return nil
        }
    }
}

private let legacyKeyboardInputValueCallback: IOHIDValueCallback = {
    context,
    result,
    _,
    value in
    guard result == kIOReturnSuccess, let context else { return }

    let element = IOHIDValueGetElement(value)
    let usage = IOHIDElementGetUsage(element)
    let integerValue = IOHIDValueGetIntegerValue(value)
    let isSlashDown = IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad
        && ((usage == 0x38 && integerValue != 0) || integerValue == 0x38)
    guard isSlashDown else { return }

    Unmanaged<KeyboardInputDeviceMonitor>
        .fromOpaque(context)
        .takeUnretainedValue()
        .recordLegacySlash(from: IOHIDElementGetDevice(element))
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
