//
//  MacKeyboardStyle.swift
//  Space Manager
//

import IOKit

enum MacKeyboardStyle: String, CaseIterable, Identifiable {
    case standard
    case numericKeypad

    var id: String { rawValue }
    var title: String { self == .standard ? "Standard" : "Numeric Keypad" }
}

enum KeyboardHardwareDetector {
    static let detectedStyle: MacKeyboardStyle = {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOHIDDevice"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return .standard }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service,
                &properties,
                kCFAllocatorDefault,
                0) == KERN_SUCCESS,
                let values = properties?.takeRetainedValue() as? [String: Any],
                (values["PrimaryUsagePage"] as? NSNumber)?.intValue == 1,
                (values["PrimaryUsage"] as? NSNumber)?.intValue == 6,
                style(for: values) == .numericKeypad
            else { continue }
            return .numericKeypad
        }
        return .standard
    }()

    static func style(for device: IOHIDDevice) -> MacKeyboardStyle? {
        let keys = ["Product", "HIDVirtualDevice", "VendorID", "ProductID"]
        let values = Dictionary(uniqueKeysWithValues: keys.compactMap { key -> (String, Any)? in
            guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
            return (key, value)
        })
        return style(for: values)
    }

    private static func style(for values: [String: Any]) -> MacKeyboardStyle? {
        let product = (values["Product"] as? String ?? "").lowercased()
        let isVirtual = (values["HIDVirtualDevice"] as? NSNumber)?.boolValue == true
        if isVirtual || product.contains("virtual") || product.contains("karabiner") {
            return nil
        }

        let vendor = (values["VendorID"] as? NSNumber)?.intValue
        let productID = (values["ProductID"] as? NSNumber)?.intValue
        // Apple uses 0x004c for these keyboards over Bluetooth and 0x05ac
        // over USB. 0x026c is the ANSI Magic Keyboard with Numeric Keypad;
        // adjacent IDs are its ISO/JIS variants. Product names are only a
        // fallback because macOS permits custom Bluetooth device names.
        let appleExtendedProductIDs: Set<Int> = [0x026C, 0x026D, 0x026E]
        if (vendor == 0x004C || vendor == 0x05AC),
           let productID,
           appleExtendedProductIDs.contains(productID) {
            return .numericKeypad
        }
        if product.contains("numeric keypad") || product.contains("extended keyboard") {
            return .numericKeypad
        }
        return .standard
    }
}
