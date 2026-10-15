import Cocoa

/// A small, clickable surface above the mouse-transparent shade window.
final class ShadeClosePanel: NSPanel {
    private final class CloseButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen, target: AnyObject, action: Selector) {
        let frame = NSRect(x: screen.visibleFrame.maxX - 180, y: screen.visibleFrame.maxY - 60,
                           width: 164, height: 44)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(frame, display: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let button = CloseButton(title: "关闭遮罩", target: target, action: action)
        button.bezelStyle = .regularSquare
        button.font = .systemFont(ofSize: 15, weight: .medium)
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.appearance = NSAppearance(named: .darkAqua)
        button.toolTip = "关闭所有屏幕的遮罩并恢复原有硬件亮度，远程控制时也可点击。"
        contentView = button
    }
}
