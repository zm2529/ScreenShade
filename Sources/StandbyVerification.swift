import Cocoa

/// Measures the existing desktop without disconnecting displays or moving windows.
struct StandbySnapshot {
    let layout: [HardwareStandby.Layout]
    let windows: [Int: CGRect]
    var windowsAvailable = true

    static func tracksWindow(layer: Int, ownerPolicy: NSApplication.ActivationPolicy) -> Bool {
        layer == 0 && ownerPolicy == .regular
    }

    static func capture() -> StandbySnapshot {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let list = info ?? []
        var windows: [Int: CGRect] = [:]
        for window in list {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pid != getpid(),
                  tracksWindow(layer: window[kCGWindowLayer as String] as? Int ?? -1,
                               ownerPolicy: NSRunningApplication(processIdentifier: pid)?.activationPolicy ?? .prohibited),
                  let id = window[kCGWindowNumber as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            windows[id] = rect
        }
        return StandbySnapshot(layout: HardwareStandby.currentLayout(), windows: windows, windowsAvailable: info != nil)
    }

    func change(from original: StandbySnapshot) -> String? {
        guard original.windowsAvailable && windowsAvailable else { return "无法读取窗口位置，未能完成布局检查。" }
        guard HardwareStandby.Configuration(layout: original.layout, modes: [:]).matches(layout) else {
            return "显示连接、分辨率或桌面布局发生变化，测试已中止。"
        }
        if original.windows.contains(where: { id, bounds in windows[id].map { $0 != bounds } ?? false }) {
            return "检测到原有窗口位置变化，测试已中止；请检查桌面布局。"
        }
        return nil
    }
}

/// A background deadline requests recovery even if the main run loop is busy.
final class WakeDeadline {
    private let lock = NSLock()
    private var active = true
    private var fired = false
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))

    init(seconds: TimeInterval, recover: @escaping () -> Void) {
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.active else { return }
            self.fired = true
            recover()
        }
        timer.resume()
    }

    var hasFired: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    @discardableResult func performIfActive(_ action: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active && !fired else { return false }
        action()
        return true
    }
    func cancel() { lock.lock(); active = false; lock.unlock(); timer.cancel() }
    deinit { timer.cancel() }
}

/// Uses the same journal and serial recovery queue as normal shading.
final class StandbyVerification {
    struct Result {
        let display: DisplayIdentity
        let layout: [HardwareStandby.Layout]
        let mode: Int?
        let message: String
        let recoveryErrors: [String]
        let cancelled: Bool
        var needsConfirmation: Bool { mode != nil && recoveryErrors.isEmpty && !cancelled }
    }

    private let brightness: Brightness
    private let snapshot: () -> StandbySnapshot
    private let holdDuration: TimeInterval
    private let timeout: TimeInterval
    private var runID = UUID()
    private var baseline: StandbySnapshot?
    private var display: DisplayIdentity?
    private var monitor: Timer?
    private var wakeTimer: Timer?
    private var deadline: WakeDeadline?
    private var recovering = false
    private var candidate: Int?
    private var heldUntil: Date?
    private var failure: String?
    private var attemptMessages: [String] = []
    private var completion: ((Result) -> Void)?
    private(set) var isRunning = false
    var onUpdate: ((String) -> Void)?

    init(brightness: Brightness, holdDuration: TimeInterval = 10, timeout: TimeInterval = 30,
         snapshot: @escaping () -> StandbySnapshot = StandbySnapshot.capture) {
        self.brightness = brightness; self.holdDuration = holdDuration; self.timeout = timeout; self.snapshot = snapshot
    }

