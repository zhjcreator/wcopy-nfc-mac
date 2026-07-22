import Foundation

enum CLIExitCode {
    static let success: Int32 = 0
    static let internalError: Int32 = 1
    static let usage: Int32 = 2
    static let noDevice: Int32 = 3
    static let transport: Int32 = 4
    static let noCard: Int32 = 5
    static let operation: Int32 = 6
    static let invalidInput: Int32 = 7
    static let confirmationRequired: Int32 = 8
    static let partialResult: Int32 = 10
    static let cancelled: Int32 = 130
}

enum CLIError: LocalizedError {
    case usage(String)
    case file(String)
    case confirmation(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .file(let message), .confirmation(let message): return message
        }
    }
}

struct CLIOptions {
    private static let booleanOptions: Set<String> = [
        "connect", "force", "help", "include-block0", "include-trailers",
        "no-verify", "pretty", "verbose", "yes", "skip-sector-0"
    ]

    private(set) var values: [String: [String]] = [:]
    private(set) var flags: Set<String> = []
    private(set) var positionals: [String] = []

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                positionals.append(contentsOf: arguments[(index + 1)...])
                break
            }
            if argument == "-h" || argument == "--help" {
                flags.insert("help")
                index += 1
                continue
            }
            guard argument.hasPrefix("--") else {
                positionals.append(argument)
                index += 1
                continue
            }

            let option = String(argument.dropFirst(2))
            if let equals = option.firstIndex(of: "=") {
                let name = String(option[..<equals])
                let value = String(option[option.index(after: equals)...])
                guard !name.isEmpty, !value.isEmpty else {
                    throw CLIError.usage("无效参数：\(argument)")
                }
                values[name, default: []].append(value)
                index += 1
            } else if Self.booleanOptions.contains(option) {
                flags.insert(option)
                index += 1
            } else {
                guard index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("-") else {
                    throw CLIError.usage("参数 --\(option) 缺少值")
                }
                values[option, default: []].append(arguments[index + 1])
                index += 2
            }
        }
    }

    func value(_ name: String) -> String? { values[name]?.last }
    func allValues(_ name: String) -> [String] { values[name] ?? [] }
    func hasFlag(_ name: String) -> Bool { flags.contains(name) }

    func validate(
        valueOptions: Set<String>,
        flagOptions: Set<String>,
        repeatableValueOptions: Set<String> = []
    ) throws {
        let unknownValues = Set(values.keys).subtracting(valueOptions)
        let unknownFlags = flags.subtracting(flagOptions.union(["help"]))
        if let option = unknownValues.union(unknownFlags).sorted().first {
            throw CLIError.usage("未知参数：--\(option)")
        }
        if let positional = positionals.first {
            throw CLIError.usage("意外的位置参数：\(positional)")
        }
        if let option = values.keys.sorted().first(where: {
            !repeatableValueOptions.contains($0) && (values[$0]?.count ?? 0) > 1
        }) {
            throw CLIError.usage("参数 --\(option) 不能重复")
        }
    }
}

struct CLICommandResult {
    let data: [String: Any]
    var exitCode: Int32 = CLIExitCode.success
}

enum WCopyCLI {
    static let schemaVersion = 1
    static let version = "1.3.0"
    private static let deviceValueOptions: Set<String> = ["device-id", "device-index", "sync-radius"]
    private static let commonFlags: Set<String> = ["pretty", "verbose"]
    private static let cancellationToken = CancellationToken()
    private static var lastMutationError: MutationError?

    static func cancel() { cancellationToken.cancel() }

    static func run(arguments: [String]) -> Int32 {
        lastMutationError = nil
        let command = arguments.first ?? "help"
        let rawOptions = Array(arguments.dropFirst())
        if command == "help" || command == "--help" || command == "-h" {
            printHelp(command: rawOptions.first)
            return CLIExitCode.success
        }

        let options: CLIOptions
        do {
            options = try CLIOptions(rawOptions)
            if options.hasFlag("help") {
                printHelp(command: command)
                return CLIExitCode.success
            }
            let result = try execute(command: command, options: options)
            emit(command: command, ok: true, data: result.data, error: nil, pretty: options.hasFlag("pretty"))
            return result.exitCode
        } catch {
            lastMutationError = error as? MutationError
            let failure = classify(error)
            let pretty = (try? CLIOptions(rawOptions).hasFlag("pretty")) ?? false
            emit(command: command, ok: false, data: nil, error: failure, pretty: pretty)
            return failure.exitCode
        }
    }

    static func parseCardMode(_ value: String?) throws -> CardScanMode {
        switch value?.lowercased() ?? "auto" {
        case "auto", "automatic": return .automatic
        case "sak19", "sak19-1k", "compatible1k": return .sak19Classic1K
        case "mini": return .mini
        case "1k", "classic1k": return .classic1K
        case "2k", "classic2k": return .classic2K
        case "4k", "classic4k": return .classic4K
        default: throw CLIError.usage("--card-mode 必须是 auto、sak19、mini、1k、2k 或 4k")
        }
    }

