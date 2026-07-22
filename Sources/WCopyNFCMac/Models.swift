import Foundation

enum AppError: LocalizedError {
    case invalidHex(String)
    case invalidKey
    case invalidUID
    case invalidSectors(String)
    case invalidDump(String)
    case incompleteDump(Int)
    case noDevice
    case notConnected
    case noCard
    case cancelled
    case transport(String)
    case unsupported(String)
    case operation(String)

    var errorDescription: String? {
        switch self {
        case .invalidHex(let value): return "无效十六进制数据：\(value)"
        case .invalidKey: return "密钥必须是 12 个十六进制字符（6 字节）"
        case .invalidUID: return "UID 必须是 8 个十六进制字符（4 字节）"
        case .invalidSectors(let value): return "无效扇区范围：\(value)"
        case .invalidDump(let reason): return "转储文件无效：\(reason)"
        case .incompleteDump(let count): return "MFD 要求完整转储，当前缺少 \(count) 个块"
        case .noDevice: return "未选择兼容的 USB-HID 设备"
        case .notConnected: return "读卡器尚未连接"
        case .noCard: return "未检测到卡片，请将卡片稳定放在感应区"
        case .cancelled: return "操作已取消"
        case .transport(let reason): return reason
        case .unsupported(let reason): return reason
        case .operation(let reason): return reason
        }
    }
}

struct MutationError: LocalizedError {
    let operation: String
    let attemptedBlocks: [Int]
    let acknowledgedBlocks: [Int]
    let reason: String

    var errorDescription: String? {
        "\(operation)期间发生错误，卡片可能已被部分修改：\(reason)"
    }
}

enum AppVersion {
    static let current = "1.3.0"
}

enum HexCodec {
    static func data(from value: String, expectedBytes: Int? = nil) throws -> Data {
        let cleaned = value
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
        guard !cleaned.isEmpty, cleaned.count.isMultiple(of: 2),
              cleaned.allSatisfy({ $0.isHexDigit }) else {
            throw AppError.invalidHex(value)
        }

        var result = Data()
        result.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
                throw AppError.invalidHex(value)
            }
            result.append(byte)
            index = next
        }
        if let expectedBytes, result.count != expectedBytes {
            throw AppError.invalidHex(value)
        }
        return result
    }

    static func string(_ data: Data, separator: String = "") -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: separator)
    }
}

func normalizeMifareKey(_ value: String) throws -> String {
    var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.lowercased().hasPrefix("0x") {
        cleaned.removeFirst(2)
    }
    do {
        return HexCodec.string(try HexCodec.data(from: cleaned, expectedBytes: 6))
    } catch {
        throw AppError.invalidKey
    }
}

enum KeyType: String, Codable, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"

    var id: String { rawValue }
    var command: UInt8 { self == .a ? 0x60 : 0x61 }
}

enum SAK19Compatibility {
    static func matches(sak: UInt8, atqa: UInt16, uidLength: Int) -> Bool {
        sak == 0x19 && atqa == 0x0004 && uidLength == 4
    }

    static func uidDerivedKeyCandidate(_ uid: Data) -> String? {
        guard uid.count == 4 else { return nil }
        return HexCodec.string(Data([
            uid[0] ^ uid[1], uid[0], uid[1], uid[2], uid[3], uid[2] ^ uid[3]
        ]))
    }
}

enum CardKind: String, Codable {
    case mini = "MIFARE Classic Mini"
    case classic1K = "MIFARE Classic 1K"
    case customClassic1K = "SAK 19 兼容 MIFARE Classic 1K"
    case classic2K = "MIFARE Classic 2K"
    case classic4K = "MIFARE Classic 4K"
    case unknown = "ISO 14443-A"

    var sectorCount: Int {
        switch self {
        case .mini: return 5
        case .classic1K, .customClassic1K: return 16
        case .classic2K: return 32
        case .classic4K: return 40
        case .unknown: return 16
        }
    }

    var blockCount: Int {
        switch self {
        case .mini: return 20
        case .classic1K, .customClassic1K, .unknown: return 64
        case .classic2K: return 128
        case .classic4K: return 256
        }
    }

    static func detect(sak: UInt8, atqa: UInt16, uidLength: Int) -> CardKind {
        if SAK19Compatibility.matches(sak: sak, atqa: atqa, uidLength: uidLength) {
            return .customClassic1K
        }
        switch sak & 0x7F {
        case 0x09: return .mini
        case 0x08: return .classic1K
        case 0x18: return .classic4K
        default: return .unknown
        }
    }

    static func storedValue(_ value: String) -> CardKind? {
        if value == "定制 MIFARE Classic 1K (SAK 19)" { return .customClassic1K }
        return CardKind(rawValue: value)
    }
}

