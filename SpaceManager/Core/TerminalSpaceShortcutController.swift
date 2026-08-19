//
//  TerminalSpaceShortcutController.swift
//  SpaceManager
//
//  Registers system-wide shortcuts for creating one Terminal Space or Spaces
//  for all Terminal windows. Carbon hot keys work while the menu bar app is inactive
//  and do not require a persistent keyboard event tap. The Mission Control
//  operation is deliberately deferred until the entire shortcut chord has been
//  released: opening Mission Control while its modifier keys are still down can
//  leave WindowManager's Space transition visually composited over the old Space.
//

import Carbon
import Foundation

@MainActor
final class TerminalSpaceShortcutController {
    private static let hotKeySignature: OSType = 0x5453_5043 // "TSPC"
    private static let terminalSpaceHotKeyID: UInt32 = 1
    private static let terminalWindowsHotKeyID: UInt32 = 2

    private var eventHandler: EventHandlerRef?
    private var terminalSpaceHotKey: EventHotKeyRef?
    private var terminalWindowsHotKey: EventHotKeyRef?
    private var releaseWaitStartedAt: TimeInterval?
    private let terminalSpaceAction: () -> Void
    private let terminalWindowsAction: () -> Void

    init(terminalSpaceAction: @escaping () -> Void, terminalWindowsAction: @escaping () -> Void) {
        self.terminalSpaceAction = terminalSpaceAction
        self.terminalWindowsAction = terminalWindowsAction
        registerHotKey()
    }

    deinit {
        if let terminalSpaceHotKey {
            UnregisterEventHotKey(terminalSpaceHotKey)
        }
        if let terminalWindowsHotKey {
            UnregisterEventHotKey(terminalWindowsHotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyReleased))

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            terminalSpaceHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler)
        guard handlerStatus == noErr else {
            NSLog("TerminalSpaceShortcutController: failed to install event handler (%d)", handlerStatus)
            return
        }

        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: Self.hotKeySignature, id: Self.terminalSpaceHotKeyID),
            GetApplicationEventTarget(),
            0,
            &terminalSpaceHotKey)

        if registrationStatus != noErr {
            NSLog(
                "TerminalSpaceShortcutController: failed to register Control-Option-Command-T (%d)",
                registrationStatus)
        }

        let terminalWindowsStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            UInt32(controlKey | optionKey | shiftKey | cmdKey),
            EventHotKeyID(signature: Self.hotKeySignature, id: Self.terminalWindowsHotKeyID),
            GetApplicationEventTarget(),
            0,
            &terminalWindowsHotKey)

        if terminalWindowsStatus != noErr {
            NSLog(
                "TerminalSpaceShortcutController: failed to register Control-Option-Shift-Command-A (%d)",
                terminalWindowsStatus)
        }
    }

    fileprivate func handle(_ event: EventRef?) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        guard let event,
              GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID) == noErr,
              hotKeyID.signature == Self.hotKeySignature,
              let action = action(for: hotKeyID.id)
        else { return OSStatus(eventNotHandledErr) }

        waitForShortcutModifiersToClear(action: action)
        return noErr
    }

    private func action(for hotKeyID: UInt32) -> (() -> Void)? {
        switch hotKeyID {
        case Self.terminalSpaceHotKeyID: terminalSpaceAction
        case Self.terminalWindowsHotKeyID: terminalWindowsAction
        default: nil
        }
    }

    private func waitForShortcutModifiersToClear(action: @escaping () -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        let startedAt = releaseWaitStartedAt ?? now
        releaseWaitStartedAt = startedAt

        let flags = CGEventSource.flagsState(.combinedSessionState)
        let shortcutModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        if flags.intersection(shortcutModifiers).isEmpty || now - startedAt >= 1.0 {
            releaseWaitStartedAt = nil
            // Allow WindowManager one additional run-loop turn after the physical
            // key-up events before opening Mission Control.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                action()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            self?.waitForShortcutModifiersToClear(action: action)
        }
    }
}

private let terminalSpaceHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let controller = Unmanaged<TerminalSpaceShortcutController>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return MainActor.assumeIsolated {
        controller.handle(event)
    }
}
