//
//  MacDisplayLayoutGuide.swift
//  Space Manager
//

import SwiftUI

struct MacDisplayLayoutGuide: View {
    let commands: [MagnetShortcutCommand]
    let colors: [String: Color]
    let displayName: String
    let displayAspectRatio: CGFloat
    let isBuiltInDisplay: Bool

    @State private var selectedPageID = ""

    private var pages: [DisplayLayoutPage] {
        var seen = Set<String>()
        return commands.compactMap { command in
            let id = "\(command.group.rawValue)-\(command.section)"
            guard seen.insert(id).inserted else { return nil }
            return DisplayLayoutPage(
                id: id,
                title: pageTitle(group: command.group, section: command.section),
                commands: commands.filter {
                    $0.group == command.group && $0.section == command.section
                })
        }
    }

    private var selectedPage: DisplayLayoutPage? {
        pages.first { $0.id == selectedPageID } ?? pages.first
    }

    var body: some View {
        VStack(spacing: 10) {
            if pages.count > 1 {
                Picker("Layout", selection: $selectedPageID) {
                    ForEach(pages) { page in
                        Text(page.title).tag(page.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            GeometryReader { proxy in
                let maximumAspect = max(0.62, min(2.4, displayAspectRatio))
                let reservedHeight: CGFloat = isBuiltInDisplay ? 24 : 42
                let availableHeight = max(1, proxy.size.height - reservedHeight)
                let screenWidth = min(proxy.size.width * 0.92, availableHeight * maximumAspect)
                let screenHeight = screenWidth / maximumAspect

                VStack(spacing: 0) {
                    displayShell
                        .frame(width: screenWidth, height: screenHeight)

                    if isBuiltInDisplay {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.secondary.opacity(0.3))
                            .frame(width: screenWidth * 1.08, height: 7)
                    } else {
                        displayStand(width: screenWidth)
                    }

                    Text(displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 5)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
        .onAppear { ensurePageSelection() }
        .onChange(of: commands.map(\.id)) { _ in ensurePageSelection() }
        .debugLabel("MacDisplayLayoutGuide")
    }

    private var displayShell: some View {
        GeometryReader { proxy in
            let bezel: CGFloat = isBuiltInDisplay ? 9 : 11

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: isBuiltInDisplay ? 12 : 9)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: isBuiltInDisplay ? 12 : 9)
                            .stroke(.secondary.opacity(0.5), lineWidth: 1)
                    }

                layoutCanvas
                    .padding(bezel)

                if isBuiltInDisplay {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .frame(width: min(76, proxy.size.width * 0.22), height: 9)
                }
            }
        }
    }

    private var layoutCanvas: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))

                if let selectedPage {
                    DisplayRegionCoverageCanvas(
                        commands: selectedPage.commands,
                        colors: colors)

                    ForEach(selectedPage.commands) { command in
                        let color = colors[command.id] ?? .accentColor
                        Rectangle()
                            .fill(.clear)
                            .overlay {
                                Rectangle()
                                    .stroke(color.opacity(0.8), lineWidth: 1.5)
                            }
                        .frame(
                            width: proxy.size.width * command.width,
                            height: proxy.size.height * command.height)
                        .offset(
                            x: proxy.size.width * command.x,
                            y: proxy.size.height * command.y)
                    }

                    ForEach(selectedPage.commands) { command in
                        let color = colors[command.id] ?? .accentColor
                        let labelPosition = labelPosition(for: command)
                        Text(command.shortcutText)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(color.opacity(0.7), lineWidth: 1)
                            }
                            .position(
                                x: proxy.size.width * labelPosition.x,
                                y: proxy.size.height * labelPosition.y +
                                    labelYOffset(for: command, among: selectedPage.commands))
                    }
                }
            }
            .clipped()
        }
    }

    private func displayStand(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.secondary.opacity(0.35))
                .frame(width: 5, height: 24)
            Capsule()
                .fill(.secondary.opacity(0.35))
                .frame(width: min(90, width * 0.3), height: 5)
        }
    }

    private func pageTitle(group: MagnetShortcutGroup, section: String) -> String {
        if group == .basics && section == "Window" { return "Window Basics" }
        return section
    }

    private func labelPosition(for command: MagnetShortcutCommand) -> CGPoint {
        var x = command.x + command.width / 2
        var y = command.y + command.height / 2

        guard command.section == "Two Thirds" else {
            return CGPoint(x: x, y: y)
        }

        switch command.orientation {
        case .horizontal:
            if command.x < 0.01 {
                x = command.x + command.width / 3
            } else if command.x + command.width > 0.99 {
                x = command.x + command.width * 2 / 3
            }
        case .portrait:
            if command.y < 0.01 {
                y = command.y + command.height / 3
            } else if command.y + command.height > 0.99 {
                y = command.y + command.height * 2 / 3
            }
        }
        return CGPoint(x: x, y: y)
    }

    private func labelYOffset(
        for command: MagnetShortcutCommand,
        among commands: [MagnetShortcutCommand]
    ) -> CGFloat {
        let matches = commands.filter { sameFrame($0, command) }
        guard matches.count > 1,
              let index = matches.firstIndex(where: { $0.id == command.id })
        else { return 0 }
        return (CGFloat(index) - CGFloat(matches.count - 1) / 2) * 25
    }

    private func sameFrame(
        _ first: MagnetShortcutCommand,
        _ second: MagnetShortcutCommand
    ) -> Bool {
        first.x == second.x && first.y == second.y &&
        first.width == second.width && first.height == second.height
    }

    private func ensurePageSelection() {
        if !pages.contains(where: { $0.id == selectedPageID }) {
            selectedPageID = pages.first?.id ?? ""
        }
    }
}