enum CardScanMode: String, CaseIterable, Identifiable {
    case automatic = "自动识别（含 SAK 19）"
    case sak19Classic1K = "SAK 19 兼容 Classic 1K"
    case mini = "强制 Classic Mini"
    case classic1K = "强制 Classic 1K"
    case classic2K = "强制 Classic 2K"
    case classic4K = "强制 Classic 4K"

    var id: String { rawValue }

    var forcedKind: CardKind? {
        switch self {
        case .automatic: return nil
        case .sak19Classic1K: return .customClassic1K
        case .mini: return .mini
        case .classic1K: return .classic1K
        case .classic2K: return .classic2K
        case .classic4K: return .classic4K
        }
    }

    var warning: String? {
        switch self {
        case .automatic: return nil
        case .sak19Classic1K: return "将按实测 SAK 19 兼容布局使用 16 扇区 / 64 块"
        case .mini: return "将按 5 扇区 / 20 块扫描"
        case .classic1K: return "将按 16 扇区 / 64 块扫描"
        case .classic2K: return "将按 32 扇区 / 128 块扫描"
        case .classic4K: return "将按 40 扇区 / 256 块扫描"
        }
    }
}

enum CardLayout {
    static func firstBlock(of sector: Int) -> Int {
        sector < 32 ? sector * 4 : 128 + (sector - 32) * 16
    }

    static func blockCount(in sector: Int) -> Int {
        sector < 32 ? 4 : 16
    }

    static func trailerBlock(of sector: Int) -> Int {
        firstBlock(of: sector) + blockCount(in: sector) - 1
    }

    static func sector(containing block: Int) -> Int {
        block < 128 ? block / 4 : 32 + (block - 128) / 16
    }

    static func isTrailer(_ block: Int) -> Bool {
        trailerBlock(of: sector(containing: block)) == block
    }

    static func keyBIsReadableData(in trailer: Data) -> Bool? {
        guard trailer.count == 16 else { return nil }
        let byte6 = trailer[6]
        let byte7 = trailer[7]
        let byte8 = trailer[8]
        let valid = ((byte6 & 0x0F) ^ (byte7 >> 4)) == 0x0F
            && ((byte6 >> 4) ^ (byte8 & 0x0F)) == 0x0F
            && ((byte7 & 0x0F) ^ (byte8 >> 4)) == 0x0F
        guard valid else { return nil }

        let c1 = (byte7 >> 7) & 1
        let c2 = (byte8 >> 3) & 1
        let c3 = (byte8 >> 7) & 1
        let code = (c1 << 2) | (c2 << 1) | c3
        return code == 0b000 || code == 0b001 || code == 0b010
    }

    static func manufacturerBlock(_ block: Data, matchesUID uid: Data) -> Bool {
        guard block.count == 16, uid.count == 4, block.prefix(4) == uid else { return false }
        return block[4] == uid.reduce(UInt8(0), ^)
    }
}

struct CardTarget: Equatable {
    let uid: Data
    let atqa: UInt16
    let sak: UInt8
    let kind: CardKind

    var uidText: String { HexCodec.string(uid, separator: ":") }
    var atqaText: String { String(format: "%04X", atqa) }
    var sakText: String { String(format: "%02X", sak) }
}

struct SectorKeys: Codable, Equatable {
    var a: String?
    var b: String?
    var bAuthenticates: Bool?

    init(a: String?, b: String?, bAuthenticates: Bool? = nil) {
        self.a = a
        self.b = b
        self.bAuthenticates = bAuthenticates
    }
}

