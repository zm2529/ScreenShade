import Cocoa
import IOKit.hid
import IOKit.hidsystem

final class PhysicalInput {
    private var manager: IOHIDManager?
    private var armedAt: UInt64 = .max
    var onActivity: ((String) -> Void)?
    var onFailure: (() -> Void)?

    var permitted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func requestPermission() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start() -> Bool {
        stop()
        guard permitted else { return false }
        let deviceManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0))
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 2],
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6],
            [kIOHIDDeviceUsagePageKey: 0x0C, kIOHIDDeviceUsageKey: 1]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(deviceManager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(deviceManager, { context, result, _, value in
            guard let context else { return }
            let observer = Unmanaged<PhysicalInput>.fromOpaque(context).takeUnretainedValue()
            if result != kIOReturnSuccess { observer.onFailure?(); return }
            guard IOHIDValueGetTimeStamp(value) >= observer.armedAt else { return }
            let element = IOHIDValueGetElement(value)
            if InputPolicy.isActivity(page: IOHIDElementGetUsagePage(element),
                                      usage: IOHIDElementGetUsage(element),
                                      value: IOHIDValueGetIntegerValue(value)) {
                observer.armedAt = .max
                let page = IOHIDElementGetUsagePage(element)
                observer.onActivity?(page == 7 || page == 0x0C ? "keyboard" : "mouse")
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(deviceManager, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<PhysicalInput>.fromOpaque(context).takeUnretainedValue().onFailure?()
        }, context)
        IOHIDManagerScheduleWithRunLoop(deviceManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let opened = IOHIDManagerOpen(deviceManager, IOOptionBits(0))
        guard opened == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(deviceManager), CFSetGetCount(devices) > 0 else {
            IOHIDManagerUnscheduleFromRunLoop(deviceManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(deviceManager, IOOptionBits(0))
            return false
        }
        manager = deviceManager
        return true
    }

    func arm() { armedAt = mach_absolute_time() }
    func disarm() { armedAt = .max }

    func stop() {
        disarm()
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(0))
        self.manager = nil
    }
}
