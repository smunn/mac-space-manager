//
//  TerminalSpaceShortcutController.swift
//  SpaceManager
//
//  Registers Control-Option-Command-T as a system-wide shortcut for creating
//  a Terminal Space. Carbon hot keys work while the menu bar app is inactive
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
    private static let hotKeyID: UInt32 = 1

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var releaseWaitStartedAt: TimeInterval?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        registerHotKey()
    }

    deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
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
            EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID),
            GetApplicationEventTarget(),
            0,
            &hotKey)

        if registrationStatus != noErr {
            NSLog(
                "TerminalSpaceShortcutController: failed to register Control-Option-Command-T (%d)",
                registrationStatus)
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
              hotKeyID.id == Self.hotKeyID
        else { return OSStatus(eventNotHandledErr) }

        waitForShortcutModifiersToClear()
        return noErr
    }

    private func waitForShortcutModifiersToClear() {
        let now = ProcessInfo.processInfo.systemUptime
        let startedAt = releaseWaitStartedAt ?? now
        releaseWaitStartedAt = startedAt

        let flags = CGEventSource.flagsState(.combinedSessionState)
        let shortcutModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        if flags.intersection(shortcutModifiers).isEmpty || now - startedAt >= 1.0 {
            releaseWaitStartedAt = nil
            // Allow WindowManager one additional run-loop turn after the physical
            // key-up events before opening Mission Control.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.action()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            self?.waitForShortcutModifiersToClear()
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
