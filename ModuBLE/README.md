# ModuBLE

**Modular Bluetooth LE SDK for IoT devices** — Swift Package · iOS 16+ / macOS 13+ · Swift 6

一个以「可验证的加密 BLE 通信闭环」为目标的模块化 SDK：把 CoreBluetooth 收敛在
`BLE` 层内部，向上提供 `async/await` 与异步流；把封包、加密、会话拆成互相独立的
模块，让每一层都能脱离真机单独测试。

参考外设是一台 macOS 上运行的 `CBPeripheralManager` App，两端共用本包的协议与
加密实现，因此不存在"手写两套封包对不齐"的问题。

---

## 仓库结构

```text
BLEPro/
├── ModuBLE/                        ← 本 SDK（Swift Package）
│   ├── Package.swift
│   ├── Sources/ModuBLE/
│   │   ├── BLE/                    CoreBluetooth 封装
│   │   ├── Protocol/               帧格式、编解码、流式重组
│   │   ├── Crypto/                 加密抽象与两种实现
│   │   ├── Session/                加密请求/响应会话
│   │   ├── Logging/                结构化事件日志
│   │   └── Demo/                   公开的测试密钥（明确标注）
│   ├── Tests/ModuBLETests/         142 个 XCTest
│   └── Documentation/
│       ├── Peripheral-GATT.md      外设契约与协议定义
│       └── Device-Verification.md  真机验收清单与已验证记录
├── bleProject/
│   ├── ModuBLEDemo.xcodeproj       iPhone Demo（只调用 SDK 公共接口）
│   └── BLEPeripheralApp.xcodeproj  macOS 参考外设（复用 SDK 做加解密）
├── .github/workflows/ci.yml        swift test + 两个 App 的无签名构建
├── LICENSE                         MIT
└── .gitignore
```

> 两个 App 通过 `XCLocalSwiftPackageReference ../ModuBLE` 引用本地包，因此必须保持
> 仓库内的相对目录结构；只克隆 `ModuBLE` 子目录会无法构建 Demo。

## 模块职责

| 模块 | 职责 | 依赖 CoreBluetooth |
|---|---|---|
| `BLE` | 扫描、连接、服务/特征发现、订阅、写入、状态流 | 是（且仅此一处） |
| `Protocol` | 帧格式、编解码、流式重组、magic 重同步 | 否 |
| `Crypto` | 加密抽象、AES-GCM、AES-CBC+HMAC | 否 |
| `Session` | 加密 → 分帧 → 写入、响应关联、超时 | 否（只依赖 `BLELink`） |
| `Logging` | 结构化事件模型 + 有界内存存储 | 否 |

依赖方向是单向的：`Session → (BLELink, CryptoProvider, Protocol)`。这保证了协议和
密码学可以完全用单元测试覆盖，不需要真机。

## 快速开始

```bash
cd ModuBLE
swift build
swift test          # 142 tests
```

### 已验证环境

记录于 2026-11-19：

| 项 | 值 |
|---|---|
| Swift | 6.4（swiftlang-6.4.0.34.1） |
| Xcode | 27.0（27A266a） |
| macOS | 27.0 |
| `swift test` | 142 passed, 0 failed |
| `BLEPeripheralApp` | Debug 构建通过（无签名） |
| `ModuBLEDemo` | iOS Simulator 构建通过（无签名） |

CI（`.github/workflows/ci.yml`）在 `macos-15` 上重复上述三项检查。

真机联调需要两个 App：

```bash
# 1. Mac 端外设
open bleProject/BLEPeripheralApp.xcodeproj     # 运行后点 Start Advertising

# 2. iPhone 端 Demo
open bleProject/ModuBLEDemo.xcodeproj          # 选择真机运行
```

Demo 里：扫描 → 连接 → Quick Commands 点 `START`，看到 `LAST DECRYPTED RESPONSE:
START_ACK` 即闭环成立。完整步骤见
[`Documentation/Device-Verification.md`](Documentation/Device-Verification.md)。

## 用法

```swift
let central = BLECentralManager(logStore: store)
let profile = GATTProfile.referencePeripheral

// 蓝牙状态（含关闭 / 未授权等可直接展示的文案）
for await state in central.observeBluetoothState() {
    // state.isReady → 可以扫描
}

// 扫描：每次产出完整设备列表，直接替换 UI 数据源
let devices = try await central.scan(profile: profile)
for try await snapshot in devices {
    // snapshot: [DiscoveredDevice]，含 name / rssi / isConnectable
}

// 连接 + 服务发现 + 订阅 TX，一次性完成
let connection = try await central.connect(device, profile: profile)

// 原始写入（自动按 MTU 切片）
try await connection.write(Data("Hello".utf8))
try await connection.write(Data("Hello".utf8), mode: .withoutResponse)

// 需要断连通知时观察状态；不要另起一个循环读 inbound
for await state in connection.observeState() {
    if case .failed(let reason) = state { /* ... */ }
}
```

