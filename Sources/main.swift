import Cocoa

final class ShadeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let input = PhysicalInput()
    private let brightness = Brightness()
    private var status: NSStatusItem!
    private let menu = NSMenu()
    private var windows: [NSWindow] = []
    private var countdown: Timer?
    private var failsafe: Timer?
    private var permissionWatch: Timer?
    private var ready = false
    private var shaded = false
    private var details = ["正在检查亮度恢复记录…"]
    private var exiting = false
    private var menuTracking = false
    private var controlWindow: NSWindow?
    private var activeLayout = ""
    private var restoreReason = "manual"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1 {
            DistributedNotificationCenter.default().post(name: .init("local.ScreenShade.toggle"), object: nil)
            NSApp.terminate(nil)
            return
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "ScreenShade")
        status.menu = menu
        menu.delegate = self
        rebuildMenu()
        input.onActivity = { [weak self] kind in
            DispatchQueue.main.async { self?.restoreReason = "physical-\(kind)"; self?.restore() }
        }
        input.onFailure = { [weak self] in
            DispatchQueue.main.async { self?.restoreReason = "input-device-unavailable"; self?.restore() }
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(toggle), name: .init("local.ScreenShade.toggle"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(restore), name: .init("local.ScreenShade.restore"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(topologyChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(restore), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(restore), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        brightness.restore { [weak self] messages in
            guard let self else { return }
            self.ready = messages.isEmpty
            self.details = messages.isEmpty ? ["移动鼠标或按任意键恢复", "Codex 的普通后台输入不会触发恢复"] : messages
            self.writeStatus(phase: "ready")
            self.rebuildMenu()
        }
        permissionWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.shaded && !self.input.permitted { self.restoreReason = "permission-lost"; self.restore() }
            self.rebuildMenu()
        }
        showControls()
        if CommandLine.arguments.contains("--shade") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggle() } }
    }

    private func add(_ title: String, _ action: Selector?, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.isEnabled = enabled; menu.addItem(item)
    }

    private func showControls() {
        if let controlWindow { controlWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 245),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ScreenShade"
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "让 Codex 工作，让屏幕安静下来")
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "同时遮黑所有屏幕，尝试降低硬件亮度。\n你移动鼠标或按任意键时恢复。")
        let start = NSButton(title: "遮黑所有屏幕（2 秒后）", target: self, action: #selector(toggle))
        start.bezelStyle = .rounded
        let restore = NSButton(title: "恢复画面与原亮度", target: self, action: #selector(recoverBrightness))
        restore.bezelStyle = .rounded
        let permission = NSButton(title: "设置输入监控权限…", target: self, action: #selector(permission))
        permission.bezelStyle = .rounded
        let row = NSStackView(views: [start, restore])
        row.orientation = .horizontal; row.spacing = 12
        let stack = NSStackView(views: [heading, description, row, permission])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                                         stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                                         stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)])
        }
        window.center()
        controlWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func rebuildMenu() {
        guard status != nil, !menuTracking else { return }
        menu.removeAllItems()
        add(shaded ? "已遮黑全部屏幕" : (countdown != nil ? "2 秒后遮黑…" : "ScreenShade"), nil, enabled: false)
        add(shaded || countdown != nil ? "恢复全部屏幕" : "遮黑所有屏幕", #selector(toggle), enabled: ready || shaded || countdown != nil)
        add("恢复原有硬件亮度", #selector(recoverBrightness))
        add("打开控制窗口", #selector(openControls))
        menu.addItem(.separator())
        add(input.permitted ? "输入监控权限：已允许" : "设置输入监控权限…", #selector(permission))
        for detail in details { add(detail, nil, enabled: false) }
        add("1 小时后自动恢复", nil, enabled: false)
        menu.addItem(.separator())
        add("退出", #selector(quit))
        status.button?.image = NSImage(systemSymbolName: shaded ? "display.trianglebadge.exclamationmark" : "display", accessibilityDescription: "ScreenShade")
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu(); menuTracking = true }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false }
    @objc private func openControls() { showControls(); NSApp.activate(ignoringOtherApps: true) }

    private func screenLayout() -> String {
        NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return "\(id):\(screen.frame):\(screen.backingScaleFactor)"
        }.sorted().joined(separator: "|")
    }

    private func writeStatus(phase: String) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenShade", isDirectory: true)
        let record: [String: Any] = ["phase": phase, "timestamp": Date().timeIntervalSince1970,
                                    "displayCount": windows.count, "restoreReason": restoreReason,
                                    "inputPermission": input.permitted, "details": details]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
                .write(to: directory.appendingPathComponent("status.json"), options: .atomic)
        } catch { NSLog("ScreenShade: could not write status") }
    }

    @objc private func toggle() {
        if shaded || countdown != nil { restore(); return }
        guard ready else { return }
        guard input.start() else { permission(); return }
        countdown = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.activate() }
        rebuildMenu()
    }

    private func activate() {
        countdown = nil
        guard input.permitted else { restore(); return }
        let displays = DisplayIdentity.connected()
        guard !displays.isEmpty else { restore(); return }
        controlWindow?.orderOut(nil)
        for screen in NSScreen.screens {
            let window = ShadeWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.setFrame(screen.frame, display: true)
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            windows.append(window)
        }
        shaded = true
        activeLayout = screenLayout()
        restoreReason = "none"
        input.arm()
        details = ["已遮黑 \(windows.count) 块屏幕；正在尝试硬件调光…"]
        failsafe = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { [weak self] _ in self?.restore() }
        writeStatus(phase: "shaded")
        brightness.dim(displays) { [weak self] messages in
            self?.details = messages; self?.writeStatus(phase: "shaded"); self?.rebuildMenu()
        }
        rebuildMenu()
        NSLog("ScreenShade: shaded %d displays", windows.count)
    }

    @objc private func restore() {
        countdown?.invalidate(); countdown = nil
        failsafe?.invalidate(); failsafe = nil
        input.stop()
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll()
        shaded = false
        ready = false
        details = ["画面已恢复；正在恢复原有硬件亮度…"]
        writeStatus(phase: "restoring")
        rebuildMenu()
        brightness.restore { [weak self] messages in
            guard let self else { return }
            self.ready = messages.isEmpty
            self.details = messages.isEmpty ? ["已恢复正常显示和原有硬件亮度"] : messages
            self.writeStatus(phase: "ready")
            self.rebuildMenu()
            if self.exiting { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        NSLog("ScreenShade: restored display content")
    }

    @objc private func topologyChanged() {
        // Do not leave stale overlays or apply saved settings to a different display.
        if shaded {
            // A brightness/color change can notify AppKit without changing layout.
            if screenLayout() != activeLayout { restoreReason = "display-layout-changed"; restore() }
        }
        else if countdown != nil { restoreReason = "display-layout-changed"; restore() }
        else { recoverBrightness() }
    }

    @objc private func recoverBrightness() { restore() }

    @objc private func permission() {
        restore()
        if !input.permitted { input.requestPermission() }
        let alert = NSAlert()
        alert.messageText = "允许 ScreenShade 检测你的鼠标和键盘活动"
        alert.informativeText = "请在系统设置 → 隐私与安全性 → 输入监控中开启 ScreenShade。只检测物理设备是否有活动，不保存按键内容。权限不足时不会遮黑屏幕。允许后如系统要求，请退出并重新打开 App。"
        alert.addButton(withTitle: "打开输入监控设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard status != nil else { return .terminateNow }
        exiting = true
        restore()
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggle(); return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
