//
//  SpaceSwitcher.swift
//  SpaceManager
//
//  Switches between macOS Spaces via direct keyboard events or Mission Control AX.
//  Uses arrow-key chaining when direct Desktop N shortcuts are unavailable.
//  Adapted from Spaceman by René Uittenbogaard (MIT License).
//

import Cocoa
import Foundation

class SpaceSwitcher {
    private let shortcutHelper = ShortcutHelper()
    private var chainObserver: NSObjectProtocol?
    private var chainTimeout: DispatchWorkItem?

    init() {
        AXIsProcessTrusted()
    }

    func reloadShortcuts() {
        shortcutHelper.reload()
    }

    /// Switches to a space by clicking the Nth desktop button inside the
    /// target display's Mission Control group.
    /// Constant time regardless of distance -- no stepping through intermediate spaces.
    func switchViaMissionControl(
        displayID: String,
        displayGroupIndex: Int = 1,
        desktopIndex: Int,
        onError: (() -> Void)? = nil
    ) {
        MissionControlAccessibility.operationQueue.async {
            guard let snapshots = MissionControlAccessibility.openAndWaitForDisplaySnapshots(),
                  let snapshot = MissionControlAccessibility.snapshot(
                    in: snapshots,
                    displayID: displayID,
                    fallbackDisplayGroupIndex: displayGroupIndex)
            else {
                NSLog("SpaceSwitcher: Mission Control display group \(displayGroupIndex) did not appear")
                SpaceOperationLog.write("Switch failed: display group \(displayGroupIndex) unavailable")
                DispatchQueue.main.async { onError?() }
                return
            }

            let buttons = snapshot.desktopButtons
            guard buttons.indices.contains(desktopIndex - 1),
                  MissionControlAccessibility.performPress(on: buttons[desktopIndex - 1])
            else {
                NSLog("SpaceSwitcher: could not press desktop \(desktopIndex) in display group \(displayGroupIndex)")
                SpaceOperationLog.write(
                    "Switch failed: AXPress display=\(displayGroupIndex) desktop=\(desktopIndex)")
                MissionControlAccessibility.dismiss()
                DispatchQueue.main.async { onError?() }
                return
            }
            SpaceOperationLog.write(
                "Switch completed via Mission Control display=\(displayGroupIndex) desktop=\(desktopIndex)")
        }
    }

    func canDirectSwitch(spaceNumber: Int) -> Bool {
        shortcutHelper.getKeyCode(spaceNumber: spaceNumber) >= 0
    }

    func switchToSpace(spaceNumber: Int, onError: (() -> Void)? = nil) {
        guard let shortcut = shortcutHelper.shortcut(forDesktop: spaceNumber) else {
            onError?()
            return
        }
        cancelChain()
        performKeyboardSwitch(shortcut: shortcut) { success in
            if !success { onError?() }
        }
    }

    func navigateToSpace(from currentNumber: Int, to targetNumber: Int, onError: (() -> Void)? = nil) {
        cancelChain()
        let delta = targetNumber - currentNumber
        guard delta != 0 else { return }
        let goRight = delta > 0
        executeChain(stepsRemaining: abs(delta), goRight: goRight, onError: onError)
    }

    private func executeChain(stepsRemaining: Int, goRight: Bool, onError: (() -> Void)? = nil) {
        guard stepsRemaining > 0 else { return }
        let shortcut = goRight
            ? shortcutHelper.moveRightShortcut ?? fallbackArrowShortcut(keyCode: 124)
            : shortcutHelper.moveLeftShortcut ?? fallbackArrowShortcut(keyCode: 123)

        performKeyboardSwitch(shortcut: shortcut) { [weak self] success in
            guard let self else { return }
            guard success else {
                onError?()
                return
            }
            self.executeChain(
                stepsRemaining: stepsRemaining - 1,
                goRight: goRight,
                onError: onError)
        }
    }

    /// Installs the active-Space observer before posting the key event so fast
    /// transitions cannot race past the observer. Completion is based on the actual
    /// workspace notification rather than successful event construction alone.
    private func performKeyboardSwitch(
        shortcut: SpaceShortcut,
        completion: @escaping (Bool) -> Void
    ) {
        cancelChain()

        let timeout = DispatchWorkItem { [weak self] in
            self?.chainTimeout = nil
            self?.removeChainObserver()
            completion(false)
        }
        chainTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)

        chainObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            timeout.cancel()
            self?.chainTimeout = nil
            self?.removeChainObserver()
            completion(true)
        }

        // Menu actions invoke this before NSMenu finishes closing. Posting immediately
        // lets the menu consume the shortcut, so wait for the next run-loop turn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, !timeout.isCancelled else { return }
            let posted = MissionControlAccessibility.postKey(
                keyCode: CGKeyCode(shortcut.keyCode),
                flags: Self.cgEventFlags(from: shortcut.modifierFlags))
            if !posted {
                timeout.cancel()
                self.chainTimeout = nil
                self.removeChainObserver()
                completion(false)
            }
        }
    }

    func cancelChain() {
        chainTimeout?.cancel()
        chainTimeout = nil
        removeChainObserver()
    }

    private func removeChainObserver() {
        if let observer = chainObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            chainObserver = nil
        }
    }

    private func fallbackArrowShortcut(keyCode: Int) -> SpaceShortcut {
        SpaceShortcut(
            keyCode: keyCode,
            modifierFlags: .control,
            keyEquivalent: "")
    }

    private static func cgEventFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var cgFlags: CGEventFlags = []
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        return cgFlags
    }
}
