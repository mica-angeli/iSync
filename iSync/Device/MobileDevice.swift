import Foundation
import Darwin

/// Late-bound access to Apple's private MobileDevice.framework, the library Finder itself uses to
/// talk to iPhones. It provides device discovery (through usbmuxd), pairing, lockdown sessions and
/// TLS-wrapped service connections. Everything above the raw service connection (AFC, the ATC sync
/// protocol) is implemented by iSync itself.
///
/// The framework ships with every copy of macOS, so binding at run time with `dlopen` keeps the app
/// free of private link-time dependencies.
final class MobileDeviceLibrary: @unchecked Sendable {
    typealias NotificationCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    typealias SubscribeFn = @convention(c) (NotificationCallback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    typealias DeviceIntFn = @convention(c) (OpaquePointer) -> Int32
    typealias DeviceRetainFn = @convention(c) (OpaquePointer) -> OpaquePointer?
    typealias DeviceReleaseFn = @convention(c) (OpaquePointer) -> Void
    typealias CopyIdentifierFn = @convention(c) (OpaquePointer) -> Unmanaged<CFString>?
    typealias CopyValueFn = @convention(c) (OpaquePointer, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    typealias StartServiceFn = @convention(c) (OpaquePointer, CFString, CFDictionary?, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    typealias ConnSendFn = @convention(c) (OpaquePointer, UnsafeRawPointer, Int) -> Int
    typealias ConnReceiveFn = @convention(c) (OpaquePointer, UnsafeMutableRawPointer, Int) -> Int
    typealias ConnVoidFn = @convention(c) (OpaquePointer) -> Void
    typealias ConnIntFn = @convention(c) (OpaquePointer) -> Int32
    typealias ErrorTextFn = @convention(c) (Int32) -> Unmanaged<CFString>?

    /// Device notification messages (`am_device_notification_callback_info.msg`).
    enum NotificationMessage: UInt32 {
        case connected = 1
        case disconnected = 2
        case unsubscribed = 3
    }

    /// `AMDeviceGetInterfaceType` values.
    enum InterfaceType: Int32 {
        case unknown = 0
        case usb = 1
        case network = 2
    }

    static let shared: Result<MobileDeviceLibrary, Error> = Result { try MobileDeviceLibrary() }

    private let handle: UnsafeMutableRawPointer

    let notificationSubscribe: SubscribeFn
    let deviceRetain: DeviceRetainFn
    let deviceRelease: DeviceReleaseFn
    let connect: DeviceIntFn
    let disconnect: DeviceIntFn
    let isPaired: DeviceIntFn
    let pair: DeviceIntFn
    let validatePairing: DeviceIntFn
    let startSession: DeviceIntFn
    let stopSession: DeviceIntFn
    let getInterfaceType: DeviceIntFn
    let copyDeviceIdentifier: CopyIdentifierFn
    let copyValue: CopyValueFn
    let secureStartService: StartServiceFn
    let connectionSend: ConnSendFn
    let connectionReceive: ConnReceiveFn
    let connectionInvalidate: ConnVoidFn
    let connectionGetSocket: ConnIntFn
    let copyErrorText: ErrorTextFn?

    static let searchPaths = [
        "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
        "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
    ]

    private init() throws {
        guard let handle = Self.searchPaths.lazy.compactMap({ dlopen($0, RTLD_NOW) }).first else {
            throw ISyncError("Apple's MobileDevice framework could not be loaded. It is part of macOS; try reinstalling the latest macOS update.")
        }
        self.handle = handle

        func symbol<T>(_ name: String) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw ISyncError("MobileDevice.framework does not export \(name).")
            }
            return unsafeBitCast(pointer, to: T.self)
        }

        notificationSubscribe = try symbol("AMDeviceNotificationSubscribe")
        deviceRetain = try symbol("AMDeviceRetain")
        deviceRelease = try symbol("AMDeviceRelease")
        connect = try symbol("AMDeviceConnect")
        disconnect = try symbol("AMDeviceDisconnect")
        isPaired = try symbol("AMDeviceIsPaired")
        pair = try symbol("AMDevicePair")
        validatePairing = try symbol("AMDeviceValidatePairing")
        startSession = try symbol("AMDeviceStartSession")
        stopSession = try symbol("AMDeviceStopSession")
        getInterfaceType = try symbol("AMDeviceGetInterfaceType")
        copyDeviceIdentifier = try symbol("AMDeviceCopyDeviceIdentifier")
        copyValue = try symbol("AMDeviceCopyValue")
        secureStartService = try symbol("AMDeviceSecureStartService")
        connectionSend = try symbol("AMDServiceConnectionSend")
        connectionReceive = try symbol("AMDServiceConnectionReceive")
        connectionInvalidate = try symbol("AMDServiceConnectionInvalidate")
        connectionGetSocket = try symbol("AMDServiceConnectionGetSocket")
        copyErrorText = try? symbol("AMDCopyErrorText")
    }

    func describe(_ code: Int32) -> String {
        let hex = String(format: "0x%08X", UInt32(bitPattern: code))
        if let text = copyErrorText?(code)?.takeRetainedValue() as String?, !text.isEmpty {
            return "\(text) (\(hex))"
        }
        return hex
    }
}

/// Basic identity of a connected iPhone.
struct DeviceInfo: Equatable, Sendable {
    var name: String
    var productType: String
    var productVersion: String
    var deviceClass: String
}

/// One iPhone known to MobileDevice. All lockdown traffic for a device is serialised.
final class AppleDevice: @unchecked Sendable, Identifiable {
    let udid: String
    let interface: MobileDeviceLibrary.InterfaceType
    var id: String { udid }

