import Foundation
import IOKit.hid

let wcopyVendorID = 0x0416
let supportedProductIDs = [0xB008, 0xB030]

struct HIDDeviceDescriptor: Identifiable {
    let id: UInt64
    let device: IOHIDDevice
    let vendorID: Int
    let productID: Int
    let productName: String
    let manufacturer: String
    let serialNumber: String
    let transport: String
    let usagePage: Int
    let usage: Int
    let maxInputReportSize: Int
    let maxOutputReportSize: Int

    var usbID: String { String(format: "%04X:%04X", vendorID, productID) }
    var protocolStatus: String {
        productID == 0xB030 ? "上游已验证" : "需要运行时握手"
    }
}

enum HIDDeviceScanner {
    static func scan() -> [HIDDeviceDescriptor] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = supportedProductIDs.map { productID in
            [
                kIOHIDVendorIDKey as String: wcopyVendorID,
                kIOHIDProductIDKey as String: productID
            ]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let deviceSet = IOHIDManagerCopyDevices(manager) else {
            return []
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let devices = deviceSet as NSSet
        return devices.compactMap { object -> HIDDeviceDescriptor? in
            guard let device = object as! IOHIDDevice? else { return nil }
            let vendor = integerProperty(device, kIOHIDVendorIDKey)
            let product = integerProperty(device, kIOHIDProductIDKey)
            guard vendor == wcopyVendorID, supportedProductIDs.contains(product) else { return nil }

            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
            let inputSize = integerProperty(device, kIOHIDMaxInputReportSizeKey)
            let outputSize = integerProperty(device, kIOHIDMaxOutputReportSizeKey)
            guard inputSize >= 64, outputSize >= 64 else { return nil }

            return HIDDeviceDescriptor(
                id: registryID,
                device: device,
                vendorID: vendor,
                productID: product,
                productName: stringProperty(device, kIOHIDProductKey, fallback: "wCopy Smart Reader"),
                manufacturer: stringProperty(device, kIOHIDManufacturerKey, fallback: "Winbond / wCopy"),
                serialNumber: stringProperty(device, kIOHIDSerialNumberKey, fallback: "未提供"),
                transport: stringProperty(device, kIOHIDTransportKey, fallback: "USB"),
                usagePage: integerProperty(device, kIOHIDPrimaryUsagePageKey),
                usage: integerProperty(device, kIOHIDPrimaryUsageKey),
                maxInputReportSize: inputSize,
                maxOutputReportSize: outputSize
            )
        }.sorted { lhs, rhs in
            if lhs.productID != rhs.productID { return lhs.productID < rhs.productID }
            return lhs.id < rhs.id
        }
    }

    private static func integerProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String, fallback: String) -> String {
        (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? fallback
    }
}

protocol HIDTransportProtocol: AnyObject {
    func write(_ report: Data) throws
    func read(timeout: TimeInterval) throws -> Data?
    func drain()
    func close()
}

final class HIDTransport: HIDTransportProtocol {
    private let descriptor: HIDDeviceDescriptor
    private let condition = NSCondition()
    private let ioLock = NSLock()
    private var reports: [Data] = []
    private var isOpen = false
    private var callbackResult: IOReturn = kIOReturnSuccess
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputCapacity: Int

    init(descriptor: HIDDeviceDescriptor) throws {
        self.descriptor = descriptor
        inputCapacity = max(descriptor.maxInputReportSize, 64)
        inputBuffer = .allocate(capacity: inputCapacity)
        inputBuffer.initialize(repeating: 0, count: inputCapacity)

        let result = IOHIDDeviceOpen(descriptor.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            inputBuffer.deallocate()
            throw AppError.transport("无法打开 HID 接口（IOReturn \(String(format: "0x%08X", result))）。请关闭占用设备的软件后重试。")
        }
        isOpen = true

        onMainThread {
            IOHIDDeviceRegisterInputReportCallback(
                descriptor.device,
                inputBuffer,
                inputCapacity,
                Self.inputCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
            IOHIDDeviceScheduleWithRunLoop(
                descriptor.device,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
        }
    }

    deinit {
        close()
        inputBuffer.deinitialize(count: inputCapacity)
        inputBuffer.deallocate()
    }

    func write(_ report: Data) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        condition.lock()
        let open = isOpen
        condition.unlock()
        guard open else { throw AppError.transport("HID 设备已关闭") }
        guard report.count == 64 else { throw AppError.operation("HID 输出报告必须为 64 字节") }
        let result: IOReturn = report.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                descriptor.device,
                kIOHIDReportTypeOutput,
                0,
                base,
                report.count
            )
        }
        guard result == kIOReturnSuccess else {
            throw AppError.transport("写入 HID 报告失败（IOReturn \(String(format: "0x%08X", result))）")
        }
    }

    func read(timeout: TimeInterval) throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while reports.isEmpty && isOpen && callbackResult == kIOReturnSuccess {
            if !condition.wait(until: deadline) { break }
        }
        if callbackResult != kIOReturnSuccess {
            throw AppError.transport("读取 HID 报告失败（IOReturn \(String(format: "0x%08X", callbackResult))）")
        }
        guard !reports.isEmpty else { return nil }
        return reports.removeFirst()
    }

    func drain() {
        condition.lock()
        reports.removeAll()
        condition.unlock()
    }

    func close() {
        ioLock.lock()
        defer { ioLock.unlock() }
        condition.lock()
        let shouldClose = isOpen
        isOpen = false
        reports.removeAll()
        condition.broadcast()
        condition.unlock()
        guard shouldClose else { return }
        onMainThread {
            IOHIDDeviceUnscheduleFromRunLoop(
                descriptor.device,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            IOHIDDeviceClose(descriptor.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    private func receive(result: IOReturn, report: UnsafeMutablePointer<UInt8>, length: Int) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        callbackResult = result
        guard result == kIOReturnSuccess, isOpen, length > 0 else { return }
        var data = Data(bytes: report, count: length)
        if data.count == 65 && data.first == 0 { data.removeFirst() }
        reports.append(data)
    }

    private static let inputCallback: IOHIDReportCallback = {
        context, result, _, _, _, report, reportLength in
        guard let context else { return }
        let transport = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
        transport.receive(result: result, report: report, length: reportLength)
    }

    private func onMainThread(_ work: () -> Void) {
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.sync(execute: work) }
    }
}
