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
    struct DimResult {
        let messages: [String]
        let confirmedStandby: [String: Int]
    }

    private struct Reading: Codable { let current: Int; let maximum: Int }
    private struct Saved: Codable { let display: DisplayIdentity; let value: Int; let power: Int? }
    private let queue = DispatchQueue(label: "ScreenShade.brightness")
    private let lock = NSLock()
    private var generation = 0
    private let journal: URL
    private let helper: URL

    init(journal: URL? = nil, helper: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenShade", isDirectory: true)
        self.journal = journal ?? directory.appendingPathComponent("brightness-recovery.json")
        self.helper = helper ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ddc-helper")
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

    private func read(_ display: DisplayIdentity) -> Reading? {
        guard let data = run(["read", "uuid=\(display.uuid)"]),
              let value = try? JSONDecoder().decode(Reading.self, from: data),
              value.maximum > 0, value.current >= 0, value.current <= value.maximum else { return nil }
        return value
    }

    private func readPower(_ display: DisplayIdentity) -> Int? {
        guard let data = run(["read-power", "uuid=\(display.uuid)"]),
              let value = try? JSONDecoder().decode(Reading.self, from: data),
              (1...4).contains(value.current) else { return nil }
        return value.current
    }

    private func wake(_ display: DisplayIdentity) -> Bool {
        for _ in 0..<3 {
            _ = run(["set-power", "uuid=\(display.uuid)", "1"])
            Thread.sleep(forTimeInterval: 0.5)
            if readPower(display) == 1 { return true }
        }
        return false
    }

    private func load() throws -> [Saved] {
        guard FileManager.default.fileExists(atPath: journal.path) else { return [] }
        return try JSONDecoder().decode([Saved].self, from: Data(contentsOf: journal))
    }

    private func save(_ entries: [Saved]) throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: journal, options: .atomic)
    }

    private func remember(_ display: DisplayIdentity, value: Int, power: Int?) throws {
        var entries = try load()
        entries.removeAll { $0.display.uuid == display.uuid }
        entries.append(Saved(display: display, value: value, power: power))
        try save(entries)
    }

    func dim(_ displays: [DisplayIdentity], standbyModes: [String: Int] = [:], fallbackToBrightness: Bool = true,
             completion: @escaping (DimResult) -> Void) {
        let token = nextGeneration()
        queue.async {
            var messages: [String] = []
            var confirmedStandby: [String: Int] = [:]
            for display in displays {
                guard self.current(token) else { break }
                guard let value = self.read(display) else {
                    messages.append("\(display.name)：黑色遮罩（硬件亮度不可读取）")
                    continue
                }
                if let mode = standbyModes[display.uuid], [2, 4].contains(mode) {
                    guard let originalPower = self.readPower(display) else {
                        messages.append("\(display.name)：黑色遮罩（电源状态不可读取，未改变硬件）")
                        continue
                    }
                    guard originalPower == 1 else {
                        messages.append("\(display.name)：原已待机，保持原电源状态")
                        continue
                    }
                    do { try self.remember(display, value: value.current, power: originalPower) }
                    catch {
                        messages.append("\(display.name)：黑色遮罩（电源恢复记录保存失败）")
                        continue
                    }
                    guard self.current(token) else { break }
                    let wrote = self.run(["set-power", "uuid=\(display.uuid)", String(mode)]) != nil
                    Thread.sleep(forTimeInterval: 0.5)
                    let observedPower = wrote ? self.readPower(display) : nil
                    if observedPower == mode {
                        confirmedStandby[display.uuid] = mode
                        messages.append("\(display.name)：硬件待机（已确认电源状态）")
                        continue
                    }
                    // Keep the persisted wake record until power-on is confirmed.
                    guard self.wake(display) else {
                        messages.append("\(display.name)：唤醒未确认，请恢复屏幕或使用显示器电源键")
                        continue
                    }
                    guard self.current(token) else { break }
                    let reason = !wrote ? "待机指令执行失败" : observedPower.map { "电源状态读回为 \($0)" } ?? "无法读回电源状态"
                    messages.append("\(display.name)：硬件待机未确认（\(reason)）" + (fallbackToBrightness ? "，改用最低亮度" : "，保持原亮度"))
                    if !fallbackToBrightness { continue }
                }
                if value.current == 0 {
                    messages.append("\(display.name)：硬件亮度已为最低")
                    continue
                }
                do {
                    try self.remember(display, value: value.current, power: nil)
                } catch {
                    messages.append("\(display.name)：黑色遮罩（原亮度保存失败）")
                    continue
                }
                guard self.current(token) else { break }
                let wrote = self.run(["set", "uuid=\(display.uuid)", "0"]) != nil
                let verified = wrote && self.read(display)?.current == 0
                messages.append("\(display.name)：" + (verified ? "硬件亮度已降至最低" : "黑色遮罩（硬件调光未确认）"))
            }
            DispatchQueue.main.async {
                if self.current(token) { completion(DimResult(messages: messages, confirmedStandby: confirmedStandby)) }
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
                    if let power = entry.power {
                        guard power == 1 && self.wake(entry.display) else {
                            pending.append(entry)
                            messages.append("\(entry.display.name)：唤醒未确认，保留恢复记录")
                            continue
                        }
                    }
                    guard DisplayIdentity.currentID(for: entry.display.uuid) != nil else {
                        pending.append(entry)
                        messages.append("\(entry.display.name)：等待重新连接后恢复亮度")
                        continue
                    }
                    var restored = false
                    for attempt in 0..<3 {
                        let wrote = self.run(["set", "uuid=\(entry.display.uuid)", String(entry.value)]) != nil
                        if wrote && self.read(entry.display)?.current == entry.value { restored = true; break }
                        if attempt < 2 { Thread.sleep(forTimeInterval: 0.2) }
                    }
                    if !restored {
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