    static func parseKeyType(_ value: String?) throws -> KeyType {
        guard let type = KeyType(rawValue: (value ?? "A").uppercased()) else {
            throw CLIError.usage("--key-type 必须是 A 或 B")
        }
        return type
    }

    private static func execute(command: String, options: CLIOptions) throws -> CLICommandResult {
        switch command {
        case "version": return try versionCommand(options)
        case "capabilities": return try capabilitiesCommand(options)
        case "devices": return try devicesCommand(options)
        case "diagnostics": return try diagnosticsCommand(options)
        case "reader-info": return try readerInfoCommand(options)
        case "card-info": return try cardInfoCommand(options)
        case "read": return try readCommand(options)
        case "keys": return try keysCommand(options)
        case "verify-key": return try verifyKeyCommand(options)
        case "restore": return try restoreCommand(options)
        case "write-uid": return try writeUIDCommand(options)
        case "format": return try formatCommand(options)
        case "pn532": return try pn532Command(options)
        case "bridge": return try bridgeCommand(options)
        default: throw CLIError.usage("未知命令：\(command)。运行 wcopy-nfc help 查看命令。")
        }
    }

    private static func versionCommand(_ options: CLIOptions) throws -> CLICommandResult {
        try options.validate(valueOptions: [], flagOptions: ["pretty"])
        return CLICommandResult(data: ["version": version, "schemaVersion": schemaVersion])
    }

    private static func capabilitiesCommand(_ options: CLIOptions) throws -> CLICommandResult {
        try options.validate(valueOptions: [], flagOptions: ["pretty"])
        return CLICommandResult(data: [
            "version": version,
            "schemaVersion": schemaVersion,
            "platform": "macOS 13+",
            "supportedUSBIDs": ["0416:B008", "0416:B030"],
            "cardModes": ["auto", "sak19", "mini", "1k", "2k", "4k"],
            "commands": [
                commandCapability("devices", mutating: false, hardware: false),
                commandCapability("diagnostics", mutating: false, hardware: false),
                commandCapability("reader-info", mutating: false, hardware: true),
                commandCapability("card-info", mutating: false, hardware: true),
                commandCapability("read", mutating: false, hardware: true),
                commandCapability("keys", mutating: false, hardware: true),
                commandCapability("verify-key", mutating: false, hardware: true),
                commandCapability("restore", mutating: true, hardware: true),
                commandCapability("write-uid", mutating: true, hardware: true),
                commandCapability("format", mutating: true, hardware: true),
                commandCapability("pn532", mutating: false, hardware: true)
            ],
            "output": [
                "format": "JSON",
                "stdout": "one JSON envelope",
                "stderr": "verbose protocol logs only",
                "writeConfirmation": "--yes"
            ],
            "exitCodes": [
                "success": CLIExitCode.success,
                "internal": CLIExitCode.internalError,
                "usage": CLIExitCode.usage,
                "noDevice": CLIExitCode.noDevice,
                "transport": CLIExitCode.transport,
                "noCard": CLIExitCode.noCard,
                "operation": CLIExitCode.operation,
                "invalidInput": CLIExitCode.invalidInput,
                "confirmationRequired": CLIExitCode.confirmationRequired,
                "partialResult": CLIExitCode.partialResult,
                "cancelled": CLIExitCode.cancelled
            ]
        ])
    }

    private static func devicesCommand(_ options: CLIOptions) throws -> CLICommandResult {
        try options.validate(valueOptions: [], flagOptions: ["pretty"])
        let devices = HIDDeviceScanner.scan()
        return CLICommandResult(data: [
            "count": devices.count,
            "devices": devices.enumerated().map { deviceObject($0.element, index: $0.offset) }
        ])
    }

    private static func diagnosticsCommand(_ options: CLIOptions) throws -> CLICommandResult {
        try options.validate(
            valueOptions: deviceValueOptions,
            flagOptions: commonFlags.union(["connect"])
        )
        let devices = HIDDeviceScanner.scan()
        var data: [String: Any] = [
            "cliVersion": version,
            "schemaVersion": schemaVersion,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": architectureName(),
            "deviceCount": devices.count,
            "devices": devices.enumerated().map { deviceObject($0.element, index: $0.offset) }
        ]
        if options.hasFlag("connect") {
            let connected = try withReader(options) { _, descriptor, index, info in
                [
                    "device": deviceObject(descriptor, index: index),
                    "firmware": info.firmware,
                    "serial": info.serial,
                    "sequence": String(format: "0x%04X", info.sequence)
                ] as [String: Any]
            }
            data["reader"] = connected
        }
        return CLICommandResult(data: data)
    }

