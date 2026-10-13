import Cocoa

struct DisplayIdentity: Codable {
    let uuid: String
    let name: String
    let displayID: UInt32

    static func connected() -> [DisplayIdentity] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            return DisplayIdentity(uuid: CFUUIDCreateString(nil, uuid) as String,
                                   name: screen.localizedName, displayID: id)
        }
    }

    static func currentID(for uuid: String) -> UInt32? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { id in
            guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return false }
            return CFUUIDCreateString(nil, value) as String == uuid
        }
    }
}

final class Brightness {
    private struct Reading: Codable { let current: Int; let maximum: Int }
    private struct Saved: Codable { let display: DisplayIdentity; let value: Int }
    private let queue = DispatchQueue(label: "ScreenShade.brightness")
    private let lock = NSLock()
    private var generation = 0
    private let journal: URL
    private let helper: URL

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenShade", isDirectory: true)
        journal = directory.appendingPathComponent("brightness-recovery.json")
        helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ddc-helper")
    }

    private func nextGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1; return generation
    }

    private func current(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token
    }

    private func run(_ arguments: [String]) -> Data? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = helper
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if task.isRunning {
            task.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
            return nil
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    private func read(_ id: UInt32) -> Reading? {
        guard let data = run(["read", String(id)]),
              let value = try? JSONDecoder().decode(Reading.self, from: data),
              value.maximum > 0, value.current >= 0, value.current <= value.maximum else { return nil }
        return value
    }

    private func load() throws -> [Saved] {
        guard FileManager.default.fileExists(atPath: journal.path) else { return [] }
        return try JSONDecoder().decode([Saved].self, from: Data(contentsOf: journal))
    }

    private func save(_ entries: [Saved]) throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: journal, options: .atomic)
    }

    func dim(_ displays: [DisplayIdentity], completion: @escaping ([String]) -> Void) {
        let token = nextGeneration()
        queue.async {
            var messages: [String] = []
            for display in displays {
                guard self.current(token) else { break }
                guard let value = self.read(display.displayID) else {
                    messages.append("\(display.name)：黑色遮罩（硬件亮度不可读取）")
                    continue
                }
                if value.current == 0 {
                    messages.append("\(display.name)：硬件亮度已为最低")
                    continue
                }
                do {
                    var entries = try self.load()
                    entries.removeAll { $0.display.uuid == display.uuid }
                    entries.append(Saved(display: display, value: value.current))
                    try self.save(entries) // Persist the original before changing hardware.
                } catch {
                    messages.append("\(display.name)：黑色遮罩（原亮度保存失败）")
                    continue
                }
                guard self.current(token) else { break }
                let wrote = self.run(["set", String(display.displayID), "0"]) != nil
                let verified = wrote && self.read(display.displayID)?.current == 0
                messages.append("\(display.name)：" + (verified ? "硬件亮度已降至最低" : "黑色遮罩（硬件调光未确认）"))
            }
            DispatchQueue.main.async {
                if self.current(token) { completion(messages) }
            }
        }
    }

    /// Also runs at startup to recover hardware settings after a previous crash.
    func restore(completion: @escaping ([String]) -> Void) {
        _ = nextGeneration()
        queue.async {
            var pending: [Saved] = []
            var messages: [String] = []
            do {
                for entry in try self.load() {
                    guard let id = DisplayIdentity.currentID(for: entry.display.uuid) else {
                        pending.append(entry)
                        messages.append("\(entry.display.name)：等待重新连接后恢复亮度")
                        continue
                    }
                    let wrote = self.run(["set", String(id), String(entry.value)]) != nil
                    if !wrote || self.read(id)?.current != entry.value {
                        pending.append(entry)
                        messages.append("\(entry.display.name)：原亮度恢复未确认，请重试")
                    }
                }
                try self.save(pending)
            } catch { messages.append("无法读取或保存亮度恢复记录") }
            DispatchQueue.main.async { completion(messages) }
        }
    }
}
