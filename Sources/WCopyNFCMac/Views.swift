import AppKit
import SwiftUI

private let brandTeal = Color(red: 0.04, green: 0.52, blue: 0.48)
private let brandOrange = Color(red: 0.95, green: 0.48, blue: 0.18)

struct WCopyNFCMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1060, minHeight: 700)
                .task { model.refreshDevices() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新 USB 设备") { model.refreshDevices() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.busy)
                Button(model.connectionState == .connected ? "断开读卡器" : "连接读卡器") {
                    model.connectionState == .connected ? model.disconnect() : model.connect()
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(model.busy)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 280)
        } detail: {
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [Color(nsColor: .windowBackgroundColor), brandTeal.opacity(0.035)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    Group {
                        switch model.page {
                        case .overview: OverviewView()
                        case .read: ReadCardView()
                        case .keys: KeyCheckView()
                        case .restore: RestoreView()
                        case .uid: UIDView()
                        case .format: FormatView()
                        case .libnfc: LibNFCView()
                        case .diagnostics: DiagnosticsView()
                        }
                    }
                    .padding(30)
                    .frame(maxWidth: 1180, alignment: .topLeading)
                }

                if model.busy { OperationBar() }
            }
            .toolbar { DeviceToolbar() }
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("完成", isPresented: Binding(
            get: { model.noticeMessage != nil },
            set: { if !$0 { model.noticeMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.noticeMessage = nil }
        } message: {
            Text(model.noticeMessage ?? "")
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [brandTeal, brandTeal.opacity(0.68)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text("wCopy NFC")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("FOR MAC")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(2.1)
                        .foregroundStyle(brandTeal)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 17)
            .padding(.bottom, 14)

            List(NavigationPage.allCases, selection: $model.page) { page in
                Label(page.rawValue, systemImage: page.icon)
                    .font(.system(size: 13, weight: .medium))
                    .tag(page)
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 10) {
                Divider()
                HStack(spacing: 9) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: statusColor.opacity(0.45), radius: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.connectionState.title)
                            .font(.caption.weight(.semibold))
                        Text(model.selectedDevice?.usbID ?? "0416:B008 / B030")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("13.56 MHz MIFARE Classic")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .connected: return brandTeal
        case .connecting: return brandOrange
        case .incompatible: return .red
        case .disconnected: return .secondary
        }
    }
}

private struct DeviceToolbar: ToolbarContent {
    @EnvironmentObject private var model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("设备", selection: $model.selectedDeviceID) {
                if model.devices.isEmpty {
                    Text("未发现设备").tag(Optional<UInt64>.none)
                }
                ForEach(model.devices) { device in
                    Text("\(device.productName) · \(device.usbID)").tag(Optional(device.id))
                }
            }
            .frame(width: 255)
            .disabled(model.busy || model.connectionState == .connected)

            Button { model.refreshDevices() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新 USB 设备")
            .disabled(model.busy)

            Button(model.connectionState == .connected ? "断开" : "连接") {
                model.connectionState == .connected ? model.disconnect() : model.connect()
            }
            .buttonStyle(.borderedProminent)
            .tint(model.connectionState == .connected ? .secondary : brandTeal)
            .disabled(model.busy || (model.devices.isEmpty && model.connectionState != .connected))
        }
    }
}

private struct OperationBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 13) {
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(brandTeal)
                .frame(width: 180)
            Text(model.operationText)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer()
            if model.operationCancellable {
                Button("取消") { model.cancelOperation() }
                    .buttonStyle(.borderless)
            } else {
                Text("请勿移动卡片或断开设备")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 7)
        .padding(20)
    }
}

private struct PageHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(brandTeal)
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 7)
    }
}

private struct Surface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.07)))
    }
}

private struct EmptyState: View {
    let title: String
    let icon: String
    let description: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

private struct MetricCard: View {
    let icon: String
    let label: String
    let value: String
    var accent: Color = brandTeal