    private static func readerInfoCommand(_ options: CLIOptions) throws -> CLICommandResult {
        try options.validate(valueOptions: deviceValueOptions, flagOptions: commonFlags)
        let data = try withReader(options) { _, descriptor, index, info in
            [
                "device": deviceObject(descriptor, index: index),
                "firmware": info.firmware,
                "serial": info.serial,
                "sequence": String(format: "0x%04X", info.sequence),
                "protocolReady": true
            ] as [String: Any]
        }
        return CLICommandResult(data: data)
    }

    private static func cardInfoCommand(_ options: CLIOptions) throws -> CLICommandResult {
        try options.validate(
            valueOptions: deviceValueOptions.union(["card-mode"]),
            flagOptions: commonFlags
        )
        let mode = try parseCardMode(options.value("card-mode"))
        let data = try withReader(options) { reader, _, _, _ in
            guard let detected = try reader.selectTarget() else { throw AppError.noCard }
            return ["card": targetObject(target(detected, applying: mode))]
        }
        return CLICommandResult(data: data)
    }

    private static func readCommand(_ options: CLIOptions) throws -> CLICommandResult {
        try options.validate(
            valueOptions: deviceValueOptions.union(["card-mode", "format", "key", "key-file", "key-type", "output", "sectors"]),
            flagOptions: commonFlags.union(["force"])
        )
        try validateOutputOptions(options)
        let key = try requiredKey(options, command: "read")
        let keyType = try parseKeyType(options.value("key-type"))
        let mode = try parseCardMode(options.value("card-mode"))
        let sectors = try options.value("sectors").map { try parseSectors($0) }

        let result = try withReader(options) { reader, _, _, _ in
            try reader.readCard(
                keyHex: key,
                keyType: keyType,
                sectors: sectors,
                scanMode: mode,
                progress: progressLogger(options),
                token: cancellationToken
            )
        }
        let dump = result.dump(key: key, keyType: keyType)
        let partial = !result.failedSectors.isEmpty || !result.failedBlocks.isEmpty
        let output = writeDumpResult(dump, options: options)
        var data: [String: Any] = [
            "card": targetObject(result.target),
            "keyType": keyType.rawValue,
            "requestedSectors": sectors ?? Array(0..<result.target.kind.sectorCount),
            "blockCount": result.blocks.count,
            "blocks": blocksObject(result.blocks),
            "failedSectors": result.failedSectors.sorted(),
            "failedBlocks": result.failedBlocks.sorted(),
            "complete": !partial,
            "output": output.value
        ]
        if let error = output.error { data["outputError"] = error }
        return CLICommandResult(
            data: data,
            exitCode: partial || output.error != nil ? CLIExitCode.partialResult : CLIExitCode.success
        )
    }

    private static func keysCommand(_ options: CLIOptions) throws -> CLICommandResult {
        try options.validate(
            valueOptions: deviceValueOptions.union(["card-mode", "dictionary", "format", "key", "output", "preset"]),
            flagOptions: commonFlags.union(["force"]),
            repeatableValueOptions: ["dictionary", "key"]
        )
        try validateOutputOptions(options)
        let mode = try parseCardMode(options.value("card-mode"))
        let preset = try dictionaryPreset(options.value("preset"))
        var customKeys = try options.allValues("key").map(normalizeMifareKey)
        var dictionaryStats: [[String: Any]] = []
        for path in options.allValues("dictionary") {
            let url = fileURL(path)
            let text: String
            do { text = try String(contentsOf: url, encoding: .utf8) }
            catch { throw CLIError.file("无法读取词典 \(url.path)：\(error.localizedDescription)") }
            let parsed = MifareKeyDictionary.parse(text)
            customKeys.append(contentsOf: parsed.keys)
            dictionaryStats.append([
                "path": url.path,
                "keys": parsed.keys.count,
                "duplicates": parsed.duplicateCount,
                "ignoredLines": parsed.ignoredLines
            ])
        }
        let candidates = MifareKeyDictionary.merged([preset.keys, customKeys])
        let outcome = try withReader(options) { reader, _, _, _ in
            try reader.checkKeys(
                candidates: candidates,
                scanMode: mode,
                progress: progressLogger(options),
                token: cancellationToken
            )
        }
        let sortedResults = outcome.sectorKeys.values.sorted { $0.sector < $1.sector }
        let foundSlots = sortedResults.reduce(0) { $0 + ($1.keyA == nil ? 0 : 1) + ($1.keyB == nil ? 0 : 1) }
        let failedSectors = sortedResults.filter { !$0.foundAny }.map(\.sector)
        let readResult = ReadResult(
            target: outcome.target,
            blocks: outcome.blocks,
            failedSectors: failedSectors,
            failedBlocks: outcome.failedBlocks
        )
        let defaultAuthentication = sortedResults.compactMap { result -> (String, KeyType)? in
            if let keyA = result.keyA { return (keyA, .a) }
            if let keyB = result.keyB, result.keyBAuthenticates != false { return (keyB, .b) }
            return nil
        }.first
        let output: DumpWriteResult
        if options.value("output") != nil {
            if let authentication = defaultAuthentication {
                let dump = readResult.dump(
                    key: authentication.0,
                    keyType: authentication.1,
                    sectorKeys: outcome.sectorKeys
                )
                output = writeDumpResult(dump, options: options)
            } else {
                output = DumpWriteResult(
                    value: NSNull(),
                    error: ["code": "INCOMPLETE_DUMP", "message": "没有找到可认证密钥，无法创建转储"]
                )
            }
        } else {
            output = DumpWriteResult(value: NSNull(), error: nil)
        }

        let partial = foundSlots < sortedResults.count * 2 || !outcome.failedBlocks.isEmpty
        var data: [String: Any] = [
            "card": targetObject(outcome.target),
            "preset": presetName(preset),
            "candidateCount": outcome.candidateCount,
            "authenticationAttempts": outcome.attempts,
            "foundSlots": foundSlots,
            "totalSlots": sortedResults.count * 2,
            "sectorKeys": sortedResults.map(sectorKeyObject),
            "dictionaryFiles": dictionaryStats,
            "blockCount": outcome.blocks.count,
            "blocks": blocksObject(outcome.blocks),
            "failedSectors": failedSectors,
            "failedBlocks": outcome.failedBlocks.sorted(),
            "output": output.value
        ]
        if let error = output.error { data["outputError"] = error }
        return CLICommandResult(
            data: data,
            exitCode: partial || output.error != nil ? CLIExitCode.partialResult : CLIExitCode.success
        )
    }

