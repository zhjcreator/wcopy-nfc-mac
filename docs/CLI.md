# wCopy NFC CLI

`wcopy-nfc` 是面向终端、自动化脚本和 Agent 的非交互接口。它与 macOS 图形应用复用同一套
IOKit HID、wCopy 封装协议和 PN532/MIFARE Classic 实现，不需要 Python、GTK、`hidraw` 或
第三方 HID 驱动。

CLI 当前支持 `0416:B008` 和 `0416:B030`，要求 macOS 13 或更高版本。只有 `reader-info` 或其他
硬件命令成功完成 HID 序列同步和初始化握手，才能说明设备协议已就绪；`devices` 只代表系统枚举
到了兼容 HID 接口。

## 构建与入口

构建 Release 图形应用和 CLI：

```bash
./Scripts/build-app.sh
```

产物：

```text
dist/wCopy NFC.app
dist/wcopy-nfc
```

直接运行：

```bash
./dist/wcopy-nfc version --pretty
./dist/wcopy-nfc capabilities --pretty
```

开发构建使用同一二进制的 `cli` 模式：

```bash
swift run WCopyNFCMac cli devices --pretty
```

如需加入用户 PATH：

```bash
mkdir -p "$HOME/.local/bin"
install -m 755 "dist/wcopy-nfc" "$HOME/.local/bin/wcopy-nfc"
```

## Agent 契约

除 `help` 外，每次调用在 stdout 输出且只输出一个 JSON 文档。普通模式为单行 JSON，`--pretty`
只改变缩进，不改变字段。成功、失败和部分结果都遵循同一个 envelope：

```json
{
  "schemaVersion": 1,
  "ok": true,
  "command": "devices",
  "data": {
    "count": 1,
    "devices": []
  }
}
```

错误示例：

```json
{
  "schemaVersion": 1,
  "ok": false,
  "command": "read",
  "error": {
    "code": "INVALID_INPUT",
    "message": "密钥必须是 12 个十六进制字符（6 字节）",
    "exitCode": 7
  }
}
```

Agent 必须同时检查进程退出码和 JSON。不要通过匹配中文 `message` 判断错误类型，应使用稳定的
`error.code`。`schemaVersion` 发生主版本变化时，字段契约可能不兼容；调用方应先运行
`capabilities` 并校验版本。

stdout 规则：

- 非 help 命令只包含 JSON envelope。
- `--verbose` 不污染 stdout，协议日志和进度写入 stderr。
- 卡片数据、UID 和已发现密钥属于敏感输出，调用方应控制日志、缓存和文件权限。
- 输出中的十六进制统一使用大写且不带 `0x`，除特别说明的诊断字段外不含分隔符。

## 退出码

| 退出码 | 含义 | Agent 建议 |
| ---: | --- | --- |
| `0` | 命令成功且结果完整 | 解析 `data` |
| `1` | 未分类内部错误 | 记录 JSON 和版本，停止自动重试 |
| `2` | 命令或参数用法错误 | 修正参数，不要原样重试 |
| `3` | 未发现或未选择设备 | 运行 `devices`，检查 USB 连接 |
| `4` | HID/PN532 传输错误 | 关闭占用设备的软件，拔插后有限重试 |
| `5` | 未检测到卡片 | 提示放卡，保持设备不变后有限重试 |
| `6` | 协议不支持或操作失败 | 检查 `error.code` 和 `message` |
| `7` | 密钥、UID、扇区、文件或转储无效 | 修正输入，不要原样重试 |
| `8` | 写命令缺少 `--yes` | 只有获得用户明确授权后才能添加 `--yes` |
| `10` | 命令正常完成，但结果不完整或未命中 | 保留并解析 `data`，不要丢弃部分结果 |
| `130` | 操作被取消 | 根据调用方取消策略处理 |

`10` 是有效结果，不等同于异常。例如：

- `keys` 找到 `27/32` 个密钥槽时，`ok` 为 `true`，退出码为 `10`。
- `read` 某些扇区认证失败时，已读取块仍在 `data.blocks` 中，退出码为 `10`。
- `verify-key` 格式正确但认证不通过时，`data.verified` 为 `false`，退出码为 `10`。

写命令若在设备已经接受至少一次块写入后发生传输或验证异常，会返回 `ok: false`、
`error.code: "PARTIAL_MUTATION"`，并包含 `mayHaveModified`、`attemptedBlocks`、
`acknowledgedBlocks` 和 `retrySafe: false`。Agent 此时不得自动重试，应停止操作并要求人工检查卡片。

## 通用参数