### 加密会话

```swift
let session = EncryptedSession(
    link: connection,
    crypto: try AESGCMProvider(key: DemoTestKey.aes128GCM),
    timeout: .seconds(5),
    logStore: store
)

let reply = try await session.request(Data("START".utf8))   // → "START_ACK"

// 信封首字节标识格式，切算法不用重连
session.updateCrypto(try AESCBCProvider(key: DemoTestKey.aes128CBCHMAC))

// 外设主动事件：已分帧、已验签、已解密
session.start()                     // 只收事件、暂不发请求时先启动接收循环
for await event in session.events { // 单消费者
    print(event.sequence, event.payload)
}
```

`EncryptedSession` 负责：加密、分帧、按 sequence 匹配响应、验签解密、超时、事件分发。
同一时刻只允许一个在途请求，并发调用返回 `SessionError.busy`——序号预留与 pending 安装
在同一次加锁中完成，不存在两个调用互相覆盖 continuation 的窗口。

### Mock 模式（无需硬件）

Mock 走的是同一套 `PacketCodec` / `CryptoProvider` / `PacketDecoder`，只把射频换成内存
队列，所以自动化测试验证的就是真实软件链路。

```swift
let transport = MockDeviceTransport(logStore: store)
let stream = try await transport.scan(profile: .referencePeripheral)
let device = /* 第一个设备 */
let link = try await transport.connect(device, profile: .referencePeripheral)

let session = EncryptedSession(
    link: link,
    crypto: try AESGCMProvider(key: DemoTestKey.aes128GCM),
    timeout: .seconds(2)
)
session.start()
for await event in session.events {
    let telemetry = try TelemetryCodec.decode(event.payload)
}

// 故障只作用于当前连接；重新连接后使用 MockConfiguration.faults
transport.applyFaultConfiguration(
    FaultConfiguration(dropRate: 0.3, latency: .milliseconds(120))
)
```

## 协议

### 帧格式

10 字节定长头 + payload，整数大端：

```text
Magic "MB" (2) | Version (1) | Kind (1) | Sequence (4) | Payload Length (2) | Payload
```

`Kind`：`0x01` request、`0x02` response、`0x03` event、`0x7F` raw。

**没有 CRC**。BLE 链路层自带 CRC，密文由 AEAD tag 或 HMAC 保护；再加一层 CRC 只会
增加字节，还会让人误以为它提供了完整性保证。

### 信封格式

payload 是自描述的信封，**首字节即格式版本**，因此两种算法可以共存而不混淆：

```text
AES-128-GCM     0x01 | Nonce (12) | Ciphertext (n) | AuthTag (16)
AES-128-CBC     0x02 | IV (16)    | Ciphertext (n) | HMAC-SHA256 (32)
```

CBC 的 HMAC 覆盖 `Version | IV | Ciphertext`，**先验 MAC 再解密**：MAC 不通过时
不会产生任何明文。主密钥 32 字节，AES 密钥与 HMAC 密钥经 HKDF-SHA256 分离，
避免同一把密钥服务两种原语。

### 命令（参考外设）

| 请求明文 | 响应明文 |
|---|---|
| `START` | `START_ACK` |
| `PING` | `PONG` |
| 其他任意字节 | 原样回显 |

回显分支让任意长度的二进制负载（含多 chunk）都能端到端校验。

### 一次加密往返

```text
iPhone (Central)                                        Mac (Peripheral)
────────────────                                        ────────────────
plaintext "START" (5 B)
  encrypt → 34 B sealed
  frame   → 44 B
  write ──── 44 B ATT write ─────────────────────────▶ PacketDecoder
                                                      decrypt → "START"
                                                      respond → "START_ACK" (9 B)
                                                      encrypt → 38 B sealed
        ◀─── 48 B notify ───────────────────────────  frame   → 48 B
  decode → decrypt → "START_ACK"
```

1000 B 负载时：信封 1029 B，帧 1039 B，按 512 切成 3 次写入；外设回显同样分片
Notify，手机端 `PacketDecoder` 重组后解密，结果与原文逐字节一致。

