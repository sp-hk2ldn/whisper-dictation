import Foundation
import IOKit.hid

enum MicroTransportEvent: Sendable {
    case status(MicroLightingError?)
    case input(MicroInput)
}

final class CodexMicroTransport: @unchecked Sendable {
    private static let vendorID = 0x303A
    private static let productID = 0x8360
    private static let vendorReportID: UInt32 = 6
    private static let reportBufferSize = 512
    private static let handshakeTimeout: TimeInterval = 2
    private static let initialBackoffSeconds = 1
    private static let maximumBackoffSeconds = 30
    private static let maximumBackoffExponent = 5
    private static let keyboardUsagePages = [0x07, 0x0C]

    private final class HIDHandle {
        let device: IOHIDDevice
        let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: CodexMicroTransport.reportBufferSize
        )

        init(device: IOHIDDevice) {
            self.device = device
        }

        deinit {
            reportBuffer.deallocate()
        }
    }

    private final class Connection {
        let handles: [HIDHandle]
        let bluetooth: Bool
        var parser = MicroHIDProtocol.MessageParser()
        var isReady = false

        init(handles: [HIDHandle], bluetooth: Bool) {
            self.handles = handles
            self.bluetooth = bluetooth
        }

        var vendorDevice: IOHIDDevice? { handles.first?.device }
    }

    private let queue = DispatchQueue(
        label: "WhisperDictation.micro-transport",
        qos: .utility
    )
    private let lock = NSLock()
    private let onEvent: @Sendable (MicroTransportEvent) -> Void
    private var desired: MicroPicture?
    private var running = false
    private var connection: Connection?
    private var applied: MicroPicture?
    private var nextRequestID = 0
    private var statusRequestID: Int?
    private var failures = 0
    private var rotation = 0
    private var retry: DispatchWorkItem?

    init(onEvent: @escaping @Sendable (MicroTransportEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            failures = 0
            rotation = 0
            connect()
        }
    }

    func show(_ picture: MicroPicture) {
        lock.withLock { desired = picture }
        queue.async { [self] in flush() }
    }

    func reconnect() {
        queue.async { [self] in
            guard running, connection == nil else { return }
            retry?.cancel()
            failures = 0
            connect()
        }
    }

    enum Ending: Sendable {
        case clearLights
        case leaveLights
    }

    func stop(
        _ ending: Ending = .clearLights,
        completion: @escaping @Sendable () -> Void
    ) {
        queue.async { [self] in
            retry?.cancel()
            retry = nil
            lock.withLock { desired = nil }
            if ending == .clearLights { clearLights() }
            teardown()
            running = false
            completion()
        }
    }

    private func connect() {
        guard running, connection == nil else { return }
        switch open() {
        case .success(let opened):
            connection = opened
            beginHandshake(opened)
        case .failure(let error):
            lost(error)
        }
    }

    private func open() -> Result<Connection, MicroLightingError> {
        let devices = findDevices()
        guard !devices.isEmpty else { return .failure(.disconnected) }
        let preferred = devices[rotation % devices.count]
        let options = IOOptionBits(kIOHIDOptionsTypeNone)
        let result = IOHIDDeviceOpen(preferred, options)
        guard result == kIOReturnSuccess else {
            return .failure(
                result == kIOReturnNotPermitted ? .permissionDenied : .transport
            )
        }
        let companions = devices
            .filter { $0 !== preferred }
            .filter { IOHIDDeviceOpen($0, options) == kIOReturnSuccess }
        let handles = ([preferred] + companions).map { HIDHandle(device: $0) }
        let bluetooth = (
            IOHIDDeviceGetProperty(preferred, kIOHIDTransportKey as CFString) as? String
        )?.localizedCaseInsensitiveContains("Bluetooth") == true
        let opened = Connection(handles: handles, bluetooth: bluetooth)
        handles.enumerated().forEach { offset, handle in
            activate(handle, readsVendorReports: offset == 0)
        }
        return .success(opened)
    }

    private func activate(_ handle: HIDHandle, readsVendorReports: Bool) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if readsVendorReports {
            IOHIDDeviceRegisterInputReportCallback(
                handle.device,
                handle.reportBuffer,
                Self.reportBufferSize,
                { context, result, _, _, reportID, bytes, count in
                    guard
                        result == kIOReturnSuccess,
                        reportID == CodexMicroTransport.vendorReportID,
                        count > 0,
                        count <= CodexMicroTransport.reportBufferSize,
                        let context
                    else { return }
                    let transport = Unmanaged<CodexMicroTransport>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                    transport.received(
                        Array(UnsafeBufferPointer(start: bytes, count: count))
                    )
                },
                context
            )
            IOHIDDeviceRegisterRemovalCallback(
                handle.device,
                { context, _, _ in
                    guard let context else { return }
                    let transport = Unmanaged<CodexMicroTransport>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                    transport.lost(.disconnected)
                },
                context
            )
        }
        IOHIDDeviceRegisterInputValueCallback(
            handle.device,
            { context, result, _, value in
                guard result == kIOReturnSuccess, let context else { return }
                let element = IOHIDValueGetElement(value)
                let transport = Unmanaged<CodexMicroTransport>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                transport.keyboardValue(
                    usagePage: Int(IOHIDElementGetUsagePage(element)),
                    usage: Int(IOHIDElementGetUsage(element)),
                    act: IOHIDValueGetIntegerValue(value)
                )
            },
            context
        )
        IOHIDDeviceSetDispatchQueue(handle.device, queue)
        IOHIDDeviceSetCancelHandler(handle.device) {
            IOHIDDeviceClose(handle.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        IOHIDDeviceActivate(handle.device)
    }

    private func beginHandshake(_ opened: Connection) {
        guard
            let id = send(
                method: MicroHIDProtocol.statusMethod,
                parameters: nil,
                over: opened
            )
        else { return lost(.transport) }
        statusRequestID = id
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self] in
            guard let self, statusRequestID == id else { return }
            rotation += 1
            lost(.timeout)
        }
    }

    private func received(_ report: [UInt8]) {
        guard let connection else { return }
        connection.parser.receive(report).forEach { message in
            switch message {
            case .reply(let reply): replied(reply)
            case .notification(let input): onEvent(.input(input))
            }
        }
    }

    private func replied(_ reply: MicroReply) {
        guard reply.id == statusRequestID else {
            guard !reply.succeeded else { return }
            applied = nil
            onEvent(.status(.rejected))
            return
        }
        statusRequestID = nil
        guard reply.succeeded, reply.version != nil else { return lost(.rejected) }
        connection?.isReady = true
        failures = 0
        onEvent(.status(nil))
        flush()
    }

    private func keyboardValue(
        usagePage: Int,
        usage: Int,
        act: Int
    ) {
        guard Self.keyboardUsagePages.contains(usagePage) else { return }
        onEvent(
            .input(
                .keyboard(
                    usagePage: usagePage,
                    usage: usage,
                    act: act
                )
            )
        )
    }

    private func flush() {
        guard
            running,
            let connection,
            connection.isReady,
            let picture = lock.withLock({ desired })
        else { return }
        let commands = MicroWritePlan.commands(for: picture, after: applied)
        guard !commands.isEmpty else { return }
        guard commands.allSatisfy({ send($0, over: connection) != nil }) else {
            return lost(.transport)
        }
        applied = picture
    }

    private func clearLights() {
        guard let connection, connection.isReady, let applied else { return }
        let commands = MicroWritePlan.commands(for: .allOff, after: applied)
        _ = commands.allSatisfy { send($0, over: connection) != nil }
    }

    private func send(_ command: MicroCommand, over connection: Connection) -> Int? {
        send(
            method: MicroHIDProtocol.method(for: command),
            parameters: MicroHIDProtocol.parameters(for: command),
            over: connection
        )
    }

    private func send(
        method: String,
        parameters: Any?,
        over connection: Connection
    ) -> Int? {
        nextRequestID = nextRequestID % 998 + 1
        let id = nextRequestID
        guard
            let device = connection.vendorDevice,
            let reports = try? MicroHIDProtocol.reports(
                method: method,
                parameters: parameters,
                id: id,
                bluetooth: connection.bluetooth
            ),
            reports.allSatisfy({ write($0, to: device) })
        else { return nil }
        return id
    }

    private func write(_ report: [UInt8], to device: IOHIDDevice) -> Bool {
        let result = report.withUnsafeBufferPointer { buffer -> IOReturn in
            guard let base = buffer.baseAddress else { return kIOReturnError }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(Self.vendorReportID),
                base,
                buffer.count
            )
        }
        return result == kIOReturnSuccess
    }

    private func lost(_ error: MicroLightingError) {
        teardown()
        onEvent(.status(error))
        scheduleReconnect()
    }

    private func teardown() {
        connection?.handles.forEach { IOHIDDeviceCancel($0.device) }
        connection = nil
        applied = nil
        statusRequestID = nil
    }

    private func scheduleReconnect() {
        guard running else { return }
        retry?.cancel()
        let delay = min(
            Self.maximumBackoffSeconds,
            Self.initialBackoffSeconds << failures
        )
        failures = min(failures + 1, Self.maximumBackoffExponent)
        let item = DispatchWorkItem { [weak self] in self?.connect() }
        retry = item
        queue.asyncAfter(deadline: .now() + .seconds(delay), execute: item)
    }

    private func findDevices() -> [IOHIDDevice] {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching("IOHIDDevice"),
                &iterator
            ) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        let candidates = sequence(state: iterator) { iterator -> io_service_t? in
            let service = IOIteratorNext(iterator)
            return service == 0 ? nil : service
        }
        .compactMap { service -> IOHIDDevice? in
            defer { IOObjectRelease(service) }
            return microDevice(for: service)
        }
        let usb = candidates.filter { transport(of: $0) == "USB" }
        let others = candidates.filter { transport(of: $0) != "USB" }
        return usb + others
    }

    private func microDevice(for service: io_service_t) -> IOHIDDevice? {
        guard
            let device = IOHIDDeviceCreate(kCFAllocatorDefault, service),
            integerProperty(kIOHIDVendorIDKey, of: device) == Self.vendorID,
            integerProperty(kIOHIDProductIDKey, of: device) == Self.productID
        else { return nil }
        return device
    }

    private func integerProperty(_ key: String, of device: IOHIDDevice) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private func transport(of device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
    }
}