private struct DisplayRegionCoverageCanvas: View {
    let commands: [MagnetShortcutCommand]
    let colors: [String: Color]

    var body: some View {
        Canvas { context, size in
            let xBoundaries = boundaries(for: commands, origin: \.x, length: \.width)
            let yBoundaries = boundaries(for: commands, origin: \.y, length: \.height)

            for xIndex in 0..<(xBoundaries.count - 1) {
                for yIndex in 0..<(yBoundaries.count - 1) {
                    let normalizedRect = CGRect(
                        x: xBoundaries[xIndex],
                        y: yBoundaries[yIndex],
                        width: xBoundaries[xIndex + 1] - xBoundaries[xIndex],
                        height: yBoundaries[yIndex + 1] - yBoundaries[yIndex])
                    let center = CGPoint(x: normalizedRect.midX, y: normalizedRect.midY)
                    let coveringCommands = commands.filter { contains(center, command: $0) }
                    guard !coveringCommands.isEmpty else { continue }

                    let rect = CGRect(
                        x: normalizedRect.minX * size.width,
                        y: normalizedRect.minY * size.height,
                        width: normalizedRect.width * size.width,
                        height: normalizedRect.height * size.height)
                    if coveringCommands.count == 1 {
                        let color = colors[coveringCommands[0].id] ?? .accentColor
                        context.fill(
                            Path(rect),
                            with: .color(color.opacity(0.2)))
                    } else {
                        drawSharedStripes(
                            in: rect,
                            commands: coveringCommands,
                            context: &context)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .debugLabel("DisplayRegionCoverageCanvas")
    }

    private func boundaries(
        for commands: [MagnetShortcutCommand],
        origin: KeyPath<MagnetShortcutCommand, Double>,
        length: KeyPath<MagnetShortcutCommand, Double>
    ) -> [CGFloat] {
        let values = commands.flatMap { command -> [CGFloat] in
            let start = CGFloat(command[keyPath: origin])
            return [start, start + CGFloat(command[keyPath: length])]
        } + [0, 1]
        return Array(Set(values.map { min(1, max(0, $0)) })).sorted()
    }

    private func contains(
        _ point: CGPoint,
        command: MagnetShortcutCommand
    ) -> Bool {
        point.x >= command.x && point.x < command.x + command.width &&
        point.y >= command.y && point.y < command.y + command.height
    }

    private func drawSharedStripes(
        in rect: CGRect,
        commands: [MagnetShortcutCommand],
        context: inout GraphicsContext
    ) {
        let stripeWidth: CGFloat = 9
        let firstOffset = rect.minX - rect.height - stripeWidth
        let lastOffset = rect.maxX + stripeWidth
        var stripeIndex = 0

        for offset in stride(
            from: firstOffset,
            through: lastOffset,
            by: stripeWidth
        ) {
            let command = commands[stripeIndex % commands.count]
            let color = colors[command.id] ?? .accentColor
            var stripe = Path()
            stripe.move(to: CGPoint(x: offset, y: rect.maxY))
            stripe.addLine(to: CGPoint(x: offset + stripeWidth, y: rect.maxY))
            stripe.addLine(to: CGPoint(
                x: offset + stripeWidth + rect.height,
                y: rect.minY))
            stripe.addLine(to: CGPoint(x: offset + rect.height, y: rect.minY))
            stripe.closeSubpath()

            var clippedContext = context
            clippedContext.clip(to: Path(rect))
            clippedContext.fill(
                stripe,
                with: .color(color.opacity(0.38)))
            stripeIndex += 1
        }
    }
}

private struct DisplayLayoutPage: Identifiable {
    let id: String
    let title: String
    let commands: [MagnetShortcutCommand]
}
