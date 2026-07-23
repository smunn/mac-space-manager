//
//  KeyboardInputDeviceMonitor.swift
//  Space Manager
//
//  CGEvent and Carbon hot-key callbacks omit the originating physical device.
//  This narrowly scoped IOHID listener records only Slash key-down events so
//  the Window Layout Cheatsheet can render the keyboard that opened it.
//

import IOKit.hid

final class KeyboardInputDeviceMonitor {
    var onSlashStyle: ((MacKeyboardStyle) -> Void)?

    private let manager = IOHIDManagerCreate(
        kCFAllocatorDefault,
        IOOptionBits(kIOHIDOptionsTypeNone))
    private let lock = NSLock()
    private var latestSlash: (style: MacKeyboardStyle, timestamp: TimeInterval)?
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        // macOS protects direct access to the built-in keyboard on current
        // systems. We only need to observe extended Apple keyboards: when an
        // external Slash is seen the cheatsheet uses the numeric layout;
        // otherwise the existing CGEvent trigger is treated as built-in.
        let appleVendors = [0x004C, 0x05AC]
        let extendedProductIDs = [0x026C, 0x026D, 0x026E]
        var matching: [[String: Any]] = []
        for vendor in appleVendors {
            for productID in extendedProductIDs {
                matching.append([
                    kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                    kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
                    kIOHIDVendorIDKey: vendor,
                    kIOHIDProductIDKey: productID
                ])
            }
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        IOHIDManagerRegisterInputValueCallback(
            manager,
            keyboardInputValueCallback,
            Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let deviceCount = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.count ?? 0
        SpaceOperationLog.write("Keyboard monitor start devices=\(deviceCount) openResult=\(openResult)")
        guard openResult == kIOReturnSuccess else {
            NSLog("KeyboardInputDeviceMonitor: IOHIDManagerOpen failed (\(openResult))")
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue)
            return
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        isRunning = false
        lock.withLock { latestSlash = nil }
    }

    func recentSlashStyle(maxAge: TimeInterval = 0.25) -> MacKeyboardStyle? {
        lock.withLock {
            guard let latestSlash,
                  ProcessInfo.processInfo.systemUptime - latestSlash.timestamp <= maxAge
            else { return nil }
            return latestSlash.style
        }
    }

    fileprivate func recordSlash(from device: IOHIDDevice) {
        guard let style = KeyboardHardwareDetector.style(for: device) else { return }
        lock.withLock {
            latestSlash = (style, ProcessInfo.processInfo.systemUptime)
        }
        NSLog("KeyboardInputDeviceMonitor: Slash detected from \(style.rawValue) keyboard")
        SpaceOperationLog.write("Keyboard monitor Slash style=\(style.rawValue)")
        onSlashStyle?(style)
    }
}

private let keyboardInputValueCallback: IOHIDValueCallback = { context, result, _, value in
    guard result == kIOReturnSuccess,
          let context
    else { return }

    let element = IOHIDValueGetElement(value)
    let usage = IOHIDElementGetUsage(element)
    let integerValue = IOHIDValueGetIntegerValue(value)
    // Keyboard reports can expose keys either as individual button elements,
    // where the element usage is Slash and the value is 1, or as an array,
    // where the value itself is the pressed key's usage.
    let isSlashDown = IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad
        && ((usage == 0x38 && integerValue != 0) || integerValue == 0x38)
    guard isSlashDown else { return }
    let device = IOHIDElementGetDevice(element)

    Unmanaged<KeyboardInputDeviceMonitor>
        .fromOpaque(context)
        .takeUnretainedValue()
        .recordSlash(from: device)
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
