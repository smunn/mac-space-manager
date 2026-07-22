//
//  MagnetShortcutModels.swift
//  SpaceManager
//
//  Editable representations of Magnet's private command schema. Magnet does not
//  publish this format, so each command retains its complete JSON object and only
//  projects the fields Space Manager understands. Unknown fields survive edits.
//

import Foundation

enum MagnetOrientation: String, Codable, CaseIterable, Sendable {
    case vertical
    case horizontal
}

enum MagnetJSONValue: Codable, Equatable, Sendable {
    case object([String: MagnetJSONValue])
    case array([MagnetJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([MagnetJSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: MagnetJSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported Magnet JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct MagnetShortcut: Codable, Equatable, Hashable, Sendable {
    var carbonKeyCode: UInt32
    var carbonModifiers: UInt32
}

struct MagnetTargetFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct MagnetCommand: Codable, Equatable, Identifiable, Sendable {
    var rawObject: [String: MagnetJSONValue]

    var id: String {
        string(at: ["id"]) ?? UUID().uuidString
    }

    var name: String {
        get { string(at: ["name"]) ?? "" }
        set { set(.string(newValue), at: ["name"]) }
    }

    var orientation: MagnetOrientation? {
        get { string(at: ["axis"]).flatMap(MagnetOrientation.init(rawValue:)) }
        set {
            if let newValue { set(.string(newValue.rawValue), at: ["axis"]) }
            else { set(nil, at: ["axis"]) }
        }
    }

    var category: String? { string(at: ["category"]) }

    var isShortcutAvailable: Bool {
        bool(at: ["keyboardShortcut", "available"]) ?? false
    }

    var isShortcutEnabled: Bool {
        get { bool(at: ["keyboardShortcut", "enabled"]) ?? false }
        set { set(.bool(newValue), at: ["keyboardShortcut", "enabled"]) }
    }

    var shortcut: MagnetShortcut? {
        get {
            guard let keyCode = number(at: ["keyboardShortcut", "shortcut", "carbonKeyCode"]),
                  let modifiers = number(at: ["keyboardShortcut", "shortcut", "carbonModifiers"])
            else { return nil }
            return MagnetShortcut(carbonKeyCode: UInt32(keyCode), carbonModifiers: UInt32(modifiers))
        }
        set {
            guard let newValue else {
                set(nil, at: ["keyboardShortcut", "shortcut"])
                isShortcutEnabled = false
                return
            }
            set(.number(Double(newValue.carbonKeyCode)), at: ["keyboardShortcut", "shortcut", "carbonKeyCode"])
            set(.number(Double(newValue.carbonModifiers)), at: ["keyboardShortcut", "shortcut", "carbonModifiers"])
            set(.bool(true), at: ["keyboardShortcut", "available"])
            isShortcutEnabled = true
        }
    }

    var targetFrames: [MagnetTargetFrame] {
        get {
            guard case .array(let segments)? = value(at: ["targetArea", "area", "segments"]) else { return [] }
            return segments.compactMap { segment in
                guard case .object(let object) = segment,
                      case .array(let frame)? = object["frame"], frame.count == 2,
                      case .array(let origin) = frame[0], origin.count == 2,
                      case .array(let size) = frame[1], size.count == 2,
                      case .number(let x) = origin[0], case .number(let y) = origin[1],
                      case .number(let width) = size[0], case .number(let height) = size[1]
                else { return nil }
                return MagnetTargetFrame(x: x, y: y, width: width, height: height)
            }
        }
        set {
            let existing: [MagnetJSONValue]
            if case .array(let segments)? = value(at: ["targetArea", "area", "segments"]) { existing = segments }
            else { existing = [] }

            let segments = newValue.enumerated().map { index, frame -> MagnetJSONValue in
                var object: [String: MagnetJSONValue]
                if existing.indices.contains(index), case .object(let old) = existing[index] { object = old }
                else { object = ["id": .string(UUID().uuidString)] }
                object["frame"] = .array([
                    .array([.number(frame.x), .number(frame.y)]),
                    .array([.number(frame.width), .number(frame.height)])
                ])
                return .object(object)
            }
            set(.array(segments), at: ["targetArea", "area", "segments"])
            set(.bool(true), at: ["targetArea", "available"])
        }
    }

    var primaryTargetFrame: MagnetTargetFrame? {
        get { targetFrames.first }
        set {
            guard let newValue else { targetFrames = [] ; return }
            var frames = targetFrames
            if frames.isEmpty { frames = [newValue] }
            else { frames[0] = newValue }
            targetFrames = frames
        }
    }

    init(rawObject: [String: MagnetJSONValue]) {
        self.rawObject = rawObject
    }

    private func value(at path: [String]) -> MagnetJSONValue? {
        var current: MagnetJSONValue = .object(rawObject)
        for component in path {
            guard case .object(let object) = current, let next = object[component] else { return nil }
            current = next
        }
        return current
    }

    private func string(at path: [String]) -> String? {
        guard case .string(let value)? = value(at: path) else { return nil }
        return value
    }

    private func bool(at path: [String]) -> Bool? {
        guard case .bool(let value)? = value(at: path) else { return nil }
        return value
    }

    private func number(at path: [String]) -> Double? {
        guard case .number(let value)? = value(at: path) else { return nil }
        return value
    }

    private mutating func set(_ value: MagnetJSONValue?, at path: [String]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            rawObject[first] = value
            return
        }
        var child: [String: MagnetJSONValue]
        if case .object(let existing)? = rawObject[first] { child = existing }
        else { child = [:] }
        Self.set(value, in: &child, at: Array(path.dropFirst()))
        rawObject[first] = .object(child)
    }

    private static func set(_ value: MagnetJSONValue?, in object: inout [String: MagnetJSONValue], at path: [String]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            object[first] = value
            return
        }
        var child: [String: MagnetJSONValue]
        if case .object(let existing)? = object[first] { child = existing }
        else { child = [:] }
        set(value, in: &child, at: Array(path.dropFirst()))
        object[first] = .object(child)
    }
}

struct MagnetShortcutConfiguration: Codable, Equatable, Sendable {
    var verticalCommands: [MagnetCommand]
    var horizontalCommands: [MagnetCommand]

    /// Original plist bytes are retained as a fallback so unrelated Magnet
    /// preferences can be preserved even if the live plist is temporarily absent.
    var sourcePropertyList: Data
    var importedAt: Date

    func commands(for orientation: MagnetOrientation) -> [MagnetCommand] {
        orientation == .vertical ? verticalCommands : horizontalCommands
    }

    mutating func replaceCommands(_ commands: [MagnetCommand], for orientation: MagnetOrientation) {
        switch orientation {
        case .vertical: verticalCommands = commands
        case .horizontal: horizontalCommands = commands
        }
    }
}

struct MagnetShortcutConflict: Equatable, Sendable {
    let orientation: MagnetOrientation
    let shortcut: MagnetShortcut
    let commandIDs: [String]
    let commandNames: [String]
}