    private static func verifyKeyCommand(_ options: CLIOptions) throws -> CLICommandResult {
        try options.validate(
            valueOptions: deviceValueOptions.union(["card-mode", "key", "key-file", "key-type", "sector"]),
            flagOptions: commonFlags
        )
        guard let rawSector = options.value("sector"), let sector = Int(rawSector) else {
            throw CLIError.usage("verify-key 需要整数 --sector")
        }
        let key = try requiredKey(options, command: "verify-key")
        let keyType = try parseKeyType(options.value("key-type"))
        let mode = try parseCardMode(options.value("card-mode"))
        let result = try withReader(options) { reader, _, _, _ -> (CardTarget, Bool) in
            guard let detected = try reader.selectTarget() else { throw AppError.noCard }
            let selectedTarget = target(detected, applying: mode)
            let verified = try reader.verifySectorKey(
                keyHex: key,
                sector: sector,
                type: keyType,
                target: selectedTarget,
                token: cancellationToken
            )
            return (selectedTarget, verified)
        }
        return CLICommandResult(data: [
            "card": targetObject(result.0),
            "sector": sector,
            "keyType": keyType.rawValue,
            "verified": result.1
        ], exitCode: result.1 ? CLIExitCode.success : CLIExitCode.partialResult)
    }

    private static func restoreCommand(_ options: CLIOptions) throws -> CLICommandResult {
        try options.validate(
            valueOptions: deviceValueOptions.union(["card-mode", "format", "input", "key", "key-file", "key-type"]),
            flagOptions: commonFlags.union(["include-block0", "include-trailers", "no-verify", "skip-sector-0", "yes"])
        )
        try requireConfirmation(options, operation: "恢复卡片")
        guard let input = options.value("input") else { throw CLIError.usage("restore 需要 --input") }
        let dump = try loadDump(fileURL(input), format: options.value("format"))
        let keyOverride = try optionalKey(options)
        if options.value("key-type") != nil, keyOverride == nil {
            throw CLIError.usage("--key-type 只能与 --key 一起使用")
        }
        let keyType = try keyOverride.map { _ in try parseKeyType(options.value("key-type")) }
        let mode = try parseCardMode(options.value("card-mode"))
        let result = try withReader(options) { reader, _, _, _ in
            try reader.restore(
                dump: dump,
                options: RestoreOptions(
                    keyOverride: keyOverride,
                    keyTypeOverride: keyType,
                    includeBlock0: options.hasFlag("include-block0"),
                    includeTrailers: options.hasFlag("include-trailers"),
                    verify: !options.hasFlag("no-verify"),
                    skipSectorZero: options.hasFlag("skip-sector-0")
                ),
                scanMode: mode,
                progress: progressLogger(options),
                token: cancellationToken
            )
        }
        return CLICommandResult(data: [
            "input": fileURL(input).path,
            "writtenBlocks": result.written,
            "failedBlocks": result.failed,
            "skippedBlocks": result.skipped,
            "verificationEnabled": !options.hasFlag("no-verify"),
            "verified": options.hasFlag("no-verify") ? NSNull() : result.failed.isEmpty
        ], exitCode: result.failed.isEmpty ? CLIExitCode.success : CLIExitCode.partialResult)
    }