struct DumpDocument: Codable, Equatable {
    var version: Int
    var uid: String
    var cardType: String?
    var atqa: String?
    var sak: String?
    var key: String
    var keyType: String
    var blocks: [String: String]
    var sectorKeys: [String: SectorKeys]?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case version, uid, cardType, atqa, sak, key, blocks, sectorKeys, createdAt
        case keyType = "key_type"
    }

    init(
        version: Int = 1,
        uid: String,
        cardType: String? = nil,
        atqa: String? = nil,
        sak: String? = nil,
        key: String = "FFFFFFFFFFFF",
        keyType: String = "A",
        blocks: [String: String],
        sectorKeys: [String: SectorKeys]? = nil,
        createdAt: Date? = Date()
    ) {
        self.version = version
        self.uid = uid
        self.cardType = cardType
        self.atqa = atqa
        self.sak = sak
        self.key = key
        self.keyType = keyType
        self.blocks = blocks
        self.sectorKeys = sectorKeys
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        uid = try values.decode(String.self, forKey: .uid)
        let storedCardType = try values.decodeIfPresent(String.self, forKey: .cardType)
        cardType = storedCardType.flatMap { CardKind.storedValue($0)?.rawValue ?? $0 }
        atqa = try values.decodeIfPresent(String.self, forKey: .atqa)
        sak = try values.decodeIfPresent(String.self, forKey: .sak)
        key = try values.decodeIfPresent(String.self, forKey: .key) ?? "FFFFFFFFFFFF"
        keyType = try values.decodeIfPresent(String.self, forKey: .keyType) ?? "A"
        blocks = try values.decode([String: String].self, forKey: .blocks)
        sectorKeys = try values.decodeIfPresent([String: SectorKeys].self, forKey: .sectorKeys)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    var sortedBlocks: [(Int, Data)] {
        blocks.compactMap { key, value in
            guard let block = Int(key), let data = try? HexCodec.data(from: value, expectedBytes: 16) else {
                return nil
            }
            return (block, data)
        }.sorted { $0.0 < $1.0 }
    }

    var inferredKind: CardKind {
        if let cardType, let kind = CardKind.storedValue(cardType) { return kind }
        let maximum = blocks.keys.compactMap(Int.init).max() ?? 63
        if maximum >= 128 { return .classic4K }
        if maximum >= 64 { return .classic2K }
        if maximum < 20 && blocks.count <= 20 { return .mini }
        return .classic1K
    }

    func validated() throws -> DumpDocument {
        guard (try? HexCodec.data(from: uid)) != nil else {
            throw AppError.invalidDump("UID 格式错误")
        }
        if let cardType, CardKind.storedValue(cardType) == nil {
            throw AppError.invalidDump("未知卡型：\(cardType)")
        }
        guard (try? HexCodec.data(from: key, expectedBytes: 6)) != nil else {
            throw AppError.invalidDump("默认密钥格式错误")
        }
        guard KeyType(rawValue: keyType) != nil else {
            throw AppError.invalidDump("密钥类型必须为 A 或 B")
        }
        let kind = inferredKind
        guard !blocks.isEmpty else {
            throw AppError.invalidDump("转储不包含任何数据块")
        }
        var parsedBlocks = Set<Int>()
        for (block, value) in blocks {
            guard let number = Int(block), number >= 0, number < kind.blockCount,
                   block == String(number), parsedBlocks.insert(number).inserted,
                   (try? HexCodec.data(from: value, expectedBytes: 16)) != nil else {
                throw AppError.invalidDump("块 \(block) 索引重复、格式不规范、超出 \(kind.rawValue) 范围或不是 16 字节")
            }
        }
        var parsedSectors = Set<Int>()
        for (sector, keys) in sectorKeys ?? [:] {
            guard let number = Int(sector), number >= 0, number < kind.sectorCount,
                  sector == String(number), parsedSectors.insert(number).inserted else {
                throw AppError.invalidDump("无效扇区密钥索引：\(sector)")
            }
            for key in [keys.a, keys.b].compactMap({ $0 }) {
                guard (try? HexCodec.data(from: key, expectedBytes: 6)) != nil else {
                    throw AppError.invalidDump("扇区 \(sector) 的密钥格式错误")
                }
            }
        }
        return self
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func fromJSON(_ data: Data) throws -> DumpDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(DumpDocument.self, from: data).validated()
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.invalidDump(error.localizedDescription)
        }
    }

    func mfdData() throws -> Data {
        let validated = try validated()
        let expected = validated.inferredKind.blockCount
        let decoded = Dictionary(uniqueKeysWithValues: validated.sortedBlocks)
        let missing = (0..<expected).filter { decoded[$0] == nil }
        guard missing.isEmpty else { throw AppError.incompleteDump(missing.count) }
        var result = Data()
        result.reserveCapacity(expected * 16)
        for block in 0..<expected {
            var data = decoded[block]!
            if CardLayout.isTrailer(block) {
                let sector = CardLayout.sector(containing: block)
                guard let keys = validated.sectorKeys?[String(sector)],
                      let keyA = keys.a, let keyB = keys.b else {
                    throw AppError.invalidDump("导出 MFD 前必须知道扇区 \(sector) 的 Key A 和 Key B；卡片读取会隐藏 Key A")
                }
                data.replaceSubrange(0..<6, with: try HexCodec.data(from: keyA, expectedBytes: 6))
                data.replaceSubrange(10..<16, with: try HexCodec.data(from: keyB, expectedBytes: 6))
            }
            result.append(data)
        }
        return result
    }

    static func fromMFD(_ data: Data) throws -> DumpDocument {
        let kind: CardKind
        switch data.count {
        case 320: kind = .mini
        case 1024: kind = .classic1K
        case 2048: kind = .classic2K
        case 4096: kind = .classic4K
        default:
            throw AppError.invalidDump("MFD 大小必须为 320、1024、2048 或 4096 字节")
        }
        var blocks: [String: String] = [:]
        var sectorKeys: [String: SectorKeys] = [:]
        for block in 0..<kind.blockCount {
            let range = (block * 16)..<((block + 1) * 16)
            let blockData = data.subdata(in: range)
            blocks[String(block)] = HexCodec.string(blockData)
            if CardLayout.isTrailer(block) {
                let sector = CardLayout.sector(containing: block)
                sectorKeys[String(sector)] = SectorKeys(
                    a: HexCodec.string(blockData.prefix(6)),
                    b: HexCodec.string(blockData.suffix(6)),
                    bAuthenticates: CardLayout.keyBIsReadableData(in: blockData).map(!)
                )
            }
        }
        let uid = HexCodec.string(data.prefix(4))
        let firstKey = sectorKeys["0"]?.a ?? "FFFFFFFFFFFF"
        return DumpDocument(uid: uid, cardType: kind.rawValue, key: firstKey, blocks: blocks, sectorKeys: sectorKeys)
    }
}

