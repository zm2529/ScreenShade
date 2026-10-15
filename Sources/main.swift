import Cocoa

final class ShadeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let input = PhysicalInput()
    private let brightness = Brightness()
    private lazy var verification = StandbyVerification(brightness: brightness)
    private let remoteWake = RemoteWakeHotKey()
    private var status: NSStatusItem!
    private let menu = NSMenu()
    private var windows: [NSWindow] = []
    private var closePanels: [ShadeClosePanel] = []
    private var countdown: Timer?
    private var permissionWatch: Timer?
    private var ready = false
    private var shaded = false
    private var details = ["正在检查亮度恢复记录…"]
    private var exiting = false
    private var menuTracking = false
    private var controlWindow: NSWindow?
    private var standbyStack: NSStackView?
    private var standbyControls: [String: NSButton] = [:]
    private var testControls: [String: NSButton] = [:]
    private var validationLabels: [String: NSTextField] = [:]
    private var verificationStatus: NSTextField?
    private var cancelTestControl: NSButton?
    private var startControl: NSButton?
    private var verificationPrompt: NSAlert?
    private var activeLayout = ""
    private var restoreReason = "manual"
    private var standbyModes: [String: Int] { remoteWake.isRegistered ? HardwareStandby.selectedModes() : [:] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1 {
            DistributedNotificationCenter.default().post(name: .init("local.ScreenShade.showControls"), object: nil)
            NSApp.terminate(nil)
            return
        }
        remoteWake.onWake = { [weak self] in
            self?.restoreReason = "remote-wake-hotkey"
            self?.restore()
        }
        remoteWake.start()
        verification.onUpdate = { [weak self] message in
            self?.details = [message]; self?.writeStatus(phase: "verifying"); self?.rebuildMenu()
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
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openControls), name: .init("local.ScreenShade.showControls"), object: nil)
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ScreenShade"
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "让 Codex 工作，让屏幕安静下来")
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "同时遮黑所有屏幕，尝试降低硬件亮度。\n本机移动鼠标或按任意键恢复；远程控制时，\n可点击遮罩右上角的“关闭遮罩”。")
        let start = NSButton(title: "遮黑所有屏幕（2 秒后）", target: self, action: #selector(toggle))
        start.bezelStyle = .rounded
        startControl = start
        let restore = NSButton(title: "恢复画面与原亮度", target: self, action: #selector(recoverBrightness))
        restore.bezelStyle = .rounded
        let permission = NSButton(title: "设置输入监控权限…", target: self, action: #selector(permission))
        permission.bezelStyle = .rounded
        let wakeHint = NSTextField(labelWithString: remoteWake.isRegistered ? "远程唤醒全部屏幕：⌃⌥⌘R" : "远程唤醒快捷键注册失败，硬件待机暂不可用")
        wakeHint.font = .systemFont(ofSize: 13)
        wakeHint.toolTip = "从远端向 Mac 发送 Control + Option + Command + R，唤醒全部屏幕并恢复原亮度。普通按键不会触发。"
        let standby = NSStackView()
        standby.orientation = .vertical; standby.alignment = .leading; standby.spacing = 8
        standbyStack = standby
        let testStatus = NSTextField(wrappingLabelWithString: "验证可选，未验证也可勾选；每次只测试一块屏幕并自动唤醒。")
        testStatus.font = .systemFont(ofSize: 12)
        verificationStatus = testStatus
        let cancelTest = NSButton(title: "取消测试并唤醒", target: self, action: #selector(cancelVerification))
        cancelTest.bezelStyle = .rounded
        cancelTest.identifier = NSUserInterfaceItemIdentifier("cancelVerification")
        cancelTestControl = cancelTest
        let row = NSStackView(views: [start, restore])
        row.orientation = .horizontal; row.spacing = 12
        let stack = NSStackView(views: [heading, description, standby, testStatus, cancelTest, wakeHint, row, permission])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                                         stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                                         stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)])
        }
        controlWindow = window
        rebuildMenu()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func rebuildStandbyControls(_ displays: [DisplayIdentity]) {
        guard let standbyStack else { return }
        if Set(standbyControls.keys) != Set(displays.map(\.uuid)) {
            for view in standbyStack.arrangedSubviews { standbyStack.removeArrangedSubview(view); view.removeFromSuperview() }
            standbyControls.removeAll()
            testControls.removeAll(); validationLabels.removeAll()
            let label = NSTextField(labelWithString: "硬件待机（逐屏设置）")
            label.font = .systemFont(ofSize: 13, weight: .medium)
            standbyStack.addArrangedSubview(label)
            for display in displays {
                let button = NSButton(checkboxWithTitle: display.name, target: self, action: #selector(toggleStandby(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(display.uuid)
                standbyControls[display.uuid] = button
                let test = NSButton(title: "验证…", target: self, action: #selector(testStandby(_:)))
                test.bezelStyle = .rounded
                test.identifier = NSUserInterfaceItemIdentifier(display.uuid)
                testControls[display.uuid] = test
                let row = NSStackView(views: [button, test]); row.spacing = 12
                let label = NSTextField(wrappingLabelWithString: "")
                label.font = .systemFont(ofSize: 12)
                label.preferredMaxLayoutWidth = 532
                label.maximumNumberOfLines = 2
                label.lineBreakMode = .byTruncatingTail
                validationLabels[display.uuid] = label
                let group = NSStackView(views: [row, label])
                group.orientation = .vertical; group.alignment = .leading; group.spacing = 2
                standbyStack.addArrangedSubview(group)
            }
            controlWindow?.setContentSize(NSSize(width: 580, height: 424 + CGFloat(displays.count) * 56))
        }
        let layout = HardwareStandby.currentLayout()
        let config = HardwareStandby.configuration()
        let editable = ready && !shaded && countdown == nil && verificationPrompt == nil
        for display in displays {
            let result = config?.validation(for: display.uuid, current: layout)
                ?? HardwareStandby.Validation(state: .unverified, message: "验证可选；未验证也可以开启硬件待机。")
            let button = standbyControls[display.uuid]
            button?.state = HardwareStandby.selectedDisplays.contains(display.uuid) ? .on : .off
            button?.isEnabled = editable
            button?.toolTip = "独立设置本屏幕；未验证或验证失败也可以勾选。实际不支持时会尝试恢复并使用最低亮度。"
            testControls[display.uuid]?.isEnabled = editable && remoteWake.isRegistered
            validationLabels[display.uuid]?.stringValue = "\(result.state.title)：\(result.message)"
            validationLabels[display.uuid]?.toolTip = result.message
            validationLabels[display.uuid]?.textColor = result.state == .failed ? .systemOrange : .secondaryLabelColor
        }
        verificationStatus?.stringValue = verification.isRunning ? details.joined(separator: "\n")
            : "验证可选，未验证也可勾选；每次只测试一块屏幕并自动唤醒。"
        cancelTestControl?.isEnabled = verification.isRunning
        startControl?.isEnabled = (ready && verificationPrompt == nil) || shaded || countdown != nil
    }

    private func rebuildMenu() {
        guard status != nil, !menuTracking else { return }
        let displays = DisplayIdentity.connected()
        rebuildStandbyControls(displays)
        menu.removeAllItems()
        add(shaded ? "已遮黑全部屏幕" : (countdown != nil ? "2 秒后遮黑…" : "ScreenShade"), nil, enabled: false)
        add(shaded || countdown != nil ? "恢复全部屏幕" : "遮黑所有屏幕", #selector(toggle), enabled: (ready && verificationPrompt == nil) || shaded || countdown != nil)
        add(remoteWake.isRegistered ? "唤醒全部屏幕并恢复原亮度（⌃⌥⌘R）" : "唤醒全部屏幕并恢复原亮度（快捷键不可用）", #selector(recoverBrightness))
        add("打开控制窗口", #selector(openControls))
        menu.addItem(.separator())
        add("硬件待机（逐屏设置）", nil, enabled: false)
        let layout = HardwareStandby.currentLayout()
        let config = HardwareStandby.configuration()
        for display in displays {
            let state = config?.validation(for: display.uuid, current: layout).state ?? .unverified
            add("\(display.name)（\(state.title)）", #selector(toggleStandby(_:)),
                enabled: ready && !shaded && countdown == nil && verificationPrompt == nil)
            menu.items.last?.representedObject = display.uuid
            menu.items.last?.state = HardwareStandby.selectedDisplays.contains(display.uuid) ? .on : .off
            add("验证 \(display.name)…", #selector(testStandby(_:)), enabled: ready && !shaded && countdown == nil && verificationPrompt == nil && remoteWake.isRegistered)
            menu.items.last?.representedObject = display.uuid
        }
        if verification.isRunning { add("取消测试并唤醒", #selector(cancelVerification)) }
        menu.addItem(.separator())
        add(input.permitted ? "输入监控权限：已允许" : "设置输入监控权限…", #selector(permission), enabled: !input.permitted)
        for detail in details { add(detail, nil, enabled: false) }
        menu.addItem(.separator())
        add("退出", #selector(quit))
        status.button?.image = NSImage(systemSymbolName: shaded ? "display.trianglebadge.exclamationmark" : "display", accessibilityDescription: "ScreenShade")
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu(); menuTracking = true }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false }
    @objc private func openControls() {
        guard !shaded && countdown == nil else { return }
        showControls()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleStandby(_ sender: AnyObject) {
        let uuid = (sender as? NSButton)?.identifier?.rawValue ?? (sender as? NSMenuItem)?.representedObject as? String
        guard let uuid, ready && !shaded && countdown == nil, verificationPrompt == nil else { return }
        HardwareStandby.setEnabled(!HardwareStandby.selectedDisplays.contains(uuid), for: uuid)
        writeStatus(phase: "ready")
        rebuildMenu()
    }

    @objc private func testStandby(_ sender: AnyObject) {
        let uuid = (sender as? NSButton)?.identifier?.rawValue ?? (sender as? NSMenuItem)?.representedObject as? String
        guard let uuid, ready, !shaded, countdown == nil, verificationPrompt == nil, remoteWake.isRegistered,
              let display = DisplayIdentity.connected().first(where: { $0.uuid == uuid }) else { return }
        showControls()
        let alert = NSAlert()
        alert.messageText = "验证 \(display.name) 的硬件待机"
        alert.informativeText = "只测试这一块屏幕，保持软件桌面连接，不添加遮罩或监听普通键鼠。确认进入待机后约 10 秒自动唤醒并恢复原亮度；必要的读写重试会延长时间。\n\n请在测试期间尝试远程点击、按键和查看画面，观察屏幕是否熄灭。不要移动已有窗口或更改显示器连接。检测到布局变化会立即请求恢复；硬件行为无法事先保证。\n\n可随时点击“取消测试并唤醒”或按 ⌃⌥⌘R。验证可跳过，不影响勾选设置。"
        alert.addButton(withTitle: "开始测试"); alert.addButton(withTitle: "取消")
        verificationPrompt = alert
        rebuildMenu()
        alert.beginSheetModal(for: controlWindow!) { [weak self] response in
            guard let self, self.verificationPrompt === alert else { return }
            self.verificationPrompt = nil
            guard response == .alertFirstButtonReturn, self.ready, !self.shaded, self.countdown == nil else { self.rebuildMenu(); return }
            self.ready = false
            self.verification.start(display) { [weak self] result in self?.finishVerification(result) }
            self.rebuildMenu()
        }
    }

    @objc private func cancelVerification() { verification.cancel() }

    private func finishVerification(_ result: StandbyVerification.Result) {
        details = [result.message] + result.recoveryErrors
        ready = result.recoveryErrors.isEmpty
        let initialState: HardwareStandby.ValidationState = result.cancelled && result.recoveryErrors.isEmpty ? .unverified : .failed
        saveVerification(result, state: result.needsConfirmation ? .unverified : initialState,
                         message: result.needsConfirmation ? "自动检查完成，尚未确认熄屏和远程操作。" : details.joined(separator: "；"))
        writeStatus(phase: ready ? "ready" : "recovery-needed"); rebuildMenu()
        if exiting {
            if ready { NSApp.reply(toApplicationShouldTerminate: true) }
            else { exiting = false; NSApp.reply(toApplicationShouldTerminate: false) }
            return
        }
        guard result.needsConfirmation else { return }
        let alert = NSAlert()
        alert.messageText = "\(result.display.name)：自动检查已完成"
        alert.informativeText = "待机读数、自动唤醒、原亮度恢复和桌面布局检查通过。\n\n请确认屏幕确实熄灭并恢复，且测试期间远程画面、鼠标和键盘保持正常。实际出现异常请选择“验证失败”；未观察或未使用远控请选择“暂不确认”，保留未验证状态。选择不会修改本屏幕的待机勾选。"
        alert.addButton(withTitle: "确认通过"); alert.addButton(withTitle: "验证失败"); alert.addButton(withTitle: "暂不确认")
        verificationPrompt = alert
        rebuildMenu()
        alert.beginSheetModal(for: controlWindow!) { [weak self] response in
            guard let self, self.verificationPrompt === alert else { return }
            self.verificationPrompt = nil
            if response == .alertFirstButtonReturn {
                self.saveVerification(result, state: .passed, message: "自动检查通过，已确认熄屏及远程操作正常。")
            } else if response == .alertSecondButtonReturn {
                self.saveVerification(result, state: .failed, message: "用户确认熄屏、恢复或远程操作存在异常。")
            }
            self.rebuildMenu()
        }
    }

    private func saveVerification(_ result: StandbyVerification.Result, state: HardwareStandby.ValidationState, message: String) {
        do {
            let layout = HardwareStandby.currentLayout()
            let matches = HardwareStandby.Configuration(layout: result.layout, modes: [:]).matches(layout)
            let validation = !matches && state == .passed
                ? HardwareStandby.Validation(state: .unverified, message: "确认前桌面布局已改变，请重新验证。")
                : HardwareStandby.Validation(state: state, message: message)
            try HardwareStandby.record(validation, for: result.display.uuid,
                                       mode: matches ? result.mode : nil, layout: layout)
        } catch { details.append("无法保存验证结果，请检查本机配置目录权限。") }
    }

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
                                    "inputPermission": input.permitted, "details": details,
                                    "hardwareStandbyDisplays": standbyModes.keys.sorted(), "remoteWakeHotkeyAvailable": remoteWake.isRegistered]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
                .write(to: directory.appendingPathComponent("status.json"), options: .atomic)
        } catch { NSLog("ScreenShade: could not write status") }
    }

    @objc private func toggle() {
        if shaded || countdown != nil { restore(); return }
        guard ready, verificationPrompt == nil else { return }
        switch input.start() {
        case .ready: break
        case .permissionRequired: permission(); return
        case .unavailable(let message):
            details = [message]
            restoreReason = "input-device-unavailable"
            writeStatus(phase: "input-error")
            rebuildMenu()
            let alert = NSAlert()
            alert.messageText = "暂时无法监听鼠标和键盘"
            alert.informativeText = message + "\n输入监控权限已允许；本次未开始遮黑。"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
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
            let closePanel = ShadeClosePanel(screen: screen, target: self, action: #selector(closeShade))
            closePanel.orderFrontRegardless()
            closePanels.append(closePanel)
        }
        shaded = true
        activeLayout = screenLayout()
        restoreReason = "none"
        input.arm()
        details = ["已遮黑 \(windows.count) 块屏幕；正在尝试硬件调光…"]
        writeStatus(phase: "shaded")
        brightness.dim(displays, standbyModes: standbyModes) { [weak self] result in
            self?.details = result.messages; self?.writeStatus(phase: "shaded"); self?.rebuildMenu()
        }
        rebuildMenu()
        NSLog("ScreenShade: shaded %d displays", windows.count)
    }

    @objc private func closeShade() {
        guard shaded else { return }
        restoreReason = "overlay-close-button"
        restore()
    }

    @objc private func restore() {
        if let alert = verificationPrompt {
            verificationPrompt = nil
            controlWindow?.endSheet(alert.window, returnCode: .alertThirdButtonReturn)
        }
        if verification.isRunning { verification.cancel(); return }
        countdown?.invalidate(); countdown = nil
        input.stop()
        for panel in closePanels { panel.orderOut(nil); panel.close() }
        closePanels.removeAll()
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
            if self.exiting {
                if self.ready { NSApp.reply(toApplicationShouldTerminate: true) }
                else { self.exiting = false; NSApp.reply(toApplicationShouldTerminate: false) }
            }
        }
        NSLog("ScreenShade: restored display content")
    }

    @objc private func topologyChanged() {
        if verification.isRunning { verification.checkLayout(); return }
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
        guard !input.permitted else { return }
        restore()
        input.requestPermission()
        guard !input.permitted else { rebuildMenu(); return }
        let alert = NSAlert()
        alert.messageText = "允许 ScreenShade 检测你的鼠标和键盘活动"
        alert.informativeText = "请在系统设置 → 隐私与安全性 → 输入监控中开启 ScreenShade。若开关已开启但仍提示未允许，可能是旧版本签名的授权：移除旧条目，再添加当前 App 并开启权限。允许后如系统要求，请完整退出并重新打开 App。只检测设备活动，不保存按键内容；权限不足时不会遮黑。"
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
        openControls(); return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
