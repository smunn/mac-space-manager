//
//  CloseSpaceShortcutController.swift
//  SpaceManager
//
//  Registers system-wide shortcuts for closing the current Space and all empty
//  Spaces. Actions wait for their shortcut chord to be released before opening
//  Mission Control so the modifiers cannot affect the Space transition or
//  another application's window commands.
//

import Carbon
import Foundation

@MainActor
final class CloseSpaceShortcutController {
    private static let hotKeySignature: OSType = 0x4353_5043 // "CSPC"
    private static let closeCurrentHotKeyID: UInt32 = 1
    private static let closeEmptyHotKeyID: UInt32 = 2

    private var eventHandler: EventHandlerRef?
    private var closeCurrentHotKey: EventHotKeyRef?
    private var closeEmptyHotKey: EventHotKeyRef?
    private var releaseWaitStartedAt: TimeInterval?
    private let closeCurrentAction: () -> Void
    private let closeEmptyAction: () -> Void

    init(
        closeCurrentAction: @escaping () -> Void,
        closeEmptyAction: @escaping () -> Void
    ) {
        self.closeCurrentAction = closeCurrentAction
        self.closeEmptyAction = closeEmptyAction
        registerHotKeys()
    }

    deinit {
        if let closeCurrentHotKey {
            UnregisterEventHotKey(closeCurrentHotKey)
        }
        if let closeEmptyHotKey {
            UnregisterEventHotKey(closeEmptyHotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func registerHotKeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyReleased))

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            closeSpaceHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler)
        guard handlerStatus == noErr else {
            NSLog("CloseSpaceShortcutController: failed to install event handler (%d)", handlerStatus)
            return
        }

        let closeCurrentStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_W),
            UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: Self.hotKeySignature, id: Self.closeCurrentHotKeyID),
            GetApplicationEventTarget(),
            0,
            &closeCurrentHotKey)

        if closeCurrentStatus != noErr {
            NSLog(
                "CloseSpaceShortcutController: failed to register Control-Option-Command-W (%d)",
                closeCurrentStatus)
        }

        let closeEmptyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: Self.hotKeySignature, id: Self.closeEmptyHotKeyID),
            GetApplicationEventTarget(),
            0,
            &closeEmptyHotKey)

        if closeEmptyStatus != noErr {
            NSLog(
                "CloseSpaceShortcutController: failed to register Control-Option-Command-E (%d)",
                closeEmptyStatus)
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
        case Self.closeCurrentHotKeyID: closeCurrentAction
        case Self.closeEmptyHotKeyID: closeEmptyAction
        default: nil
        }
    }

    private func waitForShortcutModifiersToClear(action: @escaping () -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        let startedAt = releaseWaitStartedAt ?? now
        releaseWaitStartedAt = startedAt

        let flags = CGEventSource.flagsState(.combinedSessionState)
        let shortcutModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        if flags.intersection(shortcutModifiers).isEmpty || now - startedAt >= 1.0 {
            releaseWaitStartedAt = nil
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

private let closeSpaceHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let controller = Unmanaged<CloseSpaceShortcutController>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return MainActor.assumeIsolated {
        controller.handle(event)
    }
}
