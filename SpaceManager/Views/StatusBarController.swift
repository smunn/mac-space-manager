//
//  StatusBarController.swift
//  SpaceManager
//
//  Menu bar dropdown showing all spaces with their detected contents.
//

import Cocoa
import SwiftUI

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private let spaceSwitcher = SpaceSwitcher()

    private var currentSpaces: [Space] = []

    override init() {
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu = NSMenu()
        statusMenu.delegate = self

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Spaces")
            button.image?.size = NSSize(width: 16, height: 16)
        }

        statusItem.menu = statusMenu
    }

    func updateSpaces(_ spaces: [Space]) {
        currentSpaces = spaces
        spaceSwitcher.reloadShortcuts()
        updateMenuBarTitle(spaces)
        rebuildMenu(spaces)
    }

    private func updateMenuBarTitle(_ spaces: [Space]) {
        guard let current = spaces.first(where: { $0.isCurrentSpace }) else { return }
        if let button = statusItem.button {
            let title = truncate(current.spaceName, maxLength: 20)
            button.title = " \(title)"
            button.imagePosition = .imageLeading
        }
    }

    private func rebuildMenu(_ spaces: [Space]) {
        statusMenu.removeAllItems()

        let switchMap = Space.buildSwitchIndexMap(for: spaces)
        var currentDisplayID: String?

        for space in spaces {
            if space.displayID != currentDisplayID {
                if currentDisplayID != nil {
                    statusMenu.addItem(NSMenuItem.separator())
                }
                currentDisplayID = space.displayID
            }

            let item = makeSpaceMenuItem(space: space, switchMap: switchMap)
            statusMenu.addItem(item)
        }

        statusMenu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshSpaces), keyEquivalent: "r")
        refreshItem.target = self
        statusMenu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit Space Manager", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    private func makeSpaceMenuItem(space: Space, switchMap: [String: Int]) -> NSMenuItem {
        let prefix = space.isFullScreen ? "F" : "\(space.spaceByDesktopID)"
        let title = "\(prefix).  \(space.spaceName)"

        let item = NSMenuItem(title: title, action: #selector(switchToSpace(_:)), keyEquivalent: "")
        item.target = self
        item.tag = space.spaceNumber

        if space.isCurrentSpace {
            item.state = .on
        }

        if !space.windows.isEmpty {
            let appNames = uniqueAppNames(space.windows)
            let subtitle = appNames.joined(separator: ", ")
            item.toolTip = subtitle

            let attrTitle = NSMutableAttributedString()

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuFont(ofSize: 14),
                .foregroundColor: space.isCurrentSpace ? NSColor.controlAccentColor : NSColor.labelColor
            ]
            attrTitle.append(NSAttributedString(string: "\(prefix).  \(space.spaceName)", attributes: titleAttrs))

            if !appNames.isEmpty {
                let subtitleAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.menuFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                attrTitle.append(NSAttributedString(string: "\n     \(subtitle)", attributes: subtitleAttrs))
            }

            item.attributedTitle = attrTitle
        }

        if let switchIndex = switchMap[space.spaceID], switchIndex > 0 {
            item.representedObject = switchIndex
        }

        return item
    }

    @objc private func switchToSpace(_ sender: NSMenuItem) {
        if let switchIndex = sender.representedObject as? Int {
            spaceSwitcher.switchToSpace(spaceNumber: switchIndex)
        }
    }

    @objc private func refreshSpaces() {
        NotificationCenter.default.post(name: NSNotification.Name("RequestSpaceRefresh"), object: nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func uniqueAppNames(_ windows: [SpaceWindow]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for window in windows {
            if seen.insert(window.ownerName).inserted {
                result.append(window.ownerName)
            }
        }
        return result
    }

    private func truncate(_ string: String, maxLength: Int) -> String {
        if string.count <= maxLength { return string }
        return String(string.prefix(maxLength - 1)) + "..."
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        NotificationCenter.default.post(name: NSNotification.Name("RequestSpaceRefresh"), object: nil)
    }
}
