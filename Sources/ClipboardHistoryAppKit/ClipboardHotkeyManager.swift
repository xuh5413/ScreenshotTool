import Carbon
import Foundation

@MainActor
public final class ClipboardHotkeyActionRouter {
    private let expectedID: UInt32
    private let action: () -> Void

    public init(expectedID: UInt32, action: @escaping () -> Void) {
        self.expectedID = expectedID
        self.action = action
    }

    public func handle(id: UInt32) {
        guard id == expectedID else { return }
        action()
    }
}

@MainActor
public final class ClipboardHotkeyManager {
    public static let hotkeyID: UInt32 = 2
    public static let hotkeySignature: OSType = 0x434C4950

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var router: ClipboardHotkeyActionRouter?

    public init() {}

    @discardableResult
    public func register(action: @escaping () -> Void) -> Bool {
        unregister()
        router = ClipboardHotkeyActionRouter(expectedID: Self.hotkeyID, action: action)
        guard installEventHandler() else {
            router = nil
            return false
        }

        let hotkey = EventHotKeyID(signature: Self.hotkeySignature, id: Self.hotkeyID)
        let status = RegisterEventHotKey(
            0x09,
            UInt32(cmdKey | shiftKey),
            hotkey,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            unregister()
            return false
        }
        return true
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        router = nil
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func installEventHandler() -> Bool {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerProcPtr = { _, event, userData in
            guard let event, let userData else { return noErr }
            let manager = Unmanaged<ClipboardHotkeyManager>
                .fromOpaque(userData)
                .takeUnretainedValue()
            var identifier = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &identifier
            )
            if status == noErr,
               identifier.signature == ClipboardHotkeyManager.hotkeySignature,
               identifier.id == ClipboardHotkeyManager.hotkeyID {
                manager.router?.handle(id: identifier.id)
            }
            return noErr
        }
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        return status == noErr
    }
}