    var body: some View {
        Surface {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(
                eyebrow: "NSR106-IDIC V",
                title: greeting,
                subtitle: "面向 wCopy USB 读卡器的原生 macOS 工作台。设备识别、协议握手和卡片状态分别验证，不会用“已发现 USB”冒充“可以读卡”。"
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                MetricCard(icon: "cable.connector", label: "USB 设备", value: model.selectedDevice?.usbID ?? "未发现")
                MetricCard(icon: "checkmark.shield", label: "协议状态", value: model.connectionState.title, accent: model.connectionState == .connected ? brandTeal : brandOrange)
                MetricCard(icon: "cpu", label: "固件响应", value: model.firmware)
                MetricCard(icon: "number", label: "序列计数器", value: model.sequence)
            }

            HStack(alignment: .top, spacing: 16) {
                Surface {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("开始工作", systemImage: "sparkles")
                            .font(.headline)
                        Text(model.connectionState == .connected
                             ? "读卡器协议已就绪。将卡片放在感应区后，可直接读取、备份或检查常见密钥。"
                             : "连接读卡器并完成协议握手后，卡片工具才会解锁。首次同步失败时，请拔插设备后重试。")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(model.connectionState == .connected ? "读取卡片" : "连接读卡器") {
                                if model.connectionState == .connected { model.page = .read }
                                else { model.connect() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(brandTeal)
                            .disabled(model.devices.isEmpty && model.connectionState != .connected)
                            Button("密钥检查") { model.page = .keys }
                                .buttonStyle(.bordered)
                                .disabled(model.connectionState != .connected)
                        }
                    }
                }
                Surface {
                    VStack(alignment: .leading, spacing: 13) {
                        Label("能力边界", systemImage: "scope")
                            .font(.headline)
                        CapabilityRow(title: "13.56 MHz", detail: "Classic Mini / 1K / 2K / 4K / SAK 19", ready: true)
                        CapabilityRow(title: "备份格式", detail: "JSON 与标准 .mfd", ready: true)
                        CapabilityRow(title: "125 kHz ID 卡", detail: "上游协议尚未解出", ready: false)
                        Text("0416:B008 会自动尝试 B030 的已知 HID/PN532 协议，并以真实握手结果判定兼容性。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var greeting: String {
        switch model.connectionState {
        case .connected: return "读卡器已经就绪"
        case .connecting: return "正在建立安全连接"
        case .incompatible: return "USB 已发现，协议未通过"
        case .disconnected: return model.devices.isEmpty ? "连接你的 wCopy 读卡器" : "发现了 wCopy 设备"
        }
    }
}

private struct CapabilityRow: View {
    let title: String
    let detail: String
    let ready: Bool

    var body: some View {
        HStack {
            Image(systemName: ready ? "checkmark.circle.fill" : "minus.circle.fill")
                .foregroundStyle(ready ? brandTeal : brandOrange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct ReadCardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var key = "FFFFFFFFFFFF"
    @State private var keyType: KeyType = .a
    @State private var readAll = true
    @State private var sectors = "0-15"
    @State private var scanMode: CardScanMode = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(eyebrow: "13.56 MHz", title: "读取与备份", subtitle: "选择认证密钥，读取 MIFARE Classic 扇区，并保存为可移植 JSON 或标准 MFD。")
            HStack(alignment: .top, spacing: 16) {
                Surface {
                    Form {
                        SecureField("密钥", text: $key)
                            .textFieldStyle(.roundedBorder)
                        Picker("密钥类型", selection: $keyType) {
                            ForEach(KeyType.allCases) { Text("Key \($0.rawValue)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker("卡型模式", selection: $scanMode) {
                            ForEach(CardScanMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        if let warning = scanMode.warning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(brandOrange)
                        }
                        Toggle("根据卡片类型读取全部扇区", isOn: $readAll)
                        TextField("扇区，例如 0-15", text: $sectors)
                            .disabled(readAll)
                        Button {
                            model.readCard(
                                key: key,
                                keyType: keyType,
                                readAll: readAll,
                                sectors: sectors,
                                scanMode: scanMode
                            )
                        } label: {
                            Label("开始读取", systemImage: "wave.3.right.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(brandTeal)
                        .disabled(!model.canOperate)
                    }
                    .formStyle(.grouped)
                }
                .frame(width: 345)

                ResultSummary()
            }

            if let result = model.readResult {
                Surface {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("内存块").font(.headline)
                            Spacer()
                            Text("\(result.blocks.count) BLOCKS").font(.caption.monospaced().weight(.bold)).foregroundStyle(brandTeal)
                        }
                        BlockTable(blocks: result.blocks)
                            .frame(minHeight: 240)
                    }
                }
            }
        }
    }
}

private struct ResultSummary: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Surface {
            if let result = model.readResult {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.target.kind.rawValue).font(.headline)
                            Text("ISO 14443-A").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "creditcard.and.123")
                            .font(.system(size: 25))
                            .foregroundStyle(brandTeal)
                    }
                    Divider()
                    DataPair(label: "UID", value: result.target.uidText)
                    DataPair(label: "ATQA / SAK", value: "\(result.target.atqaText) / \(result.target.sakText)")
                    DataPair(label: "认证失败", value: result.failedSectors.isEmpty ? "无" : result.failedSectors.map(String.init).joined(separator: ", "))
                    DataPair(label: "读取失败块", value: result.failedBlocks.isEmpty ? "无" : result.failedBlocks.map(String.init).joined(separator: ", "))
                    HStack {
                        Button("保存 JSON") { saveDump(mfd: false) }
                        Button("导出 MFD") { saveDump(mfd: true) }
                            .disabled(result.blocks.count != result.target.kind.blockCount)
                    }
                }
            } else {
                EmptyState(title: "等待卡片", icon: "wave.3.right", description: "读取后将在这里显示 UID、卡型和扇区状态。")
            }
        }
    }

    private func saveDump(mfd: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = mfd ? [.data] : [.json]
        panel.nameFieldStringValue = "card.\(mfd ? "mfd" : "json")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportActiveDump(to: url, mfd: mfd)
    }
}

private struct DataPair: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced()).textSelection(.enabled)
        }
    }
}