    @discardableResult func start(_ display: DisplayIdentity, completion: @escaping (Result) -> Void) -> Bool {
        guard !isRunning else { return false }
        isRunning = true; recovering = false; candidate = nil; heldUntil = nil; failure = nil; attemptMessages = []
        self.display = display; self.completion = completion; baseline = snapshot(); runID = UUID()
        guard baseline?.layout.contains(where: { $0.uuid == display.uuid }) == true,
              baseline?.windowsAvailable == true else {
            finish(message: "测试屏幕已断开或无法读取桌面布局，本次未改变硬件。", errors: [], cancelled: false)
            return true
        }
        let id = runID
        deadline = WakeDeadline(seconds: timeout) { [weak self, brightness] in
            brightness.restore { errors in
                guard let self, self.isRunning, self.runID == id else { return }
                self.finish(message: "测试超时，已请求自动唤醒。", errors: errors, cancelled: false)
            }
        }
        let monitor = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isRunning, let baseline = self.baseline else { return }
            if let change = self.snapshot().change(from: baseline) {
                self.failure = change; self.recover(message: change, cancelled: false); return
            }
            if let heldUntil = self.heldUntil {
                self.onUpdate?("测试中：请尝试远程操作；约 \(max(0, Int(ceil(heldUntil.timeIntervalSinceNow)))) 秒后自动唤醒。")
            }
        }
        self.monitor = monitor
        RunLoop.main.add(monitor, forMode: .common)
        attempt(mode: 4, id: id)
        return true
    }

    private func attempt(mode: Int, id: UUID) {
        guard isRunning, runID == id, deadline?.hasFired != true, let display else { return }
        onUpdate?("正在测试 \(display.name) 的待机方式 \(mode)；其他屏幕保持原状。")
        // Serialize submission with the deadline's recovery submission. A late
        // attempt must never be queued after the final automatic wake.
        deadline?.performIfActive {
            brightness.dim([display], standbyModes: [display.uuid: mode], fallbackToBrightness: false) { [weak self] result in
                guard let self, self.isRunning, self.runID == id, !self.recovering, self.deadline?.hasFired != true else { return }
                self.attemptMessages.append("方式 \(mode)：" + result.messages.joined(separator: "；"))
                if result.confirmedStandby[display.uuid] == mode {
                    self.candidate = mode
                    self.heldUntil = Date().addingTimeInterval(self.holdDuration)
                    let timer = Timer(timeInterval: self.holdDuration, repeats: false) { [weak self] _ in
                        self?.recover(message: "电源状态检查通过，已自动唤醒并恢复原亮度。", cancelled: false)
                    }
                    self.wakeTimer = timer
                    RunLoop.main.add(timer, forMode: .common)
                } else if mode == 4 {
                    // Restore the first attempt before trying a different mode.
                    self.brightness.restore { errors in
                        guard self.isRunning, self.runID == id, !self.recovering, self.deadline?.hasFired != true else { return }
                        if errors.isEmpty { self.attempt(mode: 2, id: id) }
                        else { self.finish(message: "待机未确认，恢复仍需重试。", errors: errors, cancelled: false) }
                    }
                } else {
                    self.recover(message: "两种待机方式均未确认生效。" + self.attemptMessages.joined(separator: "；"), cancelled: false)
                }
            }
        }
    }

    func cancel(reason: String = "测试已取消，已请求唤醒。") {
        guard isRunning else { return }
        recover(message: reason, cancelled: true)
    }

    func checkLayout() {
        guard isRunning, let baseline, let change = snapshot().change(from: baseline) else { return }
        failure = change; recover(message: change, cancelled: false)
    }

    private func recover(message: String, cancelled: Bool) {
        guard isRunning, !recovering else { return }
        recovering = true; heldUntil = nil; wakeTimer?.invalidate()
        onUpdate?("正在唤醒测试屏幕并恢复原亮度…")
        let id = runID
        brightness.restore { [weak self] errors in
            guard let self, self.isRunning, self.runID == id else { return }
            self.finish(message: message, errors: errors, cancelled: cancelled)
        }
    }

    private func finish(message: String, errors: [String], cancelled: Bool) {
        guard isRunning, let display, let baseline else { return }
        let change = failure ?? snapshot().change(from: baseline)
        let timedOut = deadline?.hasFired == true
        isRunning = false; monitor?.invalidate(); wakeTimer?.invalidate(); deadline?.cancel(); deadline = nil
        let result = Result(display: display, layout: baseline.layout,
                            mode: change == nil && !cancelled && !timedOut ? candidate : nil,
                            message: change ?? message, recoveryErrors: errors, cancelled: cancelled)
        let callback = completion; completion = nil
        callback?(result)
    }
}
