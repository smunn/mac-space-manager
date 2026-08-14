//
//  CreateIssueShortcutController.swift
//  SpaceManager
//

import Carbon
import Foundation

@MainActor
final class CreateIssueShortcutController {
    private static let signature: OSType = 0x534D_4953 // "SMIS"
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        register()
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyReleased))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            createIssueHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler)
        guard handlerStatus == noErr else {
            NSLog("CreateIssueShortcutController: handler registration failed (%d)", handlerStatus)
            return
        }

        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_I),
            UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &hotKey)
        if status != noErr {
            NSLog("CreateIssueShortcutController: Control-Option-Command-I registration failed (%d)", status)
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
              hotKeyID.signature == Self.signature
        else { return OSStatus(eventNotHandledErr) }
        action()
        return noErr
    }
}

private let createIssueHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let controller = Unmanaged<CreateIssueShortcutController>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return MainActor.assumeIsolated { controller.handle(event) }
}
