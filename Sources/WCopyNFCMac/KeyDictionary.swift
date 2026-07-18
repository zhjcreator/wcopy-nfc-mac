import Foundation

enum KeyDictionaryPreset: String, CaseIterable, Identifiable {
    case quick = "快速默认键"
    case common = "常用公开键"
    case patterns = "弱模式扩展"
    case customOnly = "仅自定义"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .quick:
            return "mfoc 使用的 13 个高命中默认键"
        case .common:
            return "默认键、常见测试键及公开部署键"
        case .patterns:
            return "常用公开键，加重复字节、递增和递减弱模式"
        case .customOnly:
            return "只使用文本框和导入文件中的密钥"
        }
    }

    var keys: [String] {
        switch self {
        case .quick: return MifareKeyDictionary.quickKeys
        case .common: return MifareKeyDictionary.commonKeys
        case .patterns: return MifareKeyDictionary.weakPatternKeys
        case .customOnly: return []
        }
    }
}

enum OnlineKeyDictionarySource: String, CaseIterable, Identifiable {
    case proxmark3 = "Proxmark3 默认键"
    case mifareClassicTool = "MIFARE Classic Tool 扩展键"

    var id: String { rawValue }

    var url: URL {
        switch self {
        case .proxmark3:
            return URL(string: "https://raw.githubusercontent.com/RfidResearchGroup/proxmark3/master/client/dictionaries/mfc_default_keys.dic")!
        case .mifareClassicTool:
            return URL(string: "https://raw.githubusercontent.com/ikarus23/MifareClassicTool/master/Mifare%20Classic%20Tool/app/src/main/assets/key-files/extended-std.keys")!
        }
    }

    var license: String {
        switch self {
        case .proxmark3: return "来源项目 GPLv3+，以仓库为准"
        case .mifareClassicTool: return "来源项目 GPLv3，以仓库为准"
        }
    }
}

struct KeyDictionaryParseResult: Equatable {
    let keys: [String]
    let ignoredLines: Int
    let duplicateCount: Int
}

struct DownloadedKeyDictionary {
    let source: OnlineKeyDictionarySource
    let text: String
    let parsed: KeyDictionaryParseResult
}

enum MifareKeyDictionary {
    private static let keyRegex = try! NSRegularExpression(
        pattern: "(?i)(?<![0-9a-f])(?:0x)?([0-9a-f]{12})(?![0-9a-f])"
    )
    // The compact default set used by mfoc and many compatible tools.
    static let quickKeys = [
        "FFFFFFFFFFFF", "A0A1A2A3A4A5", "D3F7D3F7D3F7",
        "000000000000", "B0B1B2B3B4B5", "4D3A99C351DD",
        "1A982C7E459A", "AABBCCDDEEFF", "714C5C886E97",
        "587EE5F9350F", "A0478CC39091", "533CB6C723F6",
        "8FD0A4F256E9"
    ]

    // A compact, independently curated set of public defaults and weak test keys.
    // Larger GPL dictionaries can be imported at runtime instead of being vendored.
    static let commonKeys = unique(quickKeys + [
        "A5A4A3A2A1A0", "89ECA97F8C2A", "C0C1C2C3C4C5",
        "D0D1D2D3D4D5", "E00000000000", "FAFAFAFAFAFA",
        "FBFBFBFBFBFB", "010203040506", "0123456789AB",
        "123456789ABC", "ABCDEF123456", "123456ABCDEF",
        "A23456789123", "1A2B3C4D5E6F", "112233445566",
        "001122334455", "000000000001", "000000000002",
        "00000000000A", "00000000000B", "100000000000",
        "200000000000", "A00000000000", "B00000000000",
        "111111111111", "222222222222", "333333333333",
        "444444444444", "555555555555", "666666666666",
        "777777777777", "888888888888", "999999999999",
        "AAAAAAAAAAAA", "BBBBBBBBBBBB", "CCCCCCCCCCCC",
        "DDDDDDDDDDDD", "EEEEEEEEEEEE", "A0B0C0D0E0F0",
        "A1B1C1D1E1F1", "FC00018778F7", "0297927C0F77",
        "00000FFE2488", "26940B21FF5D", "A64598A77478",
        "5C598C9C58B5", "E4D2770A89BE", "722BFCC5375F",
        "F1D83F964314", "505249564141", "505249564142",
        "47524F555041", "47524F555042", "434F4D4D4F41",
        "434F4D4D4F42", "4AF9D7ADEBE4", "2BA9621E0A36",
        "4B0B20107CCB", "F4A9EF2AFC6D", "5C8FF9990DA2",
        "75CCB59C9BED", "D01AFEEB890A", "4B791BEA7BCC",
        "4823741386AB", "326587C3D17F", "2612C6DE84CA",
        "707B11FC1481", "605F5E5D5C5B", "314B49474956",
        "564C505F4D41", "484944204953", "204752454154"
    ])

    static let weakPatternKeys: [String] = {
        var generated = commonKeys
        for value in UInt16(0)...UInt16(255) {
            let byte = String(format: "%02X", value)
            generated.append(String(repeating: byte, count: 6))

            let ascending = (0..<6).map { String(format: "%02X", (Int(value) + $0) & 0xFF) }.joined()
            let descending = (0..<6).map { String(format: "%02X", (Int(value) - $0) & 0xFF) }.joined()
            generated.append(ascending)
            generated.append(descending)
        }
        return unique(generated)
    }()

    static func parse(_ text: String) -> KeyDictionaryParseResult {
        var keys: [String] = []
        var seen = Set<String>()
        var ignored = 0
        var duplicates = 0

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//") {
                continue
            }
            for marker in ["#", "//", ";"] {
                if let range = line.range(of: marker) { line = String(line[..<range.lowerBound]) }
            }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = keyRegex.matches(in: line, range: range)
            if matches.isEmpty {
                let compact = line
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: ":", with: "")
                    .replacingOccurrences(of: "-", with: "")
                if let data = try? HexCodec.data(from: compact, expectedBytes: 6) {
                    append(HexCodec.string(data), to: &keys, seen: &seen, duplicates: &duplicates)
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    ignored += 1
                }
                continue
            }
            for match in matches {
                guard let capture = Range(match.range(at: 1), in: line) else { continue }
                append(String(line[capture]).uppercased(), to: &keys, seen: &seen, duplicates: &duplicates)
            }
        }
        return KeyDictionaryParseResult(keys: keys, ignoredLines: ignored, duplicateCount: duplicates)
    }

    static func merged(_ groups: [[String]]) -> [String] {
        unique(groups.flatMap { $0.map { $0.uppercased() } })
    }

    private static func append(
        _ key: String,
        to keys: inout [String],
        seen: inout Set<String>,
        duplicates: inout Int
    ) {
        if seen.insert(key).inserted { keys.append(key) }
        else { duplicates += 1 }
    }

    private static func unique(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0.uppercased()).inserted }.map { $0.uppercased() }
    }
}
