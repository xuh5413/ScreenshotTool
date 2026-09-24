import Carbon
import Foundation

public final class ClipboardHotkeyActionRouter {
    private let expectedSignature: OSType
    private let expectedID: UInt32
    private let action: () -> Void

    public init(expectedSignature: OSType, expectedID: UInt32, action: @escaping () -> Void) {
        self.expectedSignature = expectedSignature
        self.expectedID = expectedID
        self.action = action
    }

    @discardableResult
    public func handle(signature: OSType, id: UInt32) -> Bool {
        guard signature == expectedSignature, id == expectedID else { return false }
        action()
        return true
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
        router = ClipboardHotkeyActionRouter(
            expectedSignature: Self.hotkeySignature,
            expectedID: Self.hotkeyID,
            action: action
        )
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
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
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
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            return manager.router?.handle(signature: identifier.signature, id: identifier.id) == true
                ? OSStatus(noErr)
                : OSStatus(eventNotHandledErr)
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