| 参数 | 说明 |
| --- | --- |
| `--device-index N` | 使用 `devices` 返回的索引，默认 `0` |
| `--device-id ID` | 使用 `devices[].id`，支持十进制或 `0x` 前缀十六进制 |
| `--sync-radius N` | HID 序列号搜索半径，范围 `0...2000`，默认 `200` |
| `--card-mode MODE` | `auto`、`sak19`、`mini`、`1k`、`2k` 或 `4k` |
| `--pretty` | 格式化 JSON，便于人工阅读 |
| `--verbose` | 将同步、扫描进度和协议日志写入 stderr |
| `--help` | 显示命令帮助，不连接硬件 |

不要同时运行 GUI、CLI、官方工具或其他 NFC 程序访问同一 HID 接口。一次 CLI 调用会独占打开设备，
完成后自动关闭。Agent 应串行化硬件命令。

## 卡型模式

| CLI 值 | 几何 |
| --- | --- |
| `auto` | 根据 SAK/ATQA/UID 自动判断，包含实测 SAK 19 规则 |
| `sak19` | 强制使用 SAK 19 兼容 Classic 1K 行为和 16 扇区几何 |
| `mini` | 强制 5 扇区、20 块 |
| `1k` | 强制 16 扇区、64 块 |
| `2k` | 强制 32 扇区、128 块 |
| `4k` | 强制 40 扇区、256 块 |

`SAK 0x19 + ATQA 0x0004 + 4 字节 UID` 在 `auto` 下按实测兼容 Classic 1K 处理。`keys` 会自动
生成 `UID0^UID1 + UID0..UID3 + UID2^UID3` 候选并实际验证；例如合成 UID `12345678` 对应
`26123456782E`。兼容布局可在扇区 1/15 使用该候选。强制模式不修改 SAK、ATQA、UID 或数据。

## 密钥输入

接受以下 6 字节密钥格式：

```text
FFFFFFFFFFFF
0xFFFFFFFFFFFF
FF:FF:FF:FF:FF:FF
FF FF FF FF FF FF
```

单密钥命令可以使用 `--key HEX` 或 `--key-file FILE`，两者不能同时使用。`--key-file` 必须恰好
包含一个有效密钥，支持空行和 `#`、`;`、`//` 注释。Agent 处理非公开密钥时应优先使用权限受限的
临时文件，避免密钥出现在 shell 历史和进程参数中：

```bash
umask 077
printf '%s\n' 'FFFFFFFFFFFF' > /tmp/wcopy.key
./dist/wcopy-nfc verify-key --sector 0 --key-type A --key-file /tmp/wcopy.key
rm -f /tmp/wcopy.key
```

不要把实际密钥提交到仓库、Agent 长期记忆、诊断工单或不受保护的日志。

## 命令

### `version`

返回 CLI 和 JSON schema 版本，不访问硬件。

```bash
./dist/wcopy-nfc version --pretty
```

关键字段：`data.version`、`data.schemaVersion`。

### `capabilities`

返回可用命令、是否修改卡片、是否需要硬件、支持的 USB ID 和卡型模式。Agent 应使用这个命令做
能力发现，而不是根据帮助文本猜测。

```bash
./dist/wcopy-nfc capabilities --pretty
```

### `devices`

枚举满足 VID/PID 和 64 字节 HID 报告要求的接口，不会打开或握手设备。

```bash
./dist/wcopy-nfc devices --pretty
```

主要字段：

| 字段 | 含义 |
| --- | --- |
| `data.count` | 兼容 HID 接口数量 |
| `data.devices[].index` | 当前调用可使用的 `--device-index` |
| `data.devices[].id` | IOKit registry ID，可用于 `--device-id` |
| `data.devices[].usbID` | `0416:B008` 或 `0416:B030` |
| `inputReportBytes` / `outputReportBytes` | 必须至少为 64 |
| `protocolStatus` | 设备型号的静态说明，不代表本次握手成功；B008 仍需每次运行时握手 |

索引可能在拔插后变化。需要跨调用稳定选择时，优先记录本次枚举得到的 `id` 或设备序列号，并在
执行前重新枚举确认。

### `diagnostics`

不带参数时返回系统版本、架构和 HID 描述符。加 `--connect` 后还会打开所选设备并执行完整握手。

```bash
./dist/wcopy-nfc diagnostics --pretty
./dist/wcopy-nfc diagnostics --connect --verbose --pretty
```

`--connect` 成功时包含 `data.reader.firmware`、`serial` 和 `sequence`。

### `reader-info`

打开设备、同步 HID 序列、执行初始化并返回读卡器信息。这个命令成功才表示“协议就绪”。

```bash
./dist/wcopy-nfc reader-info --device-index 0 --pretty
```

关键字段：`data.protocolReady`、`data.firmware`、`data.serial`、`data.sequence`。

### `card-info`

只寻卡，不认证或读取 MIFARE 数据块。

```bash
./dist/wcopy-nfc card-info --card-mode auto --pretty
./dist/wcopy-nfc card-info --card-mode 1k --pretty
```