    private static func writeUIDCommand(_ options: CLIOptions) throws -> CLICommandResult {
        try options.validate(
            valueOptions: deviceValueOptions.union(["key", "key-file", "uid"]),
            flagOptions: commonFlags.union(["yes"])
        )
        try requireConfirmation(options, operation: "修改 UID")
        guard let rawUID = options.value("uid") else { throw CLIError.usage("write-uid 需要 --uid") }
        let key = try requiredKey(options, command: "write-uid")
        let uid: Data
        do { uid = try HexCodec.data(from: rawUID, expectedBytes: 4) }
        catch { throw AppError.invalidUID }
        _ = try withReader(options) { reader, _, _, _ in
            try reader.writeUID(newUID: uid, keyHex: key, token: cancellationToken)
        }
        return CLICommandResult(data: ["uid": HexCodec.string(uid), "verified": true])
    }

    private static func formatCommand(_ options: CLIOptions) throws -> CLICommandResult {
        try options.validate(
            valueOptions: deviceValueOptions.union(["card-mode", "gpb", "key", "key-file", "key-type", "sectors"]),
            flagOptions: commonFlags.union(["yes"])
        )
        try requireConfirmation(options, operation: "格式化卡片")
        guard let rawSectors = options.value("sectors") else { throw CLIError.usage("format 需要 --sectors") }
        let key = try requiredKey(options, command: "format")
        let keyType = try parseKeyType(options.value("key-type"))
        let sectors = try parseSectors(rawSectors)
        let mode = try parseCardMode(options.value("card-mode"))
        let gpbData: Data
        do { gpbData = try HexCodec.data(from: options.value("gpb") ?? "69", expectedBytes: 1) }
        catch { throw CLIError.usage("--gpb 必须是 1 字节十六进制值") }
        let failed = try withReader(options) { reader, _, _, _ in
            try reader.format(
                keyHex: key,
                keyType: keyType,
                sectors: sectors,
                gpb: gpbData[0],
                scanMode: mode,
                progress: progressLogger(options),
                token: cancellationToken
            )
        }
        return CLICommandResult(data: [
            "sectors": sectors,
            "failedSectors": failed,
            "gpb": HexCodec.string(gpbData),
            "factoryKey": "FFFFFFFFFFFF"
        ], exitCode: failed.isEmpty ? CLIExitCode.success : CLIExitCode.partialResult)
    }

    private static func pn532Command(_ options: CLIOptions) throws -> CLICommandResult {
        try options.validate(
            valueOptions: deviceValueOptions.union(["hex"]),
            flagOptions: commonFlags
        )
        guard let rawHex = options.value("hex") else { throw CLIError.usage("pn532 需要 --hex") }
        let command = try HexCodec.data(from: rawHex)
        let readOnlyCommands: Set<UInt8> = [0x02, 0x04, 0x06, 0x4A]
        guard command.count >= 2, command[0] == 0xD4, readOnlyCommands.contains(command[1]) else {
            throw CLIError.usage("pn532 只允许 D4 02、D4 04、D4 06、D4 4A 只读命令")
        }
        let response = try withReader(options) { reader, _, _, _ in try reader.rawPN532(command) }
        return CLICommandResult(data: [
            "request": HexCodec.string(command),
            "response": HexCodec.string(response)
        ])
    }

    private static func bridgeCommand(_ options: CLIOptions) throws -> CLICommandResult {
        try options.validate(
            valueOptions: deviceValueOptions.union(["command"]),
            flagOptions: commonFlags
        )
        guard let commandLine = options.value("command"), !commandLine.isEmpty else {
            throw CLIError.usage("bridge 需要 --command")
        }
        let command = [
            "/bin/zsh", "-lc",
            "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; exec \(commandLine)"
        ]
        let exitCode = try withReader(options) { reader, _, _, _ in
            let bridge = LibNFCBridge(reader: reader, logger: { log($0) })
            return try bridge.run(command: command, token: cancellationToken)
        }
        return CLICommandResult(data: [
            "command": commandLine,
            "exitCode": Int(exitCode)
        ], exitCode: exitCode == 0 ? CLIExitCode.success : CLIExitCode.operation)
    }

    private static func withReader<T>(
        _ options: CLIOptions,
        operation: (WCopyReader, HIDDeviceDescriptor, Int, HandshakeInfo) throws -> T
    ) throws -> T {
        let devices = HIDDeviceScanner.scan()
        guard !devices.isEmpty else { throw AppError.noDevice }
        let index = try selectedDeviceIndex(options, devices: devices)
        let descriptor = devices[index]
        let transport = try HIDTransport(descriptor: descriptor)
        let verbose = options.hasFlag("verbose")
        let reader = WCopyReader(transport: transport, logger: { if verbose { log($0) } })
        defer { reader.close() }
        let radius = try syncRadius(options.value("sync-radius"))
        try reader.sync(
            radius: radius,
            progress: verbose ? { log(String(format: "同步 %.0f%%", $0 * 100)) } : nil,
            token: cancellationToken
        )
        let info = try reader.initialize()
        return try operation(reader, descriptor, index, info)
    }

