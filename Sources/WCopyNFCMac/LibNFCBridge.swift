import Darwin
import Foundation

final class LibNFCBridge {
    private static let ack = Data([0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00])
    private let reader: WCopyReader
    private let logger: (String) -> Void

    init(reader: WCopyReader, logger: @escaping (String) -> Void) {
        self.reader = reader
        self.logger = logger
    }

    func run(command: [String], token: CancellationToken? = nil) throws -> Int32 {
        guard !command.isEmpty else { throw AppError.operation("未指定 libnfc 命令") }
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard openpty(&master, &slave, &name, nil, nil) == 0 else {
            throw AppError.operation("无法创建 libnfc 虚拟串口：\(String(cString: strerror(errno)))")
        }
        var terminalSettings = termios()
        if tcgetattr(slave, &terminalSettings) == 0 {
            cfmakeraw(&terminalSettings)
            _ = tcsetattr(slave, TCSANOW, &terminalSettings)
        }
        let slavePath = String(cString: name)
        defer { close(slave); close(master) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        var environment = ProcessInfo.processInfo.environment
        environment["LIBNFC_DEFAULT_DEVICE"] = "pn532_uart:\(slavePath)"
        environment["LIBNFC_LOG_LEVEL"] = environment["LIBNFC_LOG_LEVEL"] ?? "1"
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [logger] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            logger(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }

        do { try process.run() }
        catch {
            throw AppError.operation("无法启动 \(command[0])。请先通过 Homebrew 安装 libnfc/mfoc：\(error.localizedDescription)")
        }
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        logger("libnfc PTY: \(slavePath)")
        logger("libnfc 桥接已启动：\(command.joined(separator: " "))")

        var buffer = Data()

        while process.isRunning {
            do { try token?.check() }
            catch {
                process.terminate()
                process.waitUntilExit()
                throw error
            }

            var pollDescriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, 100)
            if ready < 0 {
                logger("BRIDGE POLL error: \(String(cString: strerror(errno)))")
                break
            }
            if (pollDescriptor.revents & Int16(POLLHUP)) != 0 {
                logger("BRIDGE POLL HUP: PTY master hung up")
                break
            }
            if ready > 0 && (pollDescriptor.revents & Int16(POLLIN)) != 0 {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(master, &bytes, bytes.count)
                if count > 0 {
                    let preview = bytes.prefix(min(count, 32)).map { String(format: "%02X", $0) }.joined(separator: " ")
                    logger("BRIDGE READ \(count) bytes: \(preview)")
                    buffer.append(contentsOf: bytes.prefix(count))
                } else if count == 0 {
                    logger("BRIDGE READ EOF: PTY closed")
                    break
                }
            }

            if buffer.range(of: Data([0x00, 0x00, 0xFF])) == nil, buffer.count > 2 {
                buffer = buffer.suffix(2)
            }

            while let parsed = Self.nextFrame(from: buffer) {
                buffer = parsed.remaining
                guard !parsed.payload.isEmpty else { continue }
                try Self.writeAll(Self.ack, to: master)
                let response = try response(for: parsed.payload)
                try Self.writeAll(Self.buildFrame(response), to: master)
            }
        }
        process.waitUntilExit()
        logger("libnfc 命令结束，退出码 \(process.terminationStatus)")
        return process.terminationStatus
    }

    static func buildFrame(_ payload: Data) -> Data {
        let length = UInt8(payload.count)
        let lcs = UInt8(0) &- length
        let dcs = payload.reduce(UInt8(0), &+) == 0 ? UInt8(0) : UInt8(0) &- payload.reduce(UInt8(0), &+)
        var frame = Data([0x00, 0x00, 0xFF, length, lcs])
        frame.append(payload)
        frame.append(dcs)
        frame.append(0x00)
        return frame
    }

    static func nextFrame(from buffer: Data) -> (payload: Data, remaining: Data)? {
        let marker = Data([0x00, 0x00, 0xFF])
        guard let markerRange = buffer.range(of: marker) else { return nil }
        let start = markerRange.lowerBound
        guard buffer.count >= start + 5 else { return nil }
        let length = Int(buffer[start + 3])
        let frameLength = length == 0 ? 6 : 7 + length
        guard buffer.count >= start + frameLength else { return nil }
        let payload = length == 0
            ? Data()
            : buffer.subdata(in: (start + 5)..<(start + 5 + length))
        return (payload, buffer.subdata(in: (start + frameLength)..<buffer.count))
    }

    private func response(for payload: Data) throws -> Data {
        let command = payload.count > 1 ? payload[1] : 0xFF
        var response: Data
        if command == 0x00, payload.count > 2, payload[2] == 0x00 {
            response = Data([0xD5, 0x01]) + payload.dropFirst(2)
            logger("PN532 Diagnose：本地应答")
        } else {
            switch command {
            case 0x14: response = Data([0xD5, 0x15])
            case 0x52: response = Data([0xD5, 0x53, 0x00])
            case 0x16: response = Data([0xD5, 0x17, 0x00])
            default: response = try reader.rawPN532(payload)
            }
        }
        if response.suffix(2) == Data([0x90, 0x00]) { response.removeLast(2) }
        if command == 0x4A {
            let hex = response.map { String(format: "%02X", $0) }.joined(separator: " ")
            logger("libnfc InListPassiveTarget raw response (\(response.count)B): \(hex)")
            let normalized = Self.normalizeSAK19ForLegacyLibNFC(response)
            if normalized != response {
                logger("libnfc 兼容：仅向旧工具将 SAK 19 报告为 Classic 1K SAK 08")
                response = normalized
            }
        }
        return response
    }

    static func normalizeSAK19ForLegacyLibNFC(_ response: Data) -> Data {
        guard response.count >= 12,
              response[0] == 0xD5,
              response[1] == 0x4B,
              response[2] > 0,
              response[4] == 0x00,
              response[5] == 0x04,
              response[6] == 0x19,
              response[7] == 0x04 else {
            return response
        }
        var normalized = response
        normalized[6] = 0x08
        return normalized
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw AppError.operation("虚拟串口写入失败：\(String(cString: strerror(errno)))")
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
    }
}