返回 `data.card.uid`、`atqa`、`sak`、`type`、`sectorCount` 和 `blockCount`。

### `read`

使用一个已知 Key A 或 Key B 读取指定扇区。未指定 `--sectors` 时读取所选卡型的所有扇区。

```bash
./dist/wcopy-nfc read \
  --key-file /tmp/wcopy.key \
  --key-type A \
  --sectors 0-15 \
  --card-mode 1k \
  --output /tmp/card.json \
  --pretty
```

参数：

| 参数 | 说明 |
| --- | --- |
| `--key HEX` / `--key-file FILE` | 必需，认证密钥 |
| `--key-type A|B` | 默认 `A` |
| `--sectors RANGE` | 如 `0-15`、`0-3,7,9-10` |
| `--output FILE` | 可选，原子写入 JSON/MFD 转储 |
| `--format json|mfd` | 默认按扩展名判断；无扩展名时为 JSON |
| `--force` | 允许覆盖已存在的输出文件 |

结果始终在 `data.blocks` 返回已读块，因此无需 `--output` 也能被 Agent 消费。`blocks` 的 key 是
十进制块号字符串，value 是 16 字节大写十六进制。

单一认证密钥读取通常不知道另一类密钥，因此即使读取了所有块，也可能无法导出要求完整 Key A/B
的 MFD。需要完整 MFD 时应先运行 `keys`。

### `keys`

按候选命中概率逐扇区检查 Key A 和 Key B，并尽可能读取数据块。

```bash
./dist/wcopy-nfc keys --preset quick --card-mode 1k --pretty

./dist/wcopy-nfc keys \
  --preset common \
  --dictionary ./authorized.keys \
  --dictionary ./more.dic \
  --key A0A1A2A3A4A5 \
  --card-mode 1k \
  --output /tmp/card.json \
  --verbose
```

预设：

| 值 | 内容 |
| --- | --- |
| `quick` | mfoc 常用的 13 个高命中默认键 |
| `common` | 默认值、常见公开键和测试键；默认值 |
| `patterns` | common 加重复字节、递增和递减弱模式 |
| `custom` | 只使用 `--dictionary` 和 `--key` |

`--dictionary FILE` 和 `--key HEX` 可以重复。词典支持 Proxmark3 `.dic`、MIFARE Classic Tool
`.keys` 和普通文本格式，自动处理注释、去重和无效行。

主要字段：

| 字段 | 含义 |
| --- | --- |
| `foundSlots` / `totalSlots` | 已确定的 A/B 槽数量，例如 `27/32` |
| `sectorKeys[]` | 每个扇区的 `keyA`、`keyB` 和 `keyBAuthenticates` |
| `candidateCount` | 去重后的候选数量 |
| `authenticationAttempts` | 实际认证次数，包含读取阶段的重认证 |
| `dictionaryFiles[]` | 每个导入文件的解析统计 |
| `blocks` | 成功读取的数据块 |
| `failedBlocks` | 已有可用密钥但仍无法读取的块 |

`keyBAuthenticates: false` 表示尾块访问位把 Key B 字段配置为可读数据。该 6 字节值可用于完整备份，
但不能用于 Key B 认证。Agent 不应把它传给 `verify-key --key-type B`。

静态词典检查不是完整 48 位密钥穷举。UID 派生、随机或未知密钥不会因为增加运行时间而必然找到。

### `verify-key`

对一个扇区的一个密钥槽执行实际认证，不写卡。

```bash
./dist/wcopy-nfc verify-key \
  --sector 15 \
  --key-type A \
  --key-file /tmp/wcopy.key \
  --card-mode 1k \
  --pretty
```

认证通过：退出 `0`，`data.verified` 为 `true`。认证不通过：退出 `10`，`ok` 仍为 `true`，
`data.verified` 为 `false`。

### `restore`

从 JSON 或 320/1024/2048/4096 字节 MFD 恢复卡片。此命令会写卡，必须显式提供 `--yes`。

```bash
./dist/wcopy-nfc restore \
  --input /tmp/card.json \
  --format json \
  --card-mode 1k \
  --yes \
  --pretty
```

安全默认值：

- 默认跳过块 0。
- 默认跳过所有扇区尾块。
- 默认写后回读验证。
- 写入前先验证所有目标扇区，避免发现错误密钥前已部分写入。

`--format json|mfd` 是可选输入格式提示；未提供时先参考 `.mfd` 扩展名，再根据 JSON 起始字符或
MFD 标准大小自动识别。

危险选项：