    private static func selectedDeviceIndex(_ options: CLIOptions, devices: [HIDDeviceDescriptor]) throws -> Int {
        guard options.value("device-id") == nil || options.value("device-index") == nil else {
            throw CLIError.usage("--device-id 和 --device-index 不能同时使用")
        }
        if let rawID = options.value("device-id") {
            let cleaned = rawID.lowercased().hasPrefix("0x") ? String(rawID.dropFirst(2)) : rawID
            let radix = rawID.lowercased().hasPrefix("0x") ? 16 : 10
            guard let id = UInt64(cleaned, radix: radix), let index = devices.firstIndex(where: { $0.id == id }) else {
                throw CLIError.usage("--device-id 未匹配到设备：\(rawID)")
            }
            return index
        }
        let rawIndex = options.value("device-index") ?? "0"
        guard let index = Int(rawIndex), devices.indices.contains(index) else {
            throw CLIError.usage("--device-index 超出范围：\(rawIndex)")
        }
        return index
    }

    private static func syncRadius(_ value: String?) throws -> Int {
        guard let value else { return 200 }
        guard let radius = Int(value), radius >= 0, radius <= 2_000 else {
            throw CLIError.usage("--sync-radius 必须在 0...2000 之间")
        }
        return radius
    }

    private static func dictionaryPreset(_ value: String?) throws -> KeyDictionaryPreset {
        switch value?.lowercased() ?? "common" {
        case "quick": return .quick
        case "common": return .common
        case "patterns": return .patterns
        case "custom", "none": return .customOnly
        default: throw CLIError.usage("--preset 必须是 quick、common、patterns 或 custom")
        }
    }

    private static func presetName(_ preset: KeyDictionaryPreset) -> String {
        switch preset {
        case .quick: return "quick"
        case .common: return "common"
        case .patterns: return "patterns"
        case .customOnly: return "custom"
        }
    }

    private static func target(_ detected: CardTarget, applying mode: CardScanMode) -> CardTarget {
        guard let kind = mode.forcedKind else { return detected }
        return CardTarget(uid: detected.uid, atqa: detected.atqa, sak: detected.sak, kind: kind)
    }

    private static func requireConfirmation(_ options: CLIOptions, operation: String) throws {
        guard options.hasFlag("yes") else {
            throw CLIError.confirmation("\(operation)会修改卡片；确认已获授权后添加 --yes")
        }
    }

    private static func requiredKey(_ options: CLIOptions, command: String) throws -> String {
        guard let key = try optionalKey(options) else {
            throw CLIError.usage("\(command) 需要 --key 或 --key-file")
        }
        return key
    }

