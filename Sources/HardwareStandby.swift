import Cocoa

enum HardwareStandby {
    struct Layout: Codable, Equatable {
        let uuid: String
        let frame: String
        let scale: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let refreshRate: Double
        let rotation: Double
    }

    struct Configuration: Codable {
        let layout: [Layout]
        let modes: [String: Int]

        func validatedModes(for current: [Layout]) -> [String: Int] {
            guard layout.sorted(by: { $0.uuid < $1.uuid }) == current.sorted(by: { $0.uuid < $1.uuid }) else { return [:] }
            let connected = Set(current.map(\.uuid))
            return modes.filter { connected.contains($0.key) && [2, 4].contains($0.value) }
        }
    }

    static var selectedDisplays: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "hardwareStandbyDisplays") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "hardwareStandbyDisplays") }
    }

    static func setEnabled(_ enabled: Bool, for uuid: String) {
        var selected = selectedDisplays
        if enabled { selected.insert(uuid) } else { selected.remove(uuid) }
        selectedDisplays = selected
    }

    static func selectedModes() -> [String: Int] {
        let selected = selectedDisplays
        return validatedModes().filter { selected.contains($0.key) }
    }

    static func currentLayout() -> [Layout] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            return Layout(uuid: CFUUIDCreateString(nil, uuid) as String, frame: NSStringFromRect(screen.frame),
                          scale: screen.backingScaleFactor, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                          refreshRate: mode.refreshRate, rotation: CGDisplayRotation(id))
        }
    }

    static func validatedModes() -> [String: Int] {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenShade/standby-compatibility.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Configuration.self, from: data) else { return [:] }
        return config.validatedModes(for: currentLayout())
    }
}
