import Carbon
import Foundation

public enum CarbonHotkeyError: LocalizedError {
    case eventHandlerInstallationFailed(OSStatus)
    case registrationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .eventHandlerInstallationFailed(status):
            "Could not install the global hotkey handler (\(status))."
        case let .registrationFailed(status):
            "The selected global hotkey is unavailable (\(status))."
        }
    }
}

@MainActor
public final class CarbonHotkeySource {
    public typealias Handler = @MainActor (PushToTalkEvent) -> Void

    nonisolated fileprivate static let signature: OSType = 0x5744_5054 // "WDPT"
    nonisolated fileprivate static let identifier: UInt32 = 1

    private var eventHandlerReference: EventHandlerRef?
    private var hotkeyReference: EventHotKeyRef?
    private var edgeFilter = PushToTalkEdgeFilter()
    private var handler: Handler?

    public init() {}

    public func register(
        chord: HotkeyChord,
        handler: @escaping Handler
    ) throws {
        unregister()
        self.handler = handler

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyCallback,
            eventTypes.count,
            &eventTypes,
            context,
            &eventHandlerReference
        )
        guard handlerStatus == noErr else {
            self.handler = nil
            throw CarbonHotkeyError.eventHandlerInstallationFailed(handlerStatus)
        }

        let hotkeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.identifier
        )
        let registrationStatus = RegisterEventHotKey(
            chord.keyCode,
            chord.modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyReference
        )
        guard registrationStatus == noErr else {
            unregister()
            throw CarbonHotkeyError.registrationFailed(registrationStatus)
        }
    }

    public func unregister() {
        if let hotkeyReference {
            UnregisterEventHotKey(hotkeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }

        hotkeyReference = nil
        eventHandlerReference = nil
        handler = nil
        edgeFilter = PushToTalkEdgeFilter()
    }

    fileprivate func receive(eventKind: UInt32) {
        let event: PushToTalkEvent?
        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            event = edgeFilter.receiveKeyDown()
        case UInt32(kEventHotKeyReleased):
            event = edgeFilter.receiveKeyUp()
        default:
            event = nil
        }

        if let event {
            handler?(event)
        }
    }
}

private let carbonHotkeyCallback: EventHandlerUPP = {
    _, event, userData in
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var hotkeyID = EventHotKeyID()
    let parameterStatus = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    guard
        parameterStatus == noErr,
        hotkeyID.signature == CarbonHotkeySource.signature,
        hotkeyID.id == CarbonHotkeySource.identifier
    else {
        return OSStatus(eventNotHandledErr)
    }

    let source = Unmanaged<CarbonHotkeySource>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let eventKind = GetEventKind(event)

    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            source.receive(eventKind: eventKind)
        }
    }
    return noErr
}
