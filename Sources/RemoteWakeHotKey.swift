import Cocoa
import Carbon.HIToolbox

/// One explicit recovery chord; ordinary posted keyboard events are not monitored.
final class RemoteWakeHotKey {
    private static let signature: OSType = 0x53534844
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onWake: (() -> Void)?
    var isRegistered: Bool { hotKey != nil }

    @discardableResult func start() -> Bool {
        if isRegistered { return true }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == RemoteWakeHotKey.signature, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            Unmanaged<RemoteWakeHotKey>.fromOpaque(context).takeUnretainedValue().onWake?()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return false }
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey | cmdKey),
                                            EventHotKeyID(signature: Self.signature, id: 1),
                                            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        if registered != noErr {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            hotKey = nil
        }
        return isRegistered
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