## API 速览

| 类型 | 用途 |
|---|---|
| `BLECentralManager` | 蓝牙状态广播、扫描、连接、取消连接 |
| `BLEConnection` | 特征发现、TX 订阅、MTU 切片写入、`inbound` 字节流、`observeState()` |
| `BLELink` | 字节链路抽象，`Session` 只依赖它（便于注入假实现） |
| `DeviceLink` | `BLELink` + 设备身份、断连观察、MTU；`BLEConnection` 已实现 |
| `DeviceTransport` / `CoreBluetoothTransport` | 扫描、连接的统一抽象与 CoreBluetooth 适配 |
| `MockDeviceTransport` / `MockBLELink` / `MockPeripheral` | 无需硬件的完整软件链路（真实编解码 + 加解密） |
| `Telemetry` / `TelemetryCodec` / `TelemetryGenerator` | Demo 业务载荷模型、14 字节二进制格式、确定性数据源 |
| `FaultInjector` / `FaultConfiguration` | 延迟、丢帧、认证损坏、坏帧、主动断连（可播种复现） |
| `GATTProfile` | Service / RX / TX UUID 与写模式配置 |
| `PacketCodec` / `PacketDecoder` | 单帧编解码 / 流式重组（含 magic 重同步） |
| `CryptoProvider` | 加密抽象；`AESGCMProvider`、`AESCBCProvider` |
| `EncryptedSession` | 加密请求/响应会话，带超时、算法切换、并发占用保护 |
| `SessionEvent` / `EncryptedSession.events` | 解密后的外设主动事件流（预留，尚未接入 Demo） |
| `CommunicationLog` / `CommunicationLogStore` | 结构化日志与有界存储 |
| `BLEError` / `CryptoError` / `SessionError` / `PacketError` | 分层错误，均可比较 |

## 设计决策

1. **协议不依赖 CoreBluetooth**，密码学不依赖 BLE，会话只依赖 `BLELink`。代价是多一层
   抽象，收益是协议与密码学能 100% 单测覆盖。
2. **版本字节就是格式标识**（GCM `0x01` / CBC `0x02`），接收方按首字节分发，而不是按
   长度猜。
3. **单一在途请求**。BLE 写入本来就得串行；只保留一个 pending continuation，"响应错配"
   这类 bug 在结构上就不可能发生。序号预留与 pending 安装在同一把锁内完成，并发调用
   只会得到 `SessionError.busy`，不会互相覆盖。
4. **所有等待都有上限**：连接 15 s、发现+订阅 10 s、会话请求由调用方指定。宁可报错，
   也不让调用方永久挂起。
5. **`inbound` 是单消费者流**，读取字节归 `EncryptedSession`；旁观断连用
   `observeState()`。这是 `AsyncStream` 的语义决定的，已在文档里写死。
6. **重连策略不放进 SDK**。SDK 只报告 `connectionLost`，指数退避由应用层决定。
7. **日志用锁而不是 actor**。actor 的 `await` 会让并发生产者交错，日志顺序就乱了；
   Demo 要展示的正是"按时间顺序的通信步骤"。

## 当前状态

| 模块 | 状态 |
|---|---|
| `Protocol` | ✅ 完成 |
| `Crypto` | ✅ 完成（两种算法均真机验证） |
| `Logging` | ✅ 完成 |
| `BLE` | ✅ 真机验证 |
| `Session` | ✅ 真机验证 |
| `Session.events` | ✅ 单测覆盖（外设尚未主动推送） |
| `Transport` | ✅ `DeviceTransport` + CoreBluetooth 适配 + Mock 传输 |
| `Telemetry` | ✅ 编解码与数据源（尚未接入 Demo UI） |

142 个 XCTest 全绿（含 NIST SP 800-38A CBC 向量、防篡改、超时、并发拒绝、
分片重组、中途切换算法）。

**真机已验证**（iPhone ↔ macOS 外设，2026-11-14）：

| 项 | 结果 |
|---|---|
| 扫描 / 连接 / 订阅 | ✅ `READY` 正常收到 |
| with / without response 写入 | ✅ 外设字节一致 |
| MTU 切片 | ✅ 1000 B → `512 + 488` |
| AES-128-GCM 闭环 | ✅ `START` → `START_ACK`（44 B / 48 B 帧） |
| AES-128-CBC 闭环 | ✅ 连接中切换算法，`START` → 75 B 帧 → `START_ACK` |
| 加密 + 分包回显 | ✅ 1000 B，双向分片重组后逐字节一致 |
| 断连自动重连 | ⬜ 代码完成，未做真机验证 |