struct SectorKeyResult: Identifiable, Equatable {
    let sector: Int
    var keyA: String?
    var keyB: String?
    var keyBAuthenticates: Bool?
    var id: Int { sector }
    var foundAny: Bool { keyA != nil || keyB != nil }

    init(sector: Int, keyA: String? = nil, keyB: String? = nil, keyBAuthenticates: Bool? = nil) {
        self.sector = sector
        self.keyA = keyA
        self.keyB = keyB
        self.keyBAuthenticates = keyBAuthenticates
    }
}

struct KeyCheckOutcome {
    let target: CardTarget
    let sectorKeys: [Int: SectorKeyResult]
    let blocks: [Int: Data]
    let failedBlocks: [Int]
    let attempts: Int
    let candidateCount: Int
}

struct ReadResult {
    let target: CardTarget
    let blocks: [Int: Data]
    let failedSectors: [Int]
    let failedBlocks: [Int]

    func dump(key: String, keyType: KeyType, sectorKeys: [Int: SectorKeyResult]? = nil) -> DumpDocument {
        let encodedBlocks = Dictionary(uniqueKeysWithValues: blocks.map {
            (String($0.key), HexCodec.string($0.value))
        })
        let knownKeys: [Int: SectorKeyResult]
        if let sectorKeys {
            knownKeys = sectorKeys
        } else {
            knownKeys = Dictionary(uniqueKeysWithValues: Set(blocks.keys.map(CardLayout.sector)).map { sector in
                let value = key.uppercased()
                return (sector, SectorKeyResult(
                    sector: sector,
                    keyA: keyType == .a ? value : nil,
                    keyB: keyType == .b ? value : nil,
                    keyBAuthenticates: keyType == .b ? true : nil
                ))
            })
        }
        let encodedKeys = Optional(knownKeys).map { values in
            Dictionary(uniqueKeysWithValues: values.map {
                (String($0.key), SectorKeys(
                    a: $0.value.keyA,
                    b: $0.value.keyB,
                    bAuthenticates: $0.value.keyBAuthenticates
                ))
            })
        }
        return DumpDocument(
            uid: HexCodec.string(target.uid),
            cardType: target.kind.rawValue,
            atqa: target.atqaText,
            sak: target.sakText,
            key: key,
            keyType: keyType.rawValue,
            blocks: encodedBlocks,
            sectorKeys: encodedKeys
        )
    }
}

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw AppError.cancelled }
    }
}

func parseSectors(_ specification: String, maximum: Int = 39) throws -> [Int] {
    let trimmed = specification.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AppError.invalidSectors(specification) }
    var sectors = Set<Int>()
    for rawPart in trimmed.split(separator: ",") {
        let part = rawPart.trimmingCharacters(in: .whitespaces)
        if let dash = part.firstIndex(of: "-") {
            guard let lower = Int(part[..<dash]), let upper = Int(part[part.index(after: dash)...]),
                  lower <= upper, lower >= 0, upper <= maximum else {
                throw AppError.invalidSectors(specification)
            }
            sectors.formUnion(lower...upper)
        } else {
            guard let sector = Int(part), sector >= 0, sector <= maximum else {
                throw AppError.invalidSectors(specification)
            }
            sectors.insert(sector)
        }
    }
    guard !sectors.isEmpty else { throw AppError.invalidSectors(specification) }
    return sectors.sorted()
}
