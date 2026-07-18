import AppKit
import Combine
import Foundation

enum NavigationPage: String, CaseIterable, Identifiable {
    case overview = "概览"
    case read = "读取与备份"
    case keys = "密钥检查"
    case restore = "恢复转储"
    case uid = "UID 工具"
    case format = "格式化"
    case libnfc = "libnfc 桥接"
    case diagnostics = "诊断"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .read: return "wave.3.right.circle"
        case .keys: return "key.horizontal"
        case .restore: return "square.and.arrow.down.on.square"
        case .uid: return "number.square"
        case .format: return "eraser"
        case .libnfc: return "point.3.connected.trianglepath.dotted"
        case .diagnostics: return "stethoscope"
        }
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case incompatible

    var title: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "正在连接"
        case .connected: return "协议就绪"
        case .incompatible: return "协议未通过"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var page: NavigationPage = .overview
    @Published var devices: [HIDDeviceDescriptor] = []
    @Published var selectedDeviceID: UInt64?
    @Published var connectionState: ConnectionState = .disconnected
    @Published var firmware = "-"
    @Published var readerSerial = "-"
    @Published var sequence = "-"
    @Published var busy = false
    @Published var progress = 0.0
    @Published var operationText = ""
    @Published var operationCancellable = true
    @Published var logText = ""
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published var readResult: ReadResult?
    @Published var activeDump: DumpDocument?
    @Published var importedDump: DumpDocument?
    @Published var keyResults: [Int: SectorKeyResult] = [:]
    @Published var keyCheckAttempts = 0
    @Published var keyCandidateCount = 0
    @Published var rawResponse = ""

    private let operationQueue = DispatchQueue(label: "app.wcopy.nfc.operation", qos: .userInitiated)
    private var reader: WCopyReader?
    private var cancellationToken: CancellationToken?

    var selectedDevice: HIDDeviceDescriptor? {
        guard let selectedDeviceID else { return nil }
        return devices.first { $0.id == selectedDeviceID }
    }

    var canOperate: Bool { connectionState == .connected && !busy }

    func refreshDevices() {
        guard !busy else { return }
        let previous = selectedDeviceID
        devices = HIDDeviceScanner.scan()
        if let previous, devices.contains(where: { $0.id == previous }) {
            selectedDeviceID = previous
        } else {
            selectedDeviceID = devices.first?.id
            if connectionState == .connected { disconnect() }
        }
    }

    func connect() {
        guard !busy, let descriptor = selectedDevice else {
            errorMessage = AppError.noDevice.localizedDescription
            return
        }
        disconnect()
        let transport: HIDTransport
        do { transport = try HIDTransport(descriptor: descriptor) }
        catch { errorMessage = error.localizedDescription; return }

        let newReader = WCopyReader(transport: transport, logger: appendLog)
        reader = newReader
        connectionState = .connecting
        startOperation(label: "连接读卡器", allowDisconnected: true) { [weak self] token in
            try newReader.sync(progress: { value in self?.updateProgress(value, text: "同步设备协议") }, token: token)
            let info = try newReader.initialize()
            Task { @MainActor [weak self] in
                self?.firmware = info.firmware
                self?.readerSerial = info.serial
                self?.sequence = String(format: "0x%04X", info.sequence)
                self?.connectionState = .connected
                self?.noticeMessage = descriptor.productID == 0xB008
                    ? "0416:B008 已通过 wCopy/PN532 协议握手"
                    : "读卡器已连接"
            }
        } failure: { [weak self] error in
            self?.reader?.close()
            self?.reader = nil
            self?.connectionState = .incompatible
            self?.errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        guard !busy else { return }
        cancellationToken?.cancel()
        reader?.close()
        reader = nil
        connectionState = .disconnected
        firmware = "-"
        readerSerial = "-"
        sequence = "-"
    }

    func cancelOperation() { cancellationToken?.cancel() }

    func readCard(
        key: String,
        keyType: KeyType,
        readAll: Bool,
        sectors: String,
        scanMode: CardScanMode
    ) {
        guard let reader else { errorMessage = AppError.notConnected.localizedDescription; return }
        readResult = nil
        activeDump = nil
        startOperation(label: "读取卡片") { [weak self] token in
            let requested = readAll ? nil : try parseSectors(sectors)
            let result = try reader.readCard(
                keyHex: key,
                keyType: keyType,
                sectors: requested,
                scanMode: scanMode,
                progress: { value, text in self?.updateProgress(value, text: text) },
                token: token
            )
            let dump = result.dump(key: key.uppercased(), keyType: keyType)
            Task { @MainActor [weak self] in
                self?.readResult = result
                self?.activeDump = dump
                let failures = result.failedSectors.count + result.failedBlocks.count
                self?.noticeMessage = failures == 0
                    ? "已读取 \(result.blocks.count) 个块"
                    : "读取完成，但有 \(result.failedSectors.count) 个认证失败扇区、\(result.failedBlocks.count) 个读取失败块"
            }
        }
    }

    func checkKeys(
        preset: KeyDictionaryPreset,
        customKeys: [String],
        scanMode: CardScanMode
    ) {
        guard let reader else { errorMessage = AppError.notConnected.localizedDescription; return }
        let candidates = MifareKeyDictionary.merged([preset.keys, customKeys])
        keyResults = [:]
        keyCheckAttempts = 0
        keyCandidateCount = candidates.count
        readResult = nil
        activeDump = nil
        startOperation(label: "检查常用密钥") { [weak self] token in
            let outcome = try reader.checkKeys(
                candidates: candidates,
                scanMode: scanMode,
                progress: { value, text in self?.updateProgress(value, text: text) },
                token: token
            )
            let target = outcome.target
            let results = outcome.sectorKeys
            let readResult = ReadResult(
                target: target,
                blocks: outcome.blocks,
                failedSectors: results.values.filter { !$0.foundAny }.map(\.sector),
                failedBlocks: outcome.failedBlocks
            )
            let defaultAuth = results.values.sorted { $0.sector < $1.sector }.compactMap { result -> (String, KeyType)? in
                if let keyA = result.keyA { return (keyA, .a) }
                if let keyB = result.keyB, result.keyBAuthenticates != false { return (keyB, .b) }
                return nil
            }.first
            let dump = defaultAuth.map {
                readResult.dump(key: $0.0, keyType: $0.1, sectorKeys: results)
            }
            Task { @MainActor [weak self] in
                self?.keyResults = results
                self?.keyCheckAttempts = outcome.attempts
                self?.keyCandidateCount = outcome.candidateCount
                self?.readResult = readResult
                self?.activeDump = dump
                let foundSlots = results.values.reduce(0) { $0 + ($1.keyA == nil ? 0 : 1) + ($1.keyB == nil ? 0 : 1) }
                self?.noticeMessage = "完成 \(outcome.attempts) 次认证，找到 \(foundSlots)/\(results.count * 2) 个密钥槽"
            }
        }
    }

    func pasteSectorKey(_ clipboardValue: String, sector: Int, type: KeyType) {
        guard let reader else { errorMessage = AppError.notConnected.localizedDescription; return }
        guard let target = readResult?.target, var result = keyResults[sector] else {
            errorMessage = "请先运行密钥检查"
            return
        }
        if type == .b, result.keyBAuthenticates == false {
            errorMessage = "扇区 \(sector) 的 Key B 字段是 DATA，不能用于 Key B 认证"
            return
        }
        let key: String
        do { key = try normalizeMifareKey(clipboardValue) }
        catch { errorMessage = AppError.invalidKey.localizedDescription; return }

        startOperation(label: "验证扇区 \(sector) Key \(type.rawValue)") { [weak self] token in
            guard try reader.verifySectorKey(
                keyHex: key,
                sector: sector,
                type: type,
                target: target,
                token: token
            ) else {
                throw AppError.operation("粘贴的密钥无法认证扇区 \(sector) Key \(type.rawValue)，未保存")
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if type == .a {
                    result.keyA = key
                } else {
                    result.keyB = key
                    result.keyBAuthenticates = true
                }
                self.keyResults[sector] = result
                self.keyCheckAttempts += 1
                self.rebuildActiveDumpFromKeyResults()
                self.noticeMessage = "扇区 \(sector) Key \(type.rawValue) 已验证并保存"
            }
        }
    }

    func downloadDictionary(
        _ source: OnlineKeyDictionarySource,
        completion: @escaping (Result<DownloadedKeyDictionary, Error>) -> Void
    ) {
        guard !busy else { return }
        let request = URLRequest(url: source.url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<DownloadedKeyDictionary, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(AppError.operation("词典服务器返回 HTTP \(http.statusCode)"))
            } else if let data, let text = String(data: data, encoding: .utf8) {
                let parsed = MifareKeyDictionary.parse(text)
                result = .success(DownloadedKeyDictionary(source: source, text: text, parsed: parsed))
            } else {
                result = .failure(AppError.operation("下载内容不是有效 UTF-8 文本"))
            }
            Task { @MainActor in completion(result) }
        }.resume()
    }

    func restoreDump(options: RestoreOptions, scanMode: CardScanMode) {
        guard let reader else { errorMessage = AppError.notConnected.localizedDescription; return }
        guard let dump = importedDump else { errorMessage = "请先导入 JSON 或 MFD 转储"; return }
        startOperation(label: "恢复转储", cancellable: false) { [weak self] token in
            let result = try reader.restore(
                dump: dump,
                options: options,
                scanMode: scanMode,
                progress: { value, text in self?.updateProgress(value, text: text) },
                token: token
            )
            Task { @MainActor [weak self] in
                self?.noticeMessage = "恢复完成：写入 \(result.written) 块，失败 \(result.failed.count) 块，安全跳过 \(result.skipped) 块"
            }
        }
    }

    func writeUID(uid: String, key: String) {
        guard let reader else { errorMessage = AppError.notConnected.localizedDescription; return }
        startOperation(label: "写入 UID", cancellable: false) { [weak self] token in
            let uidData: Data
            do { uidData = try HexCodec.data(from: uid, expectedBytes: 4) }
            catch { throw AppError.invalidUID }
            _ = try reader.writeUID(newUID: uidData, keyHex: key, token: token)
            Task { @MainActor [weak self] in self?.noticeMessage = "UID 已写入并通过回读验证" }
        }
    }

    func formatCard(
        key: String,
        keyType: KeyType,
        sectors: String,
        gpb: String,
        scanMode: CardScanMode
    ) {
        guard let reader else { errorMessage = AppError.notConnected.localizedDescription; return }
        startOperation(label: "格式化卡片", cancellable: false) { [weak self] token in
            let selectedSectors = try parseSectors(sectors)
            let gpbData = try HexCodec.data(from: gpb, expectedBytes: 1)
            let failed = try reader.format(
                keyHex: key,
                keyType: keyType,
                sectors: selectedSectors,
                gpb: gpbData[0],
                scanMode: scanMode,
                progress: { value, text in self?.updateProgress(value, text: text) },
                token: token
            )
            Task { @MainActor [weak self] in
                self?.noticeMessage = failed.isEmpty ? "卡片格式化完成，UID 块未改动" : "格式化结束，失败扇区：\(failed.map(String.init).joined(separator: ", "))"
            }
        }
    }

    func sendRawCommand(_ hex: String) {
        guard let reader else { errorMessage = AppError.notConnected.localizedDescription; return }
        startOperation(label: "发送 PN532 命令") { [weak self] _ in
            let command = try HexCodec.data(from: hex)
            let readOnlyCommands: Set<UInt8> = [0x02, 0x04, 0x06, 0x4A]
            guard command.count >= 2, command[0] == 0xD4, readOnlyCommands.contains(command[1]) else {
                throw AppError.operation("诊断页只允许 GetFirmwareVersion、GetGeneralStatus、ReadRegister 和 InListPassiveTarget 等只读命令")
            }
            let response = try reader.rawPN532(command)
            Task { @MainActor [weak self] in self?.rawResponse = HexCodec.string(response, separator: " ") }
        }
    }

    func runLibNFC(commandLine: String) {
        guard let reader else { errorMessage = AppError.notConnected.localizedDescription; return }
        guard !commandLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请输入 libnfc 命令"
            return
        }
        let command = [
            "/bin/zsh", "-lc",
            "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; exec \(commandLine)"
        ]
        startOperation(label: "libnfc 桥接") { [weak self] token in
            let bridge = LibNFCBridge(reader: reader, logger: self?.appendLog ?? { _ in })
            let status = try bridge.run(command: command, token: token)
            Task { @MainActor [weak self] in self?.noticeMessage = "libnfc 命令结束，退出码 \(status)" }
        }
    }

    func importDump(from url: URL) {
        guard !busy else { return }
        do {
            let data = try Data(contentsOf: url)
            let dump = url.pathExtension.lowercased() == "mfd"
                ? try DumpDocument.fromMFD(data)
                : try DumpDocument.fromJSON(data)
            importedDump = dump
            noticeMessage = "已导入 \(dump.blocks.count) 个块"
        } catch {
            importedDump = nil
            errorMessage = error.localizedDescription
        }
    }

    func exportActiveDump(to url: URL, mfd: Bool) {
        guard let dump = activeDump else { errorMessage = "当前没有可导出的读取结果"; return }
        do {
            let data = mfd ? try dump.mfdData() : try dump.jsonData()
            try data.write(to: url, options: .atomic)
            noticeMessage = "转储已保存到 \(url.lastPathComponent)"
        } catch { errorMessage = error.localizedDescription }
    }

    func diagnosticsText() -> String {
        let device = selectedDevice
        return """
        wCopy NFC for Mac diagnostics
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Device: \(device?.productName ?? "not found")
        USB ID: \(device?.usbID ?? "-")
        HID usage: \(String(format: "%04X:%04X", device?.usagePage ?? 0, device?.usage ?? 0))
        Reports: IN \(device?.maxInputReportSize ?? 0) / OUT \(device?.maxOutputReportSize ?? 0)
        Connection: \(connectionState.title)
        Firmware: \(firmware)
        Reader serial: \(readerSerial)
        Sequence: \(sequence)

        \(logText)
        """
    }

    func clearLog() { logText = "" }

    nonisolated private func appendLog(_ message: String) {
        guard !message.isEmpty else { return }
        Task { @MainActor [weak self] in
            let stamp = Date.now.formatted(date: .omitted, time: .standard)
            self?.logText += "[\(stamp)] \(message)\n"
        }
    }

    nonisolated private func updateProgress(_ value: Double, text: String) {
        Task { @MainActor [weak self] in
            self?.progress = min(max(value, 0), 1)
            self?.operationText = text
        }
    }

    private func startOperation(
        label: String,
        allowDisconnected: Bool = false,
        cancellable: Bool = true,
        work: @escaping (CancellationToken) throws -> Void,
        failure: ((Error) -> Void)? = nil
    ) {
        guard !busy else { return }
        if !allowDisconnected && connectionState != .connected {
            errorMessage = AppError.notConnected.localizedDescription
            return
        }
        let token = CancellationToken()
        cancellationToken = token
        busy = true
        operationCancellable = cancellable
        progress = 0
        operationText = label
        appendLog("开始：\(label)")
        operationQueue.async { [weak self] in
            do {
                try work(token)
                Task { @MainActor [weak self] in
                    self?.finishOperation()
                }
            } catch {
                Task { @MainActor [weak self] in
                    if let failure { failure(error) }
                    else if case AppError.cancelled = error { self?.noticeMessage = "操作已取消" }
                    else { self?.errorMessage = error.localizedDescription }
                    if case AppError.transport = error {
                        self?.reader?.close()
                        self?.reader = nil
                        self?.connectionState = .disconnected
                        self?.firmware = "-"
                        self?.readerSerial = "-"
                        self?.sequence = "-"
                    } else if error is MutationError {
                        self?.reader?.close()
                        self?.reader = nil
                        self?.connectionState = .disconnected
                        self?.firmware = "-"
                        self?.readerSerial = "-"
                        self?.sequence = "-"
                    }
                    self?.appendLog("失败：\(error.localizedDescription)")
                    self?.finishOperation()
                }
            }
        }
    }

    private func finishOperation() {
        busy = false
        progress = 0
        operationText = ""
        operationCancellable = true
        cancellationToken = nil
        if let reader { sequence = String(format: "0x%04X", reader.sequence ?? 0) }
    }

    private func rebuildActiveDumpFromKeyResults() {
        guard let readResult else { return }
        let authentication = keyResults.values.sorted { $0.sector < $1.sector }.compactMap { result -> (String, KeyType)? in
            if let keyA = result.keyA { return (keyA, .a) }
            if let keyB = result.keyB, result.keyBAuthenticates != false { return (keyB, .b) }
            return nil
        }.first
        activeDump = authentication.map {
            readResult.dump(key: $0.0, keyType: $0.1, sectorKeys: keyResults)
        }
    }
}