private struct BlockTable: View {
    let blocks: [Int: Data]

    var body: some View {
        Table(rows) {
            TableColumn("扇区") { row in
                Text(String(CardLayout.sector(containing: row.id))).monospacedDigit()
            }.width(55)
            TableColumn("块") { row in
                HStack(spacing: 6) {
                    Text(String(row.id)).monospacedDigit()
                    if row.id == 0 { Text("UID").font(.caption2).foregroundStyle(brandOrange) }
                    else if CardLayout.isTrailer(row.id) { Text("TRAILER").font(.caption2).foregroundStyle(brandTeal) }
                }
            }.width(85)
            TableColumn("16 字节数据") { row in
                Text(HexCodec.string(row.data, separator: " "))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var rows: [BlockRow] {
        blocks.map { BlockRow(id: $0.key, data: $0.value) }.sorted { $0.id < $1.id }
    }
}

private struct BlockRow: Identifiable {
    let id: Int
    let data: Data
}

private struct KeyCheckView: View {
    @EnvironmentObject private var model: AppModel
    @State private var customKeys = ""
    @State private var preset: KeyDictionaryPreset = .common
    @State private var importedFileName = ""
    @State private var downloading = false
    @State private var parsing = false
    @State private var parsedCustom = KeyDictionaryParseResult(keys: [], ignoredLines: 0, duplicateCount: 0)
    @State private var candidateCount = MifareKeyDictionary.commonKeys.count
    @State private var parsedText = ""
    @State private var parseTask: Task<Void, Never>?
    @State private var scanMode: CardScanMode = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(eyebrow: "DICTIONARY", title: "默认密钥检查", subtitle: "按命中概率扫描公开默认键和弱模式，逐扇区检查 Key A 与 Key B。只检查候选字典，不遍历完整 48 位密钥空间。")
            HStack(alignment: .top, spacing: 16) {
                Surface {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("候选词典").font(.headline)
                            Spacer()
                            Text("\(candidateCount) KEYS")
                                .font(.caption.monospaced().weight(.bold))
                                .foregroundStyle(brandTeal)
                        }
                        Picker("内置词典", selection: $preset) {
                            ForEach(KeyDictionaryPreset.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        Text(preset.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("卡型模式", selection: $scanMode) {
                            ForEach(CardScanMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        if let warning = scanMode.warning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(brandOrange)
                        }
                        if scanMode == .automatic || scanMode == .sak19Classic1K {
                            Label("检测到 SAK 19 兼容卡后，将按 UID 自动生成并实际验证扇区 1/15 派生密钥候选。", systemImage: "key.radiowaves.forward")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        HStack {
                            Text("自定义 / 导入").font(.callout.weight(.semibold))
                            Spacer()
                            Menu {
                                ForEach(OnlineKeyDictionarySource.allCases) { source in
                                    Button("\(source.rawValue) · \(source.license)") {
                                        downloadDictionary(source)
                                    }
                                }
                            } label: {
                                Label(downloading ? "下载中" : "在线载入", systemImage: "icloud.and.arrow.down")
                            }
                            .disabled(model.busy || downloading)
                            Button("导入词典…") { importDictionary() }
                                .disabled(model.busy || downloading)
                            if !customKeys.isEmpty {
                                Button("清除") {
                                    customKeys = ""
                                    importedFileName = ""
                                }
                            }
                        }
                        TextEditor(text: $customKeys)
                            .font(.body.monospaced())
                            .frame(height: 150)
                            .padding(6)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                        Text(dictionaryCaption)
                            .font(.caption).foregroundStyle(.secondary)
                        if candidateCount > 250 {
                            Label("1K 卡最多约 \(candidateCount * 32) 次候选认证，请保持卡片稳定；可随时取消。", systemImage: "clock.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(brandOrange)
                        }
                        Button("检查所有扇区") {
                            model.checkKeys(
                                preset: preset,
                                customKeys: parsedCustom.keys,
                                scanMode: scanMode
                            )
                        }
                            .buttonStyle(.borderedProminent).tint(brandTeal)
                            .disabled(!model.canOperate || parsing)
                    }
                }
                .frame(width: 385)
                Surface {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("扇区密钥").font(.headline)
                            Spacer()
                            if !model.keyResults.isEmpty {
                                Text("\(foundSlotCount)/\(model.keyResults.count * 2) FOUND")
                                    .font(.caption.monospaced().weight(.bold)).foregroundStyle(brandTeal)
                            }
                        }
                        if model.keyCheckAttempts > 0 {
                            HStack(spacing: 18) {
                                Label("\(model.keyCandidateCount) 个候选", systemImage: "list.bullet.rectangle")
                                Label("\(model.keyCheckAttempts) 次认证", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        if model.keyResults.isEmpty {
                            EmptyState(title: "尚无结果", icon: "key.horizontal", description: "运行检查后显示 Key A / Key B。")
                        } else {
                            Table(model.keyResults.values.sorted { $0.sector < $1.sector }) {
                                TableColumn("扇区") { Text(String($0.sector)).monospacedDigit() }.width(55)
                                TableColumn("Key A") { result in
                                    SectorKeyCell(
                                        sector: result.sector,
                                        type: .a,
                                        value: result.keyA,
                                        allowsPaste: true,
                                        canOperate: model.canOperate,
                                        onPaste: { value, sector, type in
                                            model.pasteSectorKey(value, sector: sector, type: type)
                                        },
                                        onError: { model.errorMessage = $0 }
                                    )
                                }
                                TableColumn("Key B") { result in
                                    HStack(spacing: 5) {
                                        SectorKeyCell(
                                            sector: result.sector,
                                            type: .b,
                                            value: result.keyB,
                                            allowsPaste: result.keyBAuthenticates != false,
                                            canOperate: model.canOperate,
                                            onPaste: { value, sector, type in
                                                model.pasteSectorKey(value, sector: sector, type: type)
                                            },
                                            onError: { model.errorMessage = $0 }
                                        )
                                        if result.keyBAuthenticates == false {
                                            Text("DATA")
                                                .font(.caption2)
                                                .foregroundStyle(brandOrange)
                                                .help("访问位允许读取 Key B 字段，但禁止使用它认证")
                                        }
                                    }
                                }
                            }
                            .frame(minHeight: 280)
                        }
                    }
                }
            }
            Surface {
                VStack(alignment: .leading, spacing: 8) {
                    Label("强制模式只改变扫描范围，不会改写卡片 SAK、ATQA 或 UID。", systemImage: "shield.checkered")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Label("公开词典来源", systemImage: "network")
                        .font(.headline)
                    Text("快速集与 mfoc 的默认键集合一致；更大的社区词典可从 Proxmark3 或 MIFARE Classic Tool 下载后直接导入。应用不内嵌这些 GPL 项目提供的词典文件。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        Link("mfoc", destination: URL(string: "https://github.com/nfc-tools/mfoc")!)
                        Link("Proxmark3 字典", destination: URL(string: "https://github.com/RfidResearchGroup/proxmark3/blob/master/client/dictionaries/mfc_default_keys.dic")!)
                        Link("MIFARE Classic Tool", destination: URL(string: "https://github.com/ikarus23/MifareClassicTool")!)
                    }
                    .font(.caption)
                }
            }
        }
        .onChange(of: customKeys) { value in parseCustom(value) }
        .onChange(of: preset) { _ in updateCandidateCount() }
    }

    private var foundSlotCount: Int {
        model.keyResults.values.reduce(0) { $0 + ($1.keyA == nil ? 0 : 1) + ($1.keyB == nil ? 0 : 1) }
    }

    private var dictionaryCaption: String {
        if customKeys.isEmpty { return "支持 .dic、.keys、.txt；每行可含注释或 0x 前缀。" }
        if parsing { return "正在解析词典…" }
        let source = importedFileName.isEmpty ? "自定义文本" : importedFileName
        return "\(source)：解析 \(parsedCustom.keys.count) 个，去重 \(parsedCustom.duplicateCount) 个，忽略 \(parsedCustom.ignoredLines) 行。"
    }

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            customKeys = try String(contentsOf: url, encoding: .utf8)
            importedFileName = url.lastPathComponent
        } catch {
            model.errorMessage = "无法读取词典：\(error.localizedDescription)"
        }
    }

    private func downloadDictionary(_ source: OnlineKeyDictionarySource) {
        downloading = true
        model.downloadDictionary(source) { result in
            downloading = false
            switch result {
            case .success(let dictionary):
                guard !dictionary.parsed.keys.isEmpty else {
                    model.errorMessage = "在线词典中没有可识别的 6 字节密钥"
                    return
                }
                parseTask?.cancel()
                parsedCustom = dictionary.parsed
                parsedText = dictionary.text
                customKeys = dictionary.text
                parsing = false
                updateCandidateCount()
                importedFileName = "\(source.rawValue)（在线）"
                model.noticeMessage = "已载入 \(dictionary.parsed.keys.count) 个密钥；许可信息请以来源仓库为准（\(source.license)）"
            case .failure(let error):
                model.errorMessage = "下载词典失败：\(error.localizedDescription)"
            }
        }
    }

    private func parseCustom(_ text: String) {
        parseTask?.cancel()
        if parsedText == text {
            parsing = false
            updateCandidateCount()
            return
        }
        if text.isEmpty {
            parsedText = ""
            parsedCustom = KeyDictionaryParseResult(keys: [], ignoredLines: 0, duplicateCount: 0)
            parsing = false
            updateCandidateCount()
            return
        }
        parsing = true
        parseTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                MifareKeyDictionary.parse(text)
            }.value
            guard !Task.isCancelled, customKeys == text else { return }
            parsedCustom = result
            parsedText = text
            parsing = false
            updateCandidateCount()
        }
    }

    private func updateCandidateCount() {
        candidateCount = MifareKeyDictionary.merged([preset.keys, parsedCustom.keys]).count
    }
}

private struct SectorKeyCell: View {
    let sector: Int
    let type: KeyType
    let value: String?
    let allowsPaste: Bool
    let canOperate: Bool
    let onPaste: (String, Int, KeyType) -> Void
    let onError: (String) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(value ?? "-")
                .monospaced()
                .textSelection(.enabled)
            Spacer(minLength: 2)
            Menu {
                Button("复制 Key \(type.rawValue)", systemImage: "doc.on.doc") {
                    copyKey()
                }
                .disabled(value == nil)
                Button("粘贴并验证 Key \(type.rawValue)", systemImage: "doc.on.clipboard") {
                    pasteKey()
                }
                .disabled(!allowsPaste || !canOperate)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(allowsPaste ? "复制或粘贴扇区密钥" : "此 Key B 字段是数据，不能粘贴认证密钥")
        }
        .contextMenu {
            Button("复制 Key \(type.rawValue)", systemImage: "doc.on.doc") {
                copyKey()
            }
            .disabled(value == nil)
            Button("粘贴并验证 Key \(type.rawValue)", systemImage: "doc.on.clipboard") {
                pasteKey()
            }
            .disabled(!allowsPaste || !canOperate)
        }
    }

    private func copyKey() {
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func pasteKey() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            onError("剪贴板中没有文本密钥")
            return
        }
        onPaste(value, sector, type)
    }
}