    private static func optionalKey(_ options: CLIOptions) throws -> String? {
        let inline = options.value("key")
        let keyFile = options.value("key-file")
        guard inline == nil || keyFile == nil else {
            throw CLIError.usage("--key 和 --key-file 不能同时使用")
        }
        if let inline { return try normalizeMifareKey(inline) }
        guard let keyFile else { return nil }
        let url = fileURL(keyFile)
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) }
        catch { throw CLIError.file("无法读取密钥文件 \(url.path)：\(error.localizedDescription)") }
        let parsed = MifareKeyDictionary.parse(text)
        guard parsed.keys.count == 1 else {
            throw CLIError.file("--key-file 必须恰好包含一个有效的 6 字节密钥")
        }
        return parsed.keys[0]
    }

    private static func loadDump(_ url: URL, format: String?) throws -> DumpDocument {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw CLIError.file("无法读取转储 \(url.path)：\(error.localizedDescription)") }
        let selectedFormat: String
        if let format {
            selectedFormat = format.lowercased()
            guard selectedFormat == "json" || selectedFormat == "mfd" else {
                throw CLIError.usage("--format 必须是 json 或 mfd")
            }
        } else if url.pathExtension.lowercased() == "mfd" {
            selectedFormat = "mfd"
        } else if data.first(where: { ![0x09, 0x0A, 0x0D, 0x20].contains($0) }) == 0x7B {
            selectedFormat = "json"
        } else if [320, 1024, 2048, 4096].contains(data.count) {
            selectedFormat = "mfd"
        } else {
            selectedFormat = "json"
        }
        return selectedFormat == "mfd" ? try DumpDocument.fromMFD(data) : try DumpDocument.fromJSON(data)
    }

    private struct DumpWriteResult {
        let value: Any
        let error: [String: Any]?
    }

    private static func validateOutputOptions(_ options: CLIOptions) throws {
        guard let path = options.value("output") else {
            if options.value("format") != nil || options.hasFlag("force") {
                throw CLIError.usage("--format 和 --force 只能与 --output 一起使用")
            }
            return
        }
        let url = fileURL(path)
        _ = try dumpFormat(options.value("format"), url: url)
        if FileManager.default.fileExists(atPath: url.path), !options.hasFlag("force") {
            throw CLIError.file("输出文件已存在：\(url.path)；使用 --force 覆盖")
        }
        var isDirectory: ObjCBool = false
        let parent = url.deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError.file("输出目录不存在：\(parent)")
        }
    }

    private static func writeDumpResult(_ dump: DumpDocument, options: CLIOptions) -> DumpWriteResult {
        do {
            return DumpWriteResult(value: try writeDumpIfRequested(dump, options: options), error: nil)
        } catch {
            return DumpWriteResult(
                value: NSNull(),
                error: ["code": "OUTPUT_WRITE", "message": error.localizedDescription]
            )
        }
    }

    private static func writeDumpIfRequested(_ dump: DumpDocument, options: CLIOptions) throws -> Any {
        guard let path = options.value("output") else { return NSNull() }
        let url = fileURL(path)
        let format = try dumpFormat(options.value("format"), url: url)
        let data = format == "mfd" ? try dump.mfdData() : try dump.jsonData()
        if !options.hasFlag("force") && FileManager.default.fileExists(atPath: url.path) {
            throw CLIError.file("输出文件已存在，使用 --force 覆盖：\(url.path)")
        }
        do { try data.write(to: url, options: .atomic) }
        catch { throw CLIError.file("无法写入 \(url.path)：\(error.localizedDescription)") }
        return ["path": url.path, "format": format, "bytes": data.count]
    }

    private static func dumpFormat(_ value: String?, url: URL) throws -> String {
        let format = value?.lowercased() ?? (url.pathExtension.lowercased() == "mfd" ? "mfd" : "json")
        guard format == "json" || format == "mfd" else {
            throw CLIError.usage("--format 必须是 json 或 mfd")
        }
        let extensionFormat = ["json", "mfd"].contains(url.pathExtension.lowercased())
            ? url.pathExtension.lowercased()
            : nil
        if let extensionFormat, extensionFormat != format {
            throw CLIError.usage("--format \(format) 与输出扩展名 .\(extensionFormat) 冲突")
        }
        return format
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    private static func progressLogger(_ options: CLIOptions) -> ((Double, String) -> Void)? {
        guard options.hasFlag("verbose") else { return nil }
        return { value, text in log(String(format: "%.0f%% %@", value * 100, text)) }
    }

    private static func commandCapability(_ name: String, mutating: Bool, hardware: Bool) -> [String: Any] {
        ["name": name, "mutating": mutating, "requiresHardware": hardware]
    }

    private static func deviceObject(_ device: HIDDeviceDescriptor, index: Int) -> [String: Any] {
        [
            "index": index,
            "id": String(device.id),
            "usbID": device.usbID,
            "product": device.productName,
            "manufacturer": device.manufacturer,
            "serial": device.serialNumber,
            "transport": device.transport,
            "usagePage": String(format: "0x%04X", device.usagePage),
            "usage": String(format: "0x%04X", device.usage),
            "inputReportBytes": device.maxInputReportSize,
            "outputReportBytes": device.maxOutputReportSize,
            "protocolStatus": device.protocolStatus
        ]
    }

    private static func targetObject(_ target: CardTarget) -> [String: Any] {
        [
            "uid": HexCodec.string(target.uid),
            "uidColon": target.uidText,
            "atqa": target.atqaText,
            "sak": target.sakText,
            "type": target.kind.rawValue,
            "sectorCount": target.kind.sectorCount,
            "blockCount": target.kind.blockCount
        ]
    }

    private static func sectorKeyObject(_ result: SectorKeyResult) -> [String: Any] {
        [
            "sector": result.sector,
            "keyA": result.keyA ?? NSNull(),
            "keyB": result.keyB ?? NSNull(),
            "keyBAuthenticates": result.keyBAuthenticates ?? NSNull()
        ]
    }

    private static func blocksObject(_ blocks: [Int: Data]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: blocks.map { (String($0.key), HexCodec.string($0.value)) })
    }

    private static func architectureName() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func classify(_ error: Error) -> (code: String, message: String, exitCode: Int32) {
        if let mutation = error as? MutationError {
            return ("PARTIAL_MUTATION", mutation.localizedDescription, CLIExitCode.operation)
        }
        if let cli = error as? CLIError {
            switch cli {
            case .usage: return ("USAGE", cli.localizedDescription, CLIExitCode.usage)
            case .file: return ("FILE", cli.localizedDescription, CLIExitCode.invalidInput)
            case .confirmation: return ("CONFIRMATION_REQUIRED", cli.localizedDescription, CLIExitCode.confirmationRequired)
            }
        }
        if let app = error as? AppError {
            switch app {
            case .noDevice, .notConnected:
                return ("NO_DEVICE", app.localizedDescription, CLIExitCode.noDevice)
            case .noCard:
                return ("NO_CARD", app.localizedDescription, CLIExitCode.noCard)
            case .transport:
                return ("TRANSPORT", app.localizedDescription, CLIExitCode.transport)
            case .cancelled:
                return ("CANCELLED", app.localizedDescription, CLIExitCode.cancelled)
            case .invalidHex, .invalidKey, .invalidUID, .invalidSectors, .invalidDump, .incompleteDump:
                return ("INVALID_INPUT", app.localizedDescription, CLIExitCode.invalidInput)
            case .unsupported:
                return ("UNSUPPORTED", app.localizedDescription, CLIExitCode.operation)
            case .operation:
                return ("OPERATION", app.localizedDescription, CLIExitCode.operation)
            }
        }
        return ("INTERNAL", error.localizedDescription, CLIExitCode.internalError)
    }

    private static func emit(
        command: String,
        ok: Bool,
        data: [String: Any]?,
        error: (code: String, message: String, exitCode: Int32)?,
        pretty: Bool
    ) {
        var envelope: [String: Any] = [
            "schemaVersion": schemaVersion,
            "ok": ok,
            "command": command
        ]
        if let data { envelope["data"] = data }
        if let error {
            var errorObject: [String: Any] = [
                "code": error.code,
                "message": error.message,
                "exitCode": error.exitCode
            ]
            if let mutation = WCopyCLI.lastMutationError {
                errorObject["mayHaveModified"] = true
                errorObject["attemptedBlocks"] = mutation.attemptedBlocks
                errorObject["acknowledgedBlocks"] = mutation.acknowledgedBlocks
                errorObject["retrySafe"] = false
            }
            envelope["error"] = errorObject
        }
        do {
            let writingOptions: JSONSerialization.WritingOptions = pretty
                ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                : [.sortedKeys, .withoutEscapingSlashes]
            var encoded = try JSONSerialization.data(withJSONObject: envelope, options: writingOptions)
            encoded.append(0x0A)
            FileHandle.standardOutput.write(encoded)
        } catch {
            let fallback = "{\"schemaVersion\":1,\"ok\":false,\"command\":\"internal\",\"error\":{\"code\":\"JSON_ENCODING\",\"message\":\"Unable to encode CLI output\",\"exitCode\":1}}\n"
            FileHandle.standardOutput.write(Data(fallback.utf8))
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[wcopy-nfc] \(message)\n".utf8))
    }

    private static func printHelp(command: String?) {
        let text: String
        switch command {
        case "read":
            text = """
            Usage: wcopy-nfc read (--key HEX | --key-file FILE) [--key-type A|B] [--sectors 0-15]
                   [--card-mode auto|sak19|mini|1k|2k|4k] [--output FILE] [--format json|mfd]
            Reads authenticated sectors. Exit 10 means a valid partial result.
            """
        case "keys":
            text = """
            Usage: wcopy-nfc keys [--preset quick|common|patterns|custom]
                   [--dictionary FILE]... [--key HEX]... [--card-mode MODE]
                   [--output FILE] [--format json|mfd]
            Checks Key A and Key B for every sector and returns all discovered slots.
            """
        case "restore":
            text = """
            Usage: wcopy-nfc restore --input FILE --yes [--format json|mfd]
                   [--key HEX|--key-file FILE] [--key-type A|B]
                   [--include-block0] [--include-trailers] [--no-verify] [--card-mode MODE]
            Mutating command. Block 0 and sector trailers are skipped unless explicitly enabled.
            """
        case "format":
            text = """
            Usage: wcopy-nfc format (--key HEX | --key-file FILE) --sectors RANGE --yes
                   [--key-type A|B] [--gpb 69] [--card-mode MODE]
            Mutating command. Clears data blocks and resets selected sector keys.
            """
        case "write-uid":
            text = """
            Usage: wcopy-nfc write-uid --uid AABBCCDD (--key HEX | --key-file FILE) --yes
            Mutating command for compatible 4-byte UID Magic/CUID cards only.
            """
        default:
            text = """
            wcopy-nfc \(version) - agent-friendly CLI for wCopy NFC readers

            Usage: wcopy-nfc COMMAND [OPTIONS]

            Discovery:
              version         CLI and schema version
              capabilities    Machine-readable capability manifest
              devices         List compatible HID interfaces
              diagnostics     Environment and HID diagnostics; --connect adds handshake
              reader-info     Open, synchronize, and initialize the selected reader
              card-info       Detect the current ISO 14443-A card

            Card operations:
              read            Read sectors with one known key
              keys            Check dictionary candidates against all key slots
              verify-key      Verify one key against one sector/key type
              restore         Restore a JSON/MFD dump; requires --yes
              write-uid       Change a Magic/CUID card UID; requires --yes
              format          Format selected sectors; requires --yes
              pn532           Send an allow-listed read-only PN532 command

            Common options:
              --device-index N    Device index from `devices` (default: 0)
              --device-id ID      Registry ID from `devices`, decimal or 0xHEX
              --sync-radius N     HID sequence search radius (default: 200)
              --card-mode MODE    auto, sak19, mini, 1k, 2k, or 4k
              --pretty            Pretty-print the JSON envelope
              --verbose           Write progress/protocol logs to stderr
              --help              Show command help

            stdout is always one JSON document for non-help commands. See docs/CLI.md.
            """
        }
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}
