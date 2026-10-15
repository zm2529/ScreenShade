import Cocoa

enum HardwareStandby {
    enum ValidationState: String, Codable {
        case unverified, passed, failed

        var title: String {
            switch self {
            case .unverified: return "未验证"
            case .passed: return "验证通过"
            case .failed: return "验证失败"
            }
        }
    }

    struct Validation: Codable {
        let state: ValidationState
        let message: String
    }

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
        var modes: [String: Int]
        // Older local profiles only stored modes. They do not imply user confirmation.
        var results: [String: Validation]? = nil

        func matches(_ current: [Layout]) -> Bool {
            layout.sorted(by: { $0.uuid < $1.uuid }) == current.sorted(by: { $0.uuid < $1.uuid })
        }

        func mode(for uuid: String, current: [Layout]) -> Int {
            guard matches(current), let mode = modes[uuid], [2, 4].contains(mode) else { return 4 }
            return mode
        }

        func validation(for uuid: String, current: [Layout]) -> Validation {
            guard matches(current), let result = results?[uuid] else {
                return Validation(state: .unverified, message: "验证可选；未验证也可以开启硬件待机。")
            }
            return result
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
        let layout = currentLayout()
        let config = configuration()
        return Dictionary(uniqueKeysWithValues: layout.filter { selected.contains($0.uuid) }.map {
            ($0.uuid, config?.mode(for: $0.uuid, current: layout) ?? 4)
        })
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

    static var configurationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenShade/standby-compatibility.json")
    }

    static func configuration(at url: URL = configurationURL) -> Configuration? {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Configuration.self, from: data) else { return nil }
        return config
    }

    static func record(_ validation: Validation, for uuid: String, mode: Int?, layout: [Layout],
                       at url: URL = configurationURL) throws {
        var config = configuration(at: url).flatMap { $0.matches(layout) ? $0 : nil }
            ?? Configuration(layout: layout, modes: [:])
        config.results = (config.results ?? [:]).merging([uuid: validation]) { _, new in new }
        config.modes[uuid] = mode.flatMap { [2, 4].contains($0) ? $0 : nil }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: url, options: .atomic)
    }
}
