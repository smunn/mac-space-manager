//
//  F3SpaceShortcutController.swift
//  SpaceManager
//
//  Tracks both forms of the Mission Control key: the standard F3 key event and
//  the undocumented NX_KEYTYPE_EXPOSE_ALL system-defined media-key event used
//  by Apple keyboards. A session event tap is required so number presses can be
//  consumed before Mission Control or the previously focused app receives them.
//

import Cocoa

final class F3SpaceShortcutController {
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var systemDefinedMonitor: Any?
    private var isF3Held = false
    private var capturedDigitKeyCodes = Set<Int64>()
    private let selectDesktop: (Int) -> Void

    init(selectDesktop: @escaping (Int) -> Void) {
        self.selectDesktop = selectDesktop
        installEventTap()
        installSystemDefinedMonitor()
    }

    deinit {
        removeEventTap()
    }

    private func installEventTap() {
        let eventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: f3SpaceShortcutEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            NSLog("F3SpaceShortcutController: could not install event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        SpaceOperationLog.write("F3 shortcut event tap installed")
    }

    private func installSystemDefinedMonitor() {
        // Quartz event taps do not receive the NX_SYSDEFINED media-key event that
        // Apple keyboards emit for Mission Control. NSEvent's global monitor does,
        // while the event tap above remains responsible for consuming the digit.
        systemDefinedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) {
            [weak self] event in
            guard let isPressed = F3SpaceShortcutRouting.f3MediaKeyIsPressed(
                data1: Int64(event.data1))
            else { return }

            DispatchQueue.main.async {
                self?.setF3Held(isPressed)
            }
        }
    }

    private func removeEventTap() {
        if let systemDefinedMonitor {
            NSEvent.removeMonitor(systemDefinedMonitor)
            self.systemDefinedMonitor = nil
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTapSource = nil
        eventTap = nil
    }

    private func setF3Held(_ isHeld: Bool) {
        isF3Held = isHeld
        SpaceOperationLog.write("F3 shortcut hold=\(isHeld)")
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            isF3Held = false
            capturedDigitKeyCodes.removeAll()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }

        guard type == .keyDown || type == .keyUp else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if keyCode == F3SpaceShortcutRouting.standardF3KeyCode {
            setF3Held(type == .keyDown)
            return false
        }

        if type == .keyUp, capturedDigitKeyCodes.remove(keyCode) != nil {
            return true
        }

        guard type == .keyDown,
              let desktopNumber = F3SpaceShortcutRouting.desktopNumber(forKeyCode: keyCode)
        else { return false }

        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { [selectDesktop] in
                selectDesktop(desktopNumber)
            }
        }
        guard isF3Held else { return false }
        capturedDigitKeyCodes.insert(keyCode)
        return true
    }
}

enum F3SpaceShortcutRouting {
    static let standardF3KeyCode: Int64 = 99
    private static let missionControlMediaKeyCode: Int64 = 2 // NX_KEYTYPE_EXPOSE_ALL

    static func f3MediaKeyIsPressed(data1: Int64) -> Bool? {
        let mediaKeyCode = (data1 & 0xFFFF_0000) >> 16
        guard mediaKeyCode == missionControlMediaKeyCode else { return nil }

        let state = (data1 & 0x0000_FF00) >> 8
        switch state {
        case 0x0A, 0x0C:
            return true
        case 0x0B:
            return false
        default:
            return nil
        }
    }

    static func desktopNumber(forKeyCode keyCode: Int64) -> Int? {
        switch keyCode {
        case 18, 83: return 1
        case 19, 84: return 2
        case 20, 85: return 3
        case 21, 86: return 4
        case 23, 87: return 5
        case 22, 88: return 6
        case 26, 89: return 7
        case 28, 91: return 8
        case 25, 92: return 9
        case 29, 82: return 10
        default: return nil
        }
    }
}

private let f3SpaceShortcutEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<F3SpaceShortcutController>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return controller.handle(type: type, event: event)
        ? nil
        : Unmanaged.passUnretained(event)
}
