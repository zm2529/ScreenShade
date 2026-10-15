import Foundation

enum InputPolicy {
    static func isPhysicalDevice(transport: String?, builtIn: Bool) -> Bool {
        let transport = transport?.lowercased().replacingOccurrences(of: " ", with: "")
        guard transport != "virtual" else { return false }
        if builtIn { return true }
        switch transport {
        case "usb", "bluetooth", "bluetoothlowenergy", "spi", "i2c", "serial", "aid", "fifo", "spu", "bt-aacp", "iap":
            return true
        default:
            return false
        }
    }

    /// HID values come from devices, rather than posted macOS UI events.
    static func isActivity(page: UInt32, usage: UInt32, value: Int) -> Bool {
        guard value != 0 else { return false }
        switch page {
        case 0x07: return (0x04...0xE7).contains(usage) && value > 0
        case 0x09: return value > 0 // Mouse buttons.
        case 0x01: return [0x30, 0x31, 0x32, 0x38].contains(usage) // Axes/wheel.
        case 0x0C: return value > 0 // Media/function keys.
        default: return false
        }
    }
}