private struct RestoreView: View {
    @EnvironmentObject private var model: AppModel
    @State private var keyOverride = ""
    @State private var keyType: KeyType = .a
    @State private var useOverride = false
    @State private var block0 = false
    @State private var trailers = false
    @State private var verify = true
    @State private var confirming = false
    @State private var scanMode: CardScanMode = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(eyebrow: "RESTORE", title: "恢复转储", subtitle: "导入上游兼容 JSON 或标准 MFD。默认只恢复普通数据块，制造块和扇区尾块保持不变。")
            HStack(alignment: .top, spacing: 16) {
                Surface {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("转储来源", systemImage: "doc.badge.arrow.up").font(.headline)
                        if let dump = model.importedDump {
                            DataPair(label: "UID", value: dump.uid)
                            DataPair(label: "卡型", value: dump.inferredKind.rawValue)
                            DataPair(label: "块数", value: String(dump.blocks.count))
                        } else {
                            Text("尚未选择文件").foregroundStyle(.secondary)
                        }
                        Button("导入 JSON / MFD") { importDump() }
                            .disabled(model.busy)
                    }
                }
                .frame(width: 330)
                Surface {
                    Form {
                        Toggle("覆盖转储中的认证密钥", isOn: $useOverride)
                        SecureField("当前卡片密钥", text: $keyOverride).disabled(!useOverride)
                        Picker("密钥类型", selection: $keyType) {
                            ForEach(KeyType.allCases) { Text("Key \($0.rawValue)").tag($0) }
                        }.disabled(!useOverride)
                        Picker("目标卡型模式", selection: $scanMode) {
                            ForEach(CardScanMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        if let warning = scanMode.warning {
                            Text(warning).font(.caption).foregroundStyle(brandOrange)
                        }
                        Divider()
                        Toggle("写后回读验证", isOn: $verify)
                        Toggle("包含块 0 / UID（仅 Magic 卡）", isOn: $block0).tint(brandOrange)
                        Toggle("包含扇区尾块（可能锁卡）", isOn: $trailers).tint(.red)
                        Button("开始恢复") { confirming = true }
                            .buttonStyle(.borderedProminent).tint(brandTeal)
                            .disabled(!model.canOperate || model.importedDump == nil)
                    }
                    .formStyle(.grouped)
                }
            }
            Surface {
                Label("安全默认值", systemImage: "shield.lefthalf.filled")
                    .font(.headline).foregroundStyle(brandTeal)
                Text("普通恢复永远跳过块 0 和每个扇区的尾块。勾选危险选项前，请确认你拥有目标卡片、已有备份，并理解错误访问位可能永久锁定扇区。")
                    .foregroundStyle(.secondary).padding(.top, 5)
            }
        }
        .confirmationDialog("确认写入卡片？", isPresented: $confirming, titleVisibility: .visible) {
            Button("确认恢复", role: .destructive) {
                model.restoreDump(
                    options: RestoreOptions(
                        keyOverride: useOverride ? keyOverride : nil,
                        keyTypeOverride: useOverride ? keyType : nil,
                        includeBlock0: block0,
                        includeTrailers: trailers,
                        verify: verify
                    ),
                    scanMode: scanMode
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(block0 || trailers ? "已启用危险块写入；应用会先验证全部目标扇区及完整尾块密钥。" : "默认只写普通数据块，制造块和密钥区不会改变。")
        }
    }

    private func importDump() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importDump(from: url)
    }
}