| 参数 | 风险 |
| --- | --- |
| `--include-block0` | 仅适用于兼容 Magic/CUID 卡；可能导致卡片不可用 |
| `--include-trailers` | 会改写密钥和访问位；错误值可能永久锁定扇区 |
| `--no-verify` | 跳过写后验证，不建议 Agent 使用 |
| `--key` / `--key-file` | 覆盖转储中用于认证目标卡的密钥 |
| `--key-type A|B` | 仅与密钥覆盖一起使用 |

没有获得用户对本次写入的明确授权时，Agent 不得自动添加 `--yes`。

### `write-uid`

修改兼容 4 字节 UID Magic/CUID 卡的 UID，自动重算 BCC 并完整回读验证。普通 MIFARE Classic
制造块不可写。此命令必须提供 `--yes`。

```bash
./dist/wcopy-nfc write-uid \
  --uid AABBCCDD \
  --key-file /tmp/wcopy.key \
  --yes \
  --pretty
```

此命令固定使用扇区 0 Key A。

### `format`

清零所选扇区普通数据块，并把尾块恢复为 Key A/Key B `FFFFFFFFFFFF`、标准访问位和指定 GPB。
块 0 保持不变。此命令必须提供 `--yes`。

```bash
./dist/wcopy-nfc format \
  --key-file /tmp/wcopy.key \
  --key-type A \
  --sectors 1-15 \
  --gpb 69 \
  --card-mode 1k \
  --yes \
  --pretty
```

`--gpb` 必须是 1 字节十六进制，默认 `69`。格式化前会先认证全部指定扇区；预检查失败时不会开始
修改任何扇区。

### `pn532`

发送受 allow-list 限制的只读 PN532 主机命令。允许的命令码：

- `D4 02` GetFirmwareVersion
- `D4 04` GetGeneralStatus
- `D4 06` ReadRegister
- `D4 4A` InListPassiveTarget

```bash
./dist/wcopy-nfc pn532 --hex 'D4 02' --pretty
```

其他命令会在发送到设备前以用法错误拒绝。CLI 不提供绕过 allow-list 的参数。

## 推荐 Agent 流程

只读识别流程：

```bash
./dist/wcopy-nfc capabilities
./dist/wcopy-nfc devices
./dist/wcopy-nfc reader-info --device-index 0
./dist/wcopy-nfc card-info --device-index 0 --card-mode auto
```

已知默认卡的保守读取流程：

```bash
./dist/wcopy-nfc keys \
  --device-index 0 \
  --preset quick \
  --card-mode 1k \
  --output /tmp/card.json
status=$?
if [ "$status" -ne 0 ] && [ "$status" -ne 10 ]; then
  exit "$status"
fi
```

Agent 决策规则：

1. 先读取 `capabilities`，确认 schema 和命令能力。
2. 每次硬件操作前运行 `devices`，确认设备唯一或明确选择设备。
3. 先运行 `reader-info`，不要把 USB 枚举当作协议就绪。
4. 默认使用 `card-info --card-mode auto`；只有卡片资料明确时才强制几何。
5. 优先执行只读命令。未经用户针对本次操作明确授权，不得执行带 `--yes` 的命令。
6. 将退出码 `10` 视为可解析的部分结果，检查 `foundSlots`、`failedSectors` 和 `failedBlocks`。
7. 不要并发访问同一设备，不要在 GUI 已连接时启动 CLI。
8. 只对只读长扫描设置外部超时。写入、UID 或格式化过程中不得强制终止或拔出设备。

## 故障处理

`devices` 返回 `count: 0`：

- 确认 USB 设备是 `0416:B008` 或 `0416:B030`。
- 拔插设备后重新枚举。
- 检查设备 HID 输入和输出报告是否至少为 64 字节。

设备存在但 `reader-info` 失败：

- 退出 GUI、官方工具和其他 NFC 程序。
- 拔下设备数秒后重连，避免序列计数器停留在异常状态。
- 使用 `diagnostics --connect --verbose` 保存 stdout JSON 和 stderr 日志。
- 必要时提高 `--sync-radius`，但不要超过 `2000`。

`card-info` 返回 `NO_CARD`：

- 把卡片稳定放在感应区，不要同时放多张卡。
- 保持同一设备选择后有限重试。

`keys` 长时间运行：

- 先用 `--preset quick`。
- 确有需要再使用 `common`、`patterns` 或大型导入词典。
- 候选数量乘以未解决密钥槽数决定认证量；大词典可能需要很长时间。
- 扫描期间保持卡片稳定，CLI 会在认证失败后重新寻卡并核对 UID、ATQA、SAK。

## 安全边界

只操作你拥有或得到明确授权的卡片。CLI 不实现 125 kHz ID 卡、UFUID 永久锁定或任意 PN532 写命令。
恢复尾块、格式化和 UID 修改均可能破坏卡片。`--yes` 只表示调用方确认本次操作，不会降低物理风险，
也不能替代备份、卡型确认和授权记录。