    private let ref: OpaquePointer
    private let md: MobileDeviceLibrary
    private let lock = NSRecursiveLock()

    init(ref: OpaquePointer, library: MobileDeviceLibrary) {
        self.md = library
        self.ref = library.deviceRetain(ref) ?? ref
        self.udid = (library.copyDeviceIdentifier(ref)?.takeRetainedValue() as String?) ?? "unknown"
        self.interface = MobileDeviceLibrary.InterfaceType(rawValue: library.getInterfaceType(ref)) ?? .unknown
    }

    deinit {
        md.deviceRelease(ref)
    }

    func refersTo(_ other: OpaquePointer) -> Bool { ref == other }

    private func check(_ code: Int32, _ action: String) throws {
        guard code == 0 else {
            throw ISyncError("Could not \(action): \(md.describe(code)).")
        }
    }

    /// Connects to lockdown, validates pairing and opens a session for the duration of `body`.
    func withLockdownSession<T>(allowPairing: Bool = true, _ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try check(md.connect(ref), "connect to the iPhone")
        defer { _ = md.disconnect(ref) }
        if md.isPaired(ref) == 0 {
            guard allowPairing else {
                throw ISyncError("This iPhone is not paired with this Mac.")
            }
            logInfo("Device \(udid) is not paired with this Mac; requesting pairing")
            let code = md.pair(ref)
            guard code == 0 else {
                throw ISyncError("This iPhone does not trust this Mac yet. Unlock the iPhone and tap “Trust”, then try again. (\(md.describe(code)))")
            }
        }
        let validation = md.validatePairing(ref)
        guard validation == 0 else {
            throw ISyncError("This iPhone's pairing with this Mac is not valid. Unlock the iPhone and tap “Trust” when asked. (\(md.describe(validation)))")
        }
        let session = md.startSession(ref)
        guard session == 0 else {
            throw ISyncError("Could not start a session with the iPhone. Make sure it is unlocked. (\(md.describe(session)))")
        }
        defer { _ = md.stopSession(ref) }
        return try body()
    }

    /// Reads one lockdown value. Must be called inside `withLockdownSession`.
    func copyValue(domain: String?, key: String?) -> Any? {
        md.copyValue(ref, domain as CFString?, key as CFString?)?.takeRetainedValue()
    }

    func readInfo(allowPairing: Bool = true) throws -> DeviceInfo {
        try withLockdownSession(allowPairing: allowPairing) {
            DeviceInfo(
                name: copyValue(domain: nil, key: "DeviceName") as? String ?? "iPhone",
                productType: copyValue(domain: nil, key: "ProductType") as? String ?? "",
                productVersion: copyValue(domain: nil, key: "ProductVersion") as? String ?? "",
                deviceClass: copyValue(domain: nil, key: "DeviceClass") as? String ?? ""
            )
        }
    }

    /// Opens the phone's media file system through Apple's AFC client.
    func openFileSystem(allowPairing: Bool = true) throws -> PhoneFileSystem {
        guard let service = try startService("com.apple.afc", allowPairing: allowPairing) as? MobileDeviceConnection else {
            throw ISyncError("Could not open the iPhone's file service.")
        }
        return try MobileDeviceAFC(service: service)
    }

    /// Starts a lockdown service and returns its (possibly TLS-wrapped) connection.
    func startService(_ name: String, allowPairing: Bool = true) throws -> ServiceTransport {
        try withLockdownSession(allowPairing: allowPairing) {
            var connection: OpaquePointer?
            let code = md.secureStartService(ref, name as CFString, nil, &connection)
            guard code == 0, let connection else {
                throw ISyncError("The iPhone refused to start \(name): \(md.describe(code)).")
            }
            logDebug("Started service \(name) on \(udid)")
            return MobileDeviceConnection(connection: connection, library: md, name: name)
        }
    }
}

/// Watches usbmuxd for iPhones being attached and detached. Callbacks arrive on the main run loop.
final class DeviceWatcher {
    static let shared = DeviceWatcher()

    var onAttach: ((AppleDevice) -> Void)?
    var onDetach: ((AppleDevice) -> Void)?

    private var subscription: OpaquePointer?
    private var devices: [AppleDevice] = []

    private init() {}

    /// Must be called on the main thread (the notifications are delivered on the calling thread's run loop).
    func start() throws {
        guard subscription == nil else { return }
        let md = try MobileDeviceLibrary.shared.get()
        let callback: MobileDeviceLibrary.NotificationCallback = { info, _ in
            guard let info else { return }
            let device = info.load(fromByteOffset: 0, as: OpaquePointer?.self)
            let message = info.load(fromByteOffset: MemoryLayout<OpaquePointer?>.size, as: UInt32.self)
            DeviceWatcher.shared.handle(device: device, message: message)
        }
        var subscription: OpaquePointer?
        let code = md.notificationSubscribe(callback, 0, 0, nil, &subscription)
        guard code == 0 else {
            throw ISyncError("Could not watch for iPhones: \(md.describe(code)).")
        }
        self.subscription = subscription
        logInfo("Watching for iPhones")
    }

    private func handle(device ref: OpaquePointer?, message: UInt32) {
        guard let ref, let md = try? MobileDeviceLibrary.shared.get() else { return }
        switch MobileDeviceLibrary.NotificationMessage(rawValue: message) {
        case .connected:
            let device = AppleDevice(ref: ref, library: md)
            logInfo("Device attached: \(device.udid) via \(device.interface)")
            devices.append(device)
            onAttach?(device)
        case .disconnected:
            if let index = devices.firstIndex(where: { $0.refersTo(ref) }) {
                let device = devices.remove(at: index)
                logInfo("Device detached: \(device.udid)")
                onDetach?(device)
            }
        default:
            break
        }
    }
}
