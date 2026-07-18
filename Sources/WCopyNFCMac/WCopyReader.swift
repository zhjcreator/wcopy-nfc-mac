import Foundation

struct HandshakeInfo {
    let firmware: String
    let serial: String
    let sequence: UInt16
}

struct RestoreOptions {
    var keyOverride: String?
    var keyTypeOverride: KeyType?
    var includeBlock0 = false
    var includeTrailers = false
    var verify = true
}

struct RestoreResult {
    let written: Int
    let failed: [Int]
    let skipped: Int
}

final class WCopyReader {
    static let bootSequence: UInt16 = 0x0C12
    static let knownKeys = MifareKeyDictionary.quickKeys

    private let transport: HIDTransportProtocol
    private let logger: (String) -> Void
    private(set) var sequence: UInt16?

    init(transport: HIDTransportProtocol, logger: @escaping (String) -> Void = { _ in }) {
        self.transport = transport
        self.logger = logger
    }

    func close() { transport.close() }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        var sum: UInt8 = 0
        for byte in bytes { sum &+= byte }
        return ~sum
    }

    static func buildFrame(sequence: UInt16, content: Data) throws -> Data {
        let length = 4 + content.count + 2
        guard length <= 64 else { throw AppError.operation("协议内容过长") }
        var frame = Data([
            0x01,
            UInt8(length),
            UInt8(sequence & 0x00FF),
            UInt8((sequence >> 8) & 0x00FF)
        ])
        frame.append(content)
        frame.append(checksum(frame))
        frame.append(0xFE)
        frame.append(Data(repeating: 0, count: 64 - frame.count))
        return frame
    }

    static func parseInputFrame(_ report: Data, expectedSequence: UInt16? = nil) -> Data? {
        guard report.count >= 6, report[0] == 0x02 else { return nil }
        let length = Int(report[1])
        guard length >= 6, length <= report.count, report[length - 1] == 0xFD else { return nil }
        let sequence = UInt16(report[2]) | (UInt16(report[3]) << 8)
        if let expectedSequence, sequence != expectedSequence { return nil }
        let payloadEnd = length - 2
        guard checksum(report.prefix(payloadEnd)) == report[payloadEnd] else { return nil }
        return report.subdata(in: 4..<payloadEnd)
    }

    static func mifareAuthenticationSucceeded(_ response: Data) throws -> Bool {
        guard response.count >= 3, response[0] == 0xD5, response[1] == 0x41 else {
            throw AppError.transport("PN532 返回了无效的 MIFARE 认证响应")
        }
        let status = response[2] & 0x3F
        if status == 0 { return true }
        if status == 0x14 { return false }
        throw AppError.transport("MIFARE 认证出现 PN532 错误 0x\(String(format: "%02X", status))，未将其计为密钥错误")
    }

    func sync(
        center: UInt16 = bootSequence,
        radius: Int = 200,
        timeout: TimeInterval = 0.08,
        progress: ((Double) -> Void)? = nil,
        token: CancellationToken? = nil
    ) throws {
        sequence = nil
        transport.drain()
        let probe = Data([0xFF, 0x00, 0x68])
        var candidates: [UInt16] = [center]
        if radius > 0 {
            for delta in 1...radius {
                if Int(center) + delta <= Int(UInt16.max) { candidates.append(UInt16(Int(center) + delta)) }
                if Int(center) - delta >= 0 { candidates.append(UInt16(Int(center) - delta)) }
            }
        }
        logger("正在同步 HID 序列计数器…")
        for (index, candidate) in candidates.enumerated() {
            try token?.check()
            if let _ = try exchange(candidate, content: probe, timeout: timeout) {
                sequence = candidate &+ 2
                logger("同步成功，序列号 0x\(String(format: "%04X", sequence!))")
                progress?(1)
                return
            }
            progress?(Double(index + 1) / Double(candidates.count))
        }
        throw AppError.operation("设备已打开，但协议同步失败。请拔插读卡器后重试；0416:B008 可能使用了不同固件协议。")
    }

    func initialize() throws -> HandshakeInfo {
        let firmwareData = try send(Data([0xFF, 0x00, 0x68]))
        let serialData = try send(Data([0xFF, 0x00, 0x69]))
        _ = try send(Data([0xFF, 0x00, 0x62, 0x01, 0x06, 0x00, 0x00, 0x1F, 0x01, 0xFA, 0x00]))
        _ = try send(Data([0xFF, 0x00, 0x40, 0x50, 0x04, 0x05, 0x01, 0x01, 0x01]))
        let info = HandshakeInfo(
            firmware: readablePayload(firmwareData),
            serial: readablePayload(serialData),
            sequence: sequence ?? 0
        )
        logger("设备初始化完成")
        return info
    }

    func selectTarget(timeout: TimeInterval = 1.0) throws -> CardTarget? {
        let response = try pn532(Data([0xD4, 0x4A, 0x01, 0x00]), timeout: timeout)
        guard response.count >= 8, response[0] == 0xD5, response[1] == 0x4B,
              response[2] > 0 else { return nil }
        let uidLength = Int(response[7])
        guard response.count >= 8 + uidLength else { return nil }
        let atqa = (UInt16(response[4]) << 8) | UInt16(response[5])
        let sak = response[6]
        let uid = response.subdata(in: 8..<(8 + uidLength))
        let kind = CardKind.detect(sak: sak, atqa: atqa, uidLength: uidLength)
        return CardTarget(uid: uid, atqa: atqa, sak: sak, kind: kind)
    }

    func readCard(
        keyHex: String,
        keyType: KeyType,
        sectors requestedSectors: [Int]?,
        scanMode: CardScanMode = .automatic,
        progress: ((Double, String) -> Void)? = nil,
        token: CancellationToken? = nil
    ) throws -> ReadResult {
        let key = try validatedKey(keyHex)
        guard let detectedTarget = try selectTarget() else { throw AppError.noCard }
        let target = target(detectedTarget, applying: scanMode)
        let sectors = requestedSectors ?? Array(0..<target.kind.sectorCount)
        guard sectors.allSatisfy({ $0 < target.kind.sectorCount }) else {
            throw AppError.invalidSectors(sectors.map(String.init).joined(separator: ","))
        }

        var blocks: [Int: Data] = [:]
        var failed: [Int] = []
        var failedBlocks: [Int] = []
        for (position, sector) in sectors.enumerated() {
            try token?.check()
            progress?(Double(position) / Double(sectors.count), "读取扇区 \(sector)")
            let first = CardLayout.firstBlock(of: sector)
            guard try authenticate(block: first, uid: target.uid, key: key, type: keyType) else {
                failed.append(sector)
                logger("扇区 \(sector)：认证失败")
                continue
            }
            for block in first..<(first + CardLayout.blockCount(in: sector)) {
                try token?.check()
                if let data = try readBlock(block) { blocks[block] = data }
                else {
                    failedBlocks.append(block)
                    logger("块 \(block)：读取失败")
                }
            }
        }
        progress?(1, "读取完成")
        logger("读取完成：\(blocks.count) 个块，\(failed.count) 个扇区认证失败")
        return ReadResult(target: target, blocks: blocks, failedSectors: failed, failedBlocks: failedBlocks)
    }

    func checkKeys(
        candidates: [String],
        scanMode: CardScanMode = .automatic,
        progress: ((Double, String) -> Void)? = nil,
        token: CancellationToken? = nil
    ) throws -> KeyCheckOutcome {
        guard let detectedTarget = try selectTarget() else { throw AppError.noCard }
        let target = target(detectedTarget, applying: scanMode)
        guard target.kind != .unknown else {
            throw AppError.unsupported("检测到 \(target.kind.rawValue)，默认密钥检查仅支持 MIFARE Classic Mini / 1K / 4K")
        }
        var keyCandidates = candidates
        if target.kind == .customClassic1K,
           let derived = SAK19Compatibility.uidDerivedKeyCandidate(target.uid) {
            keyCandidates = MifareKeyDictionary.merged([[derived], keyCandidates])
            logger("SAK 19 兼容模式：已自动加入 UID 派生密钥候选 \(derived)")
        }
        let keys = try keyCandidates.map { (try validatedKey($0), $0.uppercased()) }
        guard !keys.isEmpty else {
            throw AppError.invalidKey
        }
        var results = Dictionary(uniqueKeysWithValues: (0..<target.kind.sectorCount).map {
            ($0, SectorKeyResult(sector: $0))
        })
        var blocks: [Int: Data] = [:]
        var failedBlocks: [Int] = []
        var attempts = 0
        let slotCount = target.kind.sectorCount * 2
        let progressStride = max(1, keys.count / 100)
        var previousFoundSlots = 0

        // Scan high-probability keys across all unresolved sectors before moving
        // deeper into the dictionary, so common defaults are found quickly.
        for (keyIndex, (key, keyHex)) in keys.enumerated() {
            try token?.check()
            for sector in 0..<target.kind.sectorCount {
                try token?.check()
                let first = CardLayout.firstBlock(of: sector)
                if results[sector]?.keyA == nil {
                    attempts += 1
                    if try testAuthentication(block: first, target: target, key: key, type: .a) {
                        results[sector]?.keyA = keyHex
                        logger("扇区 \(sector)：找到 Key A = \(keyHex)")
                        if target.kind != .customClassic1K,
                           results[sector]?.keyB == nil,
                           let trailer = try readBlock(CardLayout.trailerBlock(of: sector)) {
                            if CardLayout.keyBIsReadableData(in: trailer) == true {
                                let revealedKeyB = trailer.suffix(6)
                                let revealedHex = HexCodec.string(revealedKeyB)
                                results[sector]?.keyB = revealedHex
                                results[sector]?.keyBAuthenticates = false
                                logger("扇区 \(sector)：尾块公开 Key B 字段 = \(revealedHex)（访问位禁止其用于认证）")
                            }
                        }
                    }
                }
                if results[sector]?.keyB == nil {
                    attempts += 1
                    if try testAuthentication(block: first, target: target, key: key, type: .b) {
                        results[sector]?.keyB = keyHex
                        results[sector]?.keyBAuthenticates = true
                        logger("扇区 \(sector)：找到 Key B = \(keyHex)")
                    }
                }
            }
            let foundSlots = results.values.reduce(0) { $0 + ($1.keyA == nil ? 0 : 1) + ($1.keyB == nil ? 0 : 1) }
            if keyIndex.isMultiple(of: progressStride) || foundSlots != previousFoundSlots || keyIndex + 1 == keys.count {
                let dictionaryProgress = Double(keyIndex + 1) / Double(keys.count)
                let discoveryProgress = Double(foundSlots) / Double(slotCount)
                progress?(
                    max(dictionaryProgress, discoveryProgress),
                    "字典 \(keyIndex + 1)/\(keys.count) · 已找到 \(foundSlots)/\(slotCount) 个密钥槽"
                )
            }
            previousFoundSlots = foundSlots
            if foundSlots == slotCount { break }
        }

        // SAK 19 compatible cards can authenticate Key B even when the access
        // bits describe that field as readable data. Prefer the observed auth
        // result, and only classify the field as DATA after all candidates fail.
        if target.kind == .customClassic1K {
            for sector in 0..<target.kind.sectorCount where results[sector]?.keyB == nil {
                try token?.check()
                guard let keyAHex = results[sector]?.keyA else { continue }
                let first = CardLayout.firstBlock(of: sector)
                try reselect(target: target)
                attempts += 1
                guard try authenticate(
                    block: first,
                    uid: target.uid,
                    key: validatedKey(keyAHex),
                    type: .a
                ), let trailer = try readBlock(CardLayout.trailerBlock(of: sector)),
                   CardLayout.keyBIsReadableData(in: trailer) == true else {
                    continue
                }
                let revealedHex = HexCodec.string(trailer.suffix(6))
                results[sector]?.keyB = revealedHex
                results[sector]?.keyBAuthenticates = false
                logger("扇区 \(sector)：候选 Key B 均未通过；尾块字段 = \(revealedHex)（DATA）")
            }
        }

        for sector in 0..<target.kind.sectorCount {
            try token?.check()
            let result = results[sector]!
            let first = CardLayout.firstBlock(of: sector)
            let usableKeyB = result.keyBAuthenticates == false ? nil : result.keyB
            guard result.keyA != nil || usableKeyB != nil else {
                logger("扇区 \(sector)：未找到已知密钥")
                continue
            }
            for block in first..<(first + CardLayout.blockCount(in: sector)) {
                if let data = try readBlock(
                    block,
                    target: target,
                    keyAHex: result.keyA,
                    keyBHex: usableKeyB,
                    attempts: &attempts
                ) {
                    blocks[block] = data
                } else {
                    failedBlocks.append(block)
                }
            }
        }
        progress?(1, "密钥检查完成")
        return KeyCheckOutcome(
            target: target,
            sectorKeys: results,
            blocks: blocks,
            failedBlocks: failedBlocks,
            attempts: attempts,
            candidateCount: keys.count
        )
    }

    func verifySectorKey(
        keyHex: String,
        sector: Int,
        type: KeyType,
        target: CardTarget,
        token: CancellationToken? = nil
    ) throws -> Bool {
        guard sector >= 0, sector < target.kind.sectorCount else {
            throw AppError.invalidSectors(String(sector))
        }
        try token?.check()
        guard let refreshed = try selectTarget() else { throw AppError.noCard }
        guard refreshed.uid == target.uid,
              refreshed.atqa == target.atqa,
              refreshed.sak == target.sak else {
            throw AppError.operation("卡片发生变化，未保存粘贴的密钥")
        }
        return try testAuthentication(
            block: CardLayout.firstBlock(of: sector),
            target: target,
            key: validatedKey(keyHex),
            type: type
        )
    }

    func restore(
        dump: DumpDocument,
        options: RestoreOptions,
        scanMode: CardScanMode = .automatic,
        progress: ((Double, String) -> Void)? = nil,
        token: CancellationToken? = nil
    ) throws -> RestoreResult {
        let validatedDump = try dump.validated()
        guard let detectedTarget = try selectTarget() else { throw AppError.noCard }
        var target = target(detectedTarget, applying: scanMode)
        let sourceKind = validatedDump.inferredKind
        guard sourceKind.blockCount <= target.kind.blockCount else {
            throw AppError.operation("源转储是 \(sourceKind.rawValue)，目标卡是 \(target.kind.rawValue)。为避免部分覆盖，未写入任何块。")
        }

        let allBlocks = validatedDump.sortedBlocks
        let normalBlocks = allBlocks.filter { $0.0 != 0 && !CardLayout.isTrailer($0.0) }
        var trailerBlocks = options.includeTrailers ? allBlocks.filter { CardLayout.isTrailer($0.0) } : []
        trailerBlocks = try trailerBlocks.map { block, rawData in
            let sector = CardLayout.sector(containing: block)
            guard let keys = validatedDump.sectorKeys?[String(sector)],
                  let keyA = keys.a, let keyB = keys.b else {
                throw AppError.invalidDump("恢复扇区尾块需要扇区 \(sector) 的完整 Key A 和 Key B；普通读卡会隐藏 Key A")
            }
            var data = rawData
            data.replaceSubrange(0..<6, with: try validatedKey(keyA))
            data.replaceSubrange(10..<16, with: try validatedKey(keyB))
            guard CardLayout.keyBIsReadableData(in: data) != nil else {
                throw AppError.invalidDump("扇区 \(sector) 尾块的访问位及其反码不一致")
            }
            return (block, data)
        }
        let block0: Data?
        if options.includeBlock0 {
            guard target.uid.count == 4 else {
                throw AppError.unsupported("块 0 写入只支持当前 UID 为 4 字节的 Magic/CUID 卡")
            }
            guard let rawBlock0 = validatedDump.blocks["0"] else {
                throw AppError.invalidDump("已要求恢复块 0，但转储不包含块 0")
            }
            let data = try HexCodec.data(from: rawBlock0, expectedBytes: 16)
            guard let dumpUID = try? HexCodec.data(from: validatedDump.uid, expectedBytes: 4),
                  CardLayout.manufacturerBlock(data, matchesUID: dumpUID) else {
                throw AppError.invalidDump("块 0 UID 或 BCC 与转储元数据不一致")
            }
            block0 = data
        } else {
            block0 = nil
        }
        let selectedCount = normalBlocks.count + trailerBlocks.count + (block0 == nil ? 0 : 1)
        guard selectedCount > 0 else {
            throw AppError.operation("安全选项过滤后没有可恢复的数据块")
        }
        let skipped = validatedDump.blocks.count - selectedCount

        let sectorsToAuthenticate = Set((normalBlocks + trailerBlocks).map { CardLayout.sector(containing: $0.0) })
            .union(block0 == nil ? [] : [0])
        for sector in sectorsToAuthenticate.sorted() {
            try token?.check()
            let auth = try authentication(for: sector, dump: validatedDump, options: options)
            guard try authenticate(
                block: CardLayout.firstBlock(of: sector),
                uid: target.uid,
                key: auth.key,
                type: auth.type
            ) else {
                throw AppError.operation("写入前检查失败：目标卡扇区 \(sector) 无法使用指定密钥认证，未写入任何块。")
            }
        }

        var written = 0
        var failed: [Int] = []
        var completed = 0
        let total = selectedCount
        var attemptedBlocks: [Int] = []
        var acknowledgedBlocks: [Int] = []
        var sectorsWithDataFailure = Set<Int>()

        do {
            let normalSectors = Dictionary(grouping: normalBlocks, by: { CardLayout.sector(containing: $0.0) })
            for sector in normalSectors.keys.sorted() {
                try token?.check()
                let auth = try authentication(for: sector, dump: validatedDump, options: options)
                let first = CardLayout.firstBlock(of: sector)
                guard try authenticate(block: first, uid: target.uid, key: auth.key, type: auth.type) else {
                    let sectorBlocks = normalSectors[sector]!.map(\.0)
                    failed.append(contentsOf: sectorBlocks)
                    sectorsWithDataFailure.insert(sector)
                    completed += sectorBlocks.count
                    logger("扇区 \(sector)：认证失败，已跳过")
                    continue
                }
                for (block, data) in normalSectors[sector]!.sorted(by: { $0.0 < $1.0 }) {
                    try token?.check()
                    progress?(total == 0 ? 1 : Double(completed) / Double(total), "写入块 \(block)")
                    attemptedBlocks.append(block)
                    let ok = try writeBlock(block, data: data)
                    if ok { acknowledgedBlocks.append(block) }
                    if ok && options.verify, try readBlock(block) != data {
                        throw AppError.operation("块 \(block) 已写入，但回读验证不一致")
                    }
                    if ok {
                        written += 1
                    } else {
                        failed.append(block)
                        sectorsWithDataFailure.insert(sector)
                    }
                    completed += 1
                }
            }

            if block0 != nil, sectorsWithDataFailure.contains(0) {
                failed.append(0)
                completed += 1
                logger("扇区 0 普通数据写入失败，已跳过块 0")
            } else if let data = block0 {
                let auth = try authentication(for: 0, dump: validatedDump, options: options)
                if try authenticate(block: 0, uid: target.uid, key: auth.key, type: auth.type) {
                    attemptedBlocks.append(0)
                    let accepted = try writeBlock(0, data: data)
                    if accepted { acknowledgedBlocks.append(0) }
                    if accepted, options.verify {
                        target = try reselectAfterWrite(
                            target: target,
                            expectedUID: Data(data.prefix(4))
                        )
                        let uidMatches = target.uid == data.prefix(4)
                        let authWorks = try authenticate(block: 0, uid: target.uid, key: auth.key, type: auth.type)
                        let blockMatches = try readBlock(0) == data
                        guard uidMatches && authWorks && blockMatches else {
                            throw AppError.operation("块 0 已写入，但回读验证不一致")
                        }
                        written += 1
                    } else if accepted {
                        written += 1
                        target = try reselectAfterWrite(
                            target: target,
                            expectedUID: Data(data.prefix(4))
                        )
                    } else {
                        failed.append(0)
                        sectorsWithDataFailure.insert(0)
                    }
                } else {
                    failed.append(0)
                    sectorsWithDataFailure.insert(0)
                }
                completed += 1
            }

            for (block, data) in trailerBlocks {
                let sector = CardLayout.sector(containing: block)
                if sectorsWithDataFailure.contains(sector) {
                    failed.append(block)
                    completed += 1
                    logger("扇区 \(sector)：普通数据写入失败，已保留原尾块")
                    continue
                }
                let auth = try authentication(for: sector, dump: validatedDump, options: options)
                try token?.check()
                progress?(total == 0 ? 1 : Double(completed) / Double(total), "写入扇区 \(sector) 尾块")
                var ok = try authenticate(
                    block: CardLayout.firstBlock(of: sector),
                    uid: target.uid,
                    key: auth.key,
                    type: auth.type
                )
                if ok {
                    attemptedBlocks.append(block)
                    ok = try writeBlock(block, data: data)
                    if ok { acknowledgedBlocks.append(block) }
                }
                if ok && options.verify {
                    target = try reselectAfterWrite(target: target)
                    let keyA = data.prefix(6)
                    let keyB = data.suffix(6)
                    let first = CardLayout.firstBlock(of: sector)
                    let keyAWorks = try authenticate(block: first, uid: target.uid, key: keyA, type: .a)
                    let keyBReadable = CardLayout.keyBIsReadableData(in: data) == true
                    let keyBWorks = keyBReadable
                        ? true
                        : try authenticate(block: first, uid: target.uid, key: keyB, type: .b)
                    let accessMatches: Bool
                    if keyAWorks, let readback = try readBlock(block) {
                        accessMatches = readback.subdata(in: 6..<10) == data.subdata(in: 6..<10)
                            && (!keyBReadable || readback.suffix(6) == data.suffix(6))
                    } else {
                        accessMatches = false
                    }
                    ok = keyAWorks && keyBWorks && accessMatches
                    guard ok else {
                        throw AppError.operation("尾块 \(block) 已写入，但密钥或访问位验证不一致")
                    }
                }
                if ok { written += 1 } else { failed.append(block) }
                completed += 1
            }
        } catch {
            guard !attemptedBlocks.isEmpty else { throw error }
            throw MutationError(
                operation: "恢复",
                attemptedBlocks: attemptedBlocks,
                acknowledgedBlocks: acknowledgedBlocks,
                reason: error.localizedDescription
            )
        }
        progress?(1, "恢复完成")
        return RestoreResult(written: written, failed: failed.sorted(), skipped: max(0, skipped))
    }

    func writeUID(newUID: Data, keyHex: String, token: CancellationToken? = nil) throws -> Bool {
        guard newUID.count == 4 else { throw AppError.invalidUID }
        let key = try validatedKey(keyHex)
        guard let target = try selectTarget() else { throw AppError.noCard }
        guard target.uid.count == 4 else {
            throw AppError.unsupported("UID 修改只支持当前 UID 为 4 字节的 Magic/CUID 卡")
        }
        guard try authenticate(block: 0, uid: target.uid, key: key, type: .a),
              let oldBlock = try readBlock(0) else {
            throw AppError.operation("扇区 0 认证或读取失败")
        }
        try token?.check()
        let bcc = newUID.reduce(UInt8(0), ^)
        var replacement = Data(newUID)
        replacement.append(bcc)
        replacement.append(oldBlock.dropFirst(5))
        guard try authenticate(block: 0, uid: target.uid, key: key, type: .a) else {
            throw AppError.operation("UID 写入前扇区 0 认证失败，未修改卡片")
        }
        var acknowledged = false
        do {
            guard try writeBlock(0, data: replacement) else {
                throw AppError.operation("UID 写入失败。该卡可能不是可改 UID 的 Magic/CUID 卡。")
            }
            acknowledged = true
            let verifyTarget = try reselectAfterWrite(target: target, expectedUID: newUID)
            guard try authenticate(block: 0, uid: verifyTarget.uid, key: key, type: .a),
                  try readBlock(0) == replacement else {
                throw AppError.operation("设备报告写入成功，但回读验证不一致")
            }
        } catch {
            throw MutationError(
                operation: "UID 写入",
                attemptedBlocks: [0],
                acknowledgedBlocks: acknowledged ? [0] : [],
                reason: error.localizedDescription
            )
        }
        return true
    }

    func format(
        keyHex: String,
        keyType: KeyType,
        sectors: [Int],
        gpb: UInt8,
        scanMode: CardScanMode = .automatic,
        progress: ((Double, String) -> Void)? = nil,
        token: CancellationToken? = nil
    ) throws -> [Int] {
        let key = try validatedKey(keyHex)
        guard let detectedTarget = try selectTarget() else { throw AppError.noCard }
        let target = target(detectedTarget, applying: scanMode)
        let zero = Data(repeating: 0, count: 16)
        let trailer = try HexCodec.data(from: "FFFFFFFFFFFFFF0780\(String(format: "%02X", gpb))FFFFFFFFFFFF", expectedBytes: 16)
        guard sectors.allSatisfy({ $0 < target.kind.sectorCount }) else {
            throw AppError.invalidSectors(sectors.map(String.init).joined(separator: ","))
        }
        for sector in sectors {
            try token?.check()
            guard try authenticate(
                block: CardLayout.firstBlock(of: sector),
                uid: target.uid,
                key: key,
                type: keyType
            ) else {
                throw AppError.operation("格式化前检查失败：扇区 \(sector) 无法认证，未修改任何扇区。")
            }
        }

        var failed: [Int] = []
        var currentTarget = target
        var attemptedBlocks: [Int] = []
        var acknowledgedBlocks: [Int] = []
        do {
            for (position, sector) in sectors.enumerated() {
                try token?.check()
                progress?(Double(position) / Double(sectors.count), "格式化扇区 \(sector)")
                let first = CardLayout.firstBlock(of: sector)
                guard try authenticate(block: first, uid: currentTarget.uid, key: key, type: keyType) else {
                    failed.append(sector)
                    continue
                }
                var success = true
                let trailerBlock = CardLayout.trailerBlock(of: sector)
                for block in first..<trailerBlock where block != 0 {
                    try token?.check()
                    attemptedBlocks.append(block)
                    let accepted = try writeBlock(block, data: zero)
                    if accepted { acknowledgedBlocks.append(block) }
                    if accepted, try readBlock(block) != zero {
                        throw AppError.operation("块 \(block) 已写入，但回读验证不一致")
                    }
                    if !accepted {
                        success = false
                        break
                    }
                }
                guard success else {
                    failed.append(sector)
                    logger("扇区 \(sector)：普通数据写入失败，已保留原尾块")
                    continue
                }
                try token?.check()
                attemptedBlocks.append(trailerBlock)
                let trailerAccepted = try writeBlock(trailerBlock, data: trailer)
                if trailerAccepted { acknowledgedBlocks.append(trailerBlock) }
                success = trailerAccepted
                if success {
                    currentTarget = try reselectAfterWrite(target: currentTarget)
                    let keyA = trailer.prefix(6)
                    let keyB = trailer.suffix(6)
                    let keyAWorks = try authenticate(block: first, uid: currentTarget.uid, key: keyA, type: .a)
                    let keyBReadable = CardLayout.keyBIsReadableData(in: trailer) == true
                    let keyBWorks = keyBReadable
                        ? true
                        : try authenticate(block: first, uid: currentTarget.uid, key: keyB, type: .b)
                    let accessMatches: Bool
                    if keyAWorks, let readback = try readBlock(trailerBlock) {
                        accessMatches = readback.subdata(in: 6..<10) == trailer.subdata(in: 6..<10)
                            && (!keyBReadable || readback.suffix(6) == trailer.suffix(6))
                    } else {
                        accessMatches = false
                    }
                    success = keyAWorks && keyBWorks && accessMatches
                    guard success else {
                        throw AppError.operation("扇区 \(sector) 尾块已写入，但密钥或访问位验证不一致")
                    }
                }
                if !success { failed.append(sector) }
            }
        } catch {
            guard !attemptedBlocks.isEmpty else { throw error }
            throw MutationError(
                operation: "格式化",
                attemptedBlocks: attemptedBlocks,
                acknowledgedBlocks: acknowledgedBlocks,
                reason: error.localizedDescription
            )
        }
        progress?(1, "格式化完成")
        return failed
    }

    func rawPN532(_ bytes: Data) throws -> Data {
        guard bytes.count >= 2, bytes.first == 0xD4 else {
            throw AppError.operation("PN532 主机命令必须以 D4 开头")
        }
        return try pn532(bytes, timeout: 2)
    }

    private func exchange(_ outboundSequence: UInt16, content: Data, timeout: TimeInterval) throws -> Data? {
        let frame = try Self.buildFrame(sequence: outboundSequence, content: content)
        try transport.write(frame)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let report = try transport.read(timeout: max(0, deadline.timeIntervalSinceNow)) else { return nil }
            if let content = Self.parseInputFrame(report, expectedSequence: outboundSequence &+ 1) {
                return content
            }
        }
        return nil
    }

    private func send(_ content: Data, timeout: TimeInterval = 1.0) throws -> Data {
        guard let current = sequence else { throw AppError.operation("设备尚未同步") }
        guard let response = try exchange(current, content: content, timeout: timeout) else {
            throw AppError.transport("设备响应超时，请重新连接或拔插读卡器")
        }
        sequence = current &+ 2
        return response
    }

    private func pn532(_ command: Data, timeout: TimeInterval = 1.0) throws -> Data {
        guard command.count <= 53 else { throw AppError.operation("PN532 命令过长") }
        var wrapped = Data([0xFF, 0x00, 0x00, 0x00, UInt8(command.count)])
        wrapped.append(command)
        return try send(wrapped, timeout: timeout)
    }

    private func authenticate(block: Int, uid: Data, key: Data, type: KeyType) throws -> Bool {
        guard block >= 0, block <= 255 else { return false }
        var command = Data([0xD4, 0x40, 0x01, type.command, UInt8(block)])
        command.append(key)
        guard uid.count >= 4 else { return false }
        command.append(uid.suffix(4))
        let response = try pn532(command)
        return try Self.mifareAuthenticationSucceeded(response)
    }

    private func testAuthentication(block: Int, target: CardTarget, key: Data, type: KeyType) throws -> Bool {
        if try authenticate(block: block, uid: target.uid, key: key, type: type) { return true }
        try reselect(target: target)
        return false
    }

    private func readBlock(
        _ block: Int,
        target: CardTarget,
        keyAHex: String?,
        keyBHex: String?,
        attempts: inout Int
    ) throws -> Data? {
        let first = CardLayout.firstBlock(of: CardLayout.sector(containing: block))
        if let keyAHex {
            try reselect(target: target)
            attempts += 1
            if try authenticate(block: first, uid: target.uid, key: validatedKey(keyAHex), type: .a),
               let data = try readBlock(block) {
                return data
            }
        }
        if let keyBHex {
            try reselect(target: target)
            attempts += 1
            if try authenticate(block: first, uid: target.uid, key: validatedKey(keyBHex), type: .b),
               let data = try readBlock(block) {
                return data
            }
        }
        return nil
    }

    private func reselect(target: CardTarget) throws {
        guard let refreshed = try selectTarget() else { throw AppError.noCard }
        guard refreshed.uid == target.uid,
              refreshed.atqa == target.atqa,
              refreshed.sak == target.sak else {
            throw AppError.operation("密钥检查期间卡片发生变化，已停止以避免混合结果")
        }
    }

    private func reselectAfterWrite(target: CardTarget, expectedUID: Data? = nil) throws -> CardTarget {
        guard let refreshed = try selectTarget() else {
            throw AppError.operation("写入后无法重新寻卡验证")
        }
        guard refreshed.uid == (expectedUID ?? target.uid),
              refreshed.atqa == target.atqa,
              refreshed.sak == target.sak else {
            throw AppError.operation("写入后检测到卡片发生变化，已停止后续写入")
        }
        return CardTarget(
            uid: refreshed.uid,
            atqa: refreshed.atqa,
            sak: refreshed.sak,
            kind: target.kind
        )
    }

    private func target(_ detected: CardTarget, applying mode: CardScanMode) -> CardTarget {
        guard let forcedKind = mode.forcedKind else { return detected }
        logger("强制卡型模式：\(forcedKind.rawValue)；原始 SAK=\(detected.sakText)，ATQA=\(detected.atqaText)")
        return CardTarget(
            uid: detected.uid,
            atqa: detected.atqa,
            sak: detected.sak,
            kind: forcedKind
        )
    }

    private func readBlock(_ block: Int) throws -> Data? {
        let response = try pn532(Data([0xD4, 0x40, 0x01, 0x30, UInt8(block)]))
        guard response.count >= 19, response[0] == 0xD5, response[2] == 0 else { return nil }
        return response.subdata(in: 3..<19)
    }

    private func writeBlock(_ block: Int, data: Data) throws -> Bool {
        guard data.count == 16 else { throw AppError.operation("块数据必须为 16 字节") }
        var command = Data([0xD4, 0x40, 0x01, 0xA0, UInt8(block)])
        command.append(data)
        let response = try pn532(command)
        return response.count >= 3 && response[0] == 0xD5 && response[2] == 0
    }

    private func validatedKey(_ keyHex: String) throws -> Data {
        do { return try HexCodec.data(from: keyHex, expectedBytes: 6) }
        catch { throw AppError.invalidKey }
    }

    private func authentication(for sector: Int, dump: DumpDocument, options: RestoreOptions) throws -> (key: Data, type: KeyType) {
        if let override = options.keyOverride, !override.isEmpty {
            return (try validatedKey(override), options.keyTypeOverride ?? .a)
        }
        let stored = dump.sectorKeys?[String(sector)]
        if let keyA = stored?.a { return (try validatedKey(keyA), options.keyTypeOverride ?? .a) }
        if let keyB = stored?.b, stored?.bAuthenticates != false {
            return (try validatedKey(keyB), options.keyTypeOverride ?? .b)
        }
        let type = options.keyTypeOverride ?? KeyType(rawValue: dump.keyType) ?? .a
        return (try validatedKey(dump.key), type)
    }

    private func readablePayload(_ data: Data) -> String {
        let printable = data.filter { $0 >= 0x20 && $0 <= 0x7E }
        if printable.count >= 3, let value = String(data: Data(printable), encoding: .ascii) {
            return value
        }
        return HexCodec.string(data, separator: " ")
    }
}
