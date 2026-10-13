import Foundation

@main struct InputPolicyTests {
    static func main() {
        func check(_ page: UInt32, _ usage: UInt32, _ value: Int, _ expected: Bool) {
            precondition(InputPolicy.isActivity(page: page, usage: usage, value: value) == expected,
                         "Unexpected activity for \(page):\(usage):\(value)")
        }
        check(7, 4, 1, true) // A physical key press.
        check(7, 4, 0, false) // Releases must not wake.
        check(7, 0xE1, 1, true) // Modifier-only key press.
        check(7, 1, 1, false) // Keyboard error/rollover report.
        check(1, 0x30, 1, true)
        check(1, 0x31, -1, true) // Mouse movement in either direction.
        check(1, 0x30, 0, false) // Stationary mouse.
        check(1, 0x38, -1, true) // Mouse wheel.
        check(9, 1, 1, true)
        check(9, 1, 0, false)
        check(0x0C, 0xE9, 1, true) // Media key.
        check(0xFF00, 1, 1, false) // Vendor telemetry must not wake.
        print("Physical input boundaries: passed")
    }
}