## 测试覆盖

| 测试文件 | 覆盖内容 |
|---|---|
| `PacketCodecTests` | 帧编解码、字节级重组、magic 重同步、截断/超长/未知版本 |
| `AESGCMProviderTests` | 往返、Nonce 唯一性、错钥、篡改密文/Nonce/Tag |
| `AESCBCProviderTests` | NIST 向量、Encrypt-then-MAC 顺序、篡改 IV/密文/MAC、PKCS#7、跨格式拒绝 |
| `EncryptedSessionTests` | 往返、超时、序号错配、并发拒绝、close 释放、分片重组、中途切换算法 |
| `EncryptedSessionConcurrencyTests` | 128 并发 × 20 轮的 continuation 泄漏回归、预留释放、close 竞争、超时后复用 |
| `EncryptedSessionEventTests` | 事件解密分发、事件与响应互不干扰、坏事件丢弃、流终止 |
| `EncryptedSessionLimitsTests` | GCM/CBC 明文上限、边界请求、超限拒绝、切换算法后的上限 |
| `DeviceTransportTests` | 传输类型、蓝牙状态不提前激活、`DeviceLink` 默认写模式、MTU 透出 |
| `TelemetryTests` | 14 字节格式往返、符号与边界角度、电量/uptime 越界、截断、版本、前向兼容 |
| `DemoPeripheralBehaviorTests` | 命令表、速率范围、二进制回显 |
| `FaultInjectorTests` | 种子可复现、速率钳制、损坏帧认证失败、坏帧不被解析、计数器 |
| `MockTransportTests` | 扫描/连接、加密往返、超 MTU 分片重组、遥测事件、丢包/损坏/断连、热更新故障 |
| `BLETypesTests` / `MTUChunkerTests` | 状态与错误映射、切片边界、Data 切片索引 |
| `BLELinkTests` | 假链路上的帧往返、噪声容忍 |
| `CommunicationLogStoreTests` | 顺序、容量上限、回调保序 |

## 已知限制

首期交付的是「可验证的加密闭环」，不是可直接上生产的安全方案：

1. **无重放保护**：`sequence` 只用于请求响应匹配，不做单调性校验。生产需要单调计数器 + 接收窗口。
2. **无双向认证**：两端共享预置对称密钥，无法证明对端身份。后续应做 ECDH + 设备证书。
3. **无密钥轮换**：`DemoTestKey` 是公开的测试密钥，禁止用于生产。
4. **`inbound` 单消费者**：见设计决策 5。
5. **单连接**：同一时刻只允许一个活动连接。
6. **外设侧假设单一 central**：多 central 并发写入时，按 offset 合并可能串包。
7. **明文回退仍在**：非协议帧会得到 `RX #n: k bytes` 纯文本响应，仅为迁移期兼容，生产应关闭。
8. **单帧上限 4096 B**：超出直接拒绝，避免损坏的长度字段导致无界分配。该上限是
   **信封**长度，因此明文上限为 GCM 4067 B / CBC 4031 B，`EncryptedSession` 会提前
   返回 `SessionError.payloadTooLarge(max:)`。
9. **事件流尚未接入 Demo**：`EncryptedSession.events` 与 Mock 外设已可用，
   Dashboard / 故障面板仍属后续阶段；macOS 外设只响应命令，不主动推送事件。
10. **Mock 不模拟射频细节**：没有 RSSI 抖动、连接参数协商、ATT 拥塞与真实丢包
    模式；故障是按配置注入的确定性事件，不能用来评估无线性能。

## 安全边界

- 不记录密钥或会话凭证。
- 日志会记录**解密后的明文**（响应与事件），仅用于 Demo 诊断；接入真实业务时应关闭
  或脱敏 payload。日志中的密文 / Nonce / IV 均属测试会话数据。
- 测试密钥集中在 `DemoTestKey`，命名与注释都明确标注不可用于生产。
- CBC 在 MAC 校验失败时**不继续解密**；GCM 认证失败时不返回任何明文。

## 后续路线

- 重放保护（单调序号 + 接收窗口）
- ECDH + HKDF 动态协商会话密钥
- 多连接与连接池
- 事件流接入 Demo：Dashboard 仪表盘与故障注入面板（SDK 侧已完成）
- macOS 外设推送 Telemetry（当前只响应命令，不主动发事件）
- 应用层可靠传输（滑动窗口、ACK bitmap、选择性重传）
- 后台恢复与状态保存