private struct UIDView: View {
    @EnvironmentObject private var model: AppModel
    @State private var uid = ""
    @State private var key = "FFFFFFFFFFFF"
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(eyebrow: "MAGIC CARD", title: "UID 工具", subtitle: "保留制造商块其余内容，仅替换 4 字节 UID 并自动重算 BCC。仅适用于可写块 0 的 CUID / Magic 卡。")
            HStack(alignment: .top, spacing: 16) {
                Surface {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("新 UID").font(.headline)
                        TextField("例如 AABBCCDD", text: $uid)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                        SecureField("扇区 0 当前 Key A", text: $key)
                            .textFieldStyle(.roundedBorder)
                        Button("写入并验证") { confirming = true }
                            .buttonStyle(.borderedProminent).tint(brandOrange)
                            .disabled(!model.canOperate || uid.isEmpty)
                    }
                }
                .frame(width: 430)
                Surface {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("重要限制", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(brandOrange)
                        Text("原装 NXP MIFARE Classic 的块 0 在工厂锁定，写入会正常失败。此工具不执行 Gen1A 后门解锁，也不提供不可逆的 UFUID 锁定命令。")
                            .foregroundStyle(.secondary)
                        Text("应用会在写入后重新寻卡、认证并回读完整块 0，只有完全一致才报告成功。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .confirmationDialog("确认修改 UID？", isPresented: $confirming, titleVisibility: .visible) {
            Button("写入 \(uid.uppercased())", role: .destructive) { model.writeUID(uid: uid, key: key) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先确认目标是你拥有或获授权操作的可改 UID 卡。")
        }
    }
}

private struct FormatView: View {
    @EnvironmentObject private var model: AppModel
    @State private var key = "FFFFFFFFFFFF"
    @State private var keyType: KeyType = .a
    @State private var sectors = "0-15"
    @State private var gpb = "69"
    @State private var confirming = false
    @State private var scanMode: CardScanMode = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(eyebrow: "DESTRUCTIVE", title: "格式化卡片", subtitle: "清零数据块，并将尾块恢复为 FFFFFFFFFFFF / FF0780 / GPB / FFFFFFFFFFFF。块 0 永不改动。")
            Surface {
                HStack(alignment: .top, spacing: 30) {
                    Form {
                        SecureField("当前密钥", text: $key)
                        Picker("密钥类型", selection: $keyType) {
                            ForEach(KeyType.allCases) { Text("Key \($0.rawValue)").tag($0) }
                        }.pickerStyle(.segmented)
                        TextField("扇区", text: $sectors)
                        TextField("GPB（1 字节）", text: $gpb)
                        Picker("卡型模式", selection: $scanMode) {
                            ForEach(CardScanMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        if let warning = scanMode.warning {
                            Text(warning).font(.caption).foregroundStyle(brandOrange)
                        }
                        Button("格式化所选扇区") { confirming = true }
                            .buttonStyle(.borderedProminent).tint(.red)
                            .disabled(!model.canOperate)
                    }
                    .formStyle(.grouped)
                    .frame(width: 390)
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "eraser.line.dashed.fill")
                            .font(.system(size: 34)).foregroundStyle(.red)
                        Text("此操作不可撤销").font(.title3.bold())
                        Text("请先在“读取与备份”中保存完整转储。格式化期间不要移动卡片或拔出读卡器。扇区 0 的数据块 1、2 和尾块会被重置，但制造块 0 始终保留。")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 360, alignment: .leading)
                }
            }
        }
        .confirmationDialog("彻底清除卡片数据？", isPresented: $confirming, titleVisibility: .visible) {
            Button("格式化 \(sectors)", role: .destructive) {
                model.formatCard(
                    key: key,
                    keyType: keyType,
                    sectors: sectors,
                    gpb: gpb,
                    scanMode: scanMode
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("普通数据将被清零，扇区密钥将恢复为 FFFFFFFFFFFF。")
        }
    }
}

private struct LibNFCView: View {
    @EnvironmentObject private var model: AppModel
    @State private var command = "nfc-list"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(eyebrow: "ADVANCED", title: "libnfc 桥接", subtitle: "将 wCopy HID 封装转换为 PN532 UART，在 macOS 上运行 nfc-list、mfoc 或 mfcuk。")
            HStack(alignment: .top, spacing: 16) {
                Surface {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("命令").font(.headline)
                        Picker("预设", selection: $command) {
                            Text("检测：nfc-list").tag("nfc-list")
                            Text("备份：mfoc").tag("mfoc -O dump.mfd")
                            Text("DarkSide：mfcuk").tag("mfcuk -C -R 0:A -v 2")
                        }
                        TextField("命令", text: $command)
                            .font(.body.monospaced()).textFieldStyle(.roundedBorder)
                        Button("启动桥接") { model.runLibNFC(commandLine: command) }
                            .buttonStyle(.borderedProminent).tint(brandTeal)
                            .disabled(!model.canOperate || command.isEmpty)
                    }
                }
                .frame(width: 440)
                Surface {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("可选依赖", systemImage: "shippingbox")
                            .font(.headline)
                        Text("Homebrew 安装：")
                            .foregroundStyle(.secondary)
                        Text("brew install libnfc mfoc mfcuk")
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .padding(10)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        Text("上游仅验证过默认密钥卡的 mfoc 字典阶段；真正的 nested / DarkSide 攻击尚未经过该硬件实测。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            LogSurface()
        }
    }
}

private struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var rawCommand = "D44A0100"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(eyebrow: "SUPPORT", title: "设备诊断", subtitle: "检查 HID 描述符、协议状态和只读 PN532 响应。向项目报告 B008 兼容性时可导出此信息。")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                MetricCard(icon: "tag", label: "产品", value: model.selectedDevice?.productName ?? "-")
                MetricCard(icon: "number", label: "VID:PID", value: model.selectedDevice?.usbID ?? "-")
                MetricCard(icon: "arrow.left.arrow.right", label: "HID Report", value: "IN \(model.selectedDevice?.maxInputReportSize ?? 0) / OUT \(model.selectedDevice?.maxOutputReportSize ?? 0)")
                MetricCard(icon: "checkmark.seal", label: "兼容性", value: model.selectedDevice?.protocolStatus ?? "-")
            }
            Surface {
                VStack(alignment: .leading, spacing: 12) {
                    Text("原始 PN532 命令").font(.headline)
                    HStack {
                        TextField("以 D4 开头", text: $rawCommand)
                            .font(.body.monospaced()).textFieldStyle(.roundedBorder)
                        Button("发送") { model.sendRawCommand(rawCommand) }
                            .disabled(!model.canOperate)
                    }
                    if !model.rawResponse.isEmpty {
                        Text(model.rawResponse)
                            .font(.body.monospaced()).textSelection(.enabled)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(brandTeal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            LogSurface(showExport: true)
        }
    }
}

private struct LogSurface: View {
    @EnvironmentObject private var model: AppModel
    var showExport = false

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("运行日志").font(.headline)
                    Spacer()
                    if showExport { Button("导出诊断") { exportDiagnostics() } }
                    Button("清除") { model.clearLog() }
                }
                ScrollView {
                    Text(model.logText.isEmpty ? "暂无日志" : model.logText)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(model.logText.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 180, maxHeight: 300)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "wcopy-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.diagnosticsText().write(to: url, atomically: true, encoding: .utf8) }
        catch { model.errorMessage = error.localizedDescription }
    }
}
