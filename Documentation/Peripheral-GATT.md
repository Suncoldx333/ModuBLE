# 参考外设 GATT 契约

> 事实来源：`Demo/BLEPeripheralApp/` 当前代码（2026-11-19 核对）
> 适用范围：iPhone 端 SDK（`ModuBLE`）与 Mac 参考外设之间的链路与协议
> 状态：**与代码一致**。任何一方改动 UUID、属性或载荷格式，必须先改本文件。

本文件只描述**当前确实实现**的行为。未实现的能力集中在第 7 节，不得在 README、
演示或对外描述中当作已有功能。

## 1. GATT 定义

| 项 | 值 | 属性 | 权限 |
|---|---|---|---|
| Service | `5A0C8B3E-7D2F-4A6B-9C1D-3E5F7A9B1C2D` | primary，唯一 Service | — |
| RX / Data | `9F8E7D6C-5B4A-3F2E-8D7C-6B5A4F3E2D1C` | `.read .write .writeWithoutResponse` | readable, writeable |
| TX / Status | `1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D` | `.read .notify` | readable |

- 常量位置：`PeripheralManager.serviceUUID`、`.characteristicUUID`、`.statusCharacteristicUUID`。
- 特征构造位置：`PeripheralManager.init()`。
- 两个特征挂在同一个 Service 下。**Central 写入 RX，订阅 TX。**
- SDK 侧对应配置：`GATTProfile.referencePeripheral`。UUID 通过 `GATTProfile` 注入，
  传输层不硬编码。

## 2. 外设行为（当前实现）

| 时机 | 行为 |
|---|---|
| Central 订阅 TX 成功 | 立即 Notify 一次 UTF-8 `READY` |
| 收到**非协议**写入 | 保存字节，并 Notify `RX #<序号>: <字节数> bytes` |
| 收到**协议帧** | 解密 → 按命令生成响应 → 加密 → Notify **同 sequence** 的 `response` 帧 |
| 收到 `START` | 回 `START_ACK`，并按 3.3 的频率持续 Notify `event` 帧 |
| 收到 `STOP` | 回 `STOP_ACK`，停止 `event` 推送 |
| 收到 `SET_RATE:<hz>` | 回 `RATE:<hz>`，按新频率重建定时器 |
| 无订阅者 | 暂停 `event` 推送；重新订阅后若仍处于 START 状态则自动恢复 |
| 收到**无法识别信封**的协议帧 | 不 Notify，本地状态设为 `UNSUPPORTED ENVELOPE`，控制台打印原因 |
| 协议帧解密/认证失败 | 不 Notify，本地状态设为 `DECRYPT FAIL`，控制台打印原因 |
| Central 读取 RX | 返回最后一次写入的原始字节 |
| Central 读取 TX | 返回最后一次 Notify 的原始字节 |
| Central 连接 / 断开 | 不产生 Notify |
| 广播存活 | 持电源断言禁止 App Nap / 空闲睡眠；每 5 秒自检，广播被系统回收时自动重启 |
| 写入批量回调 | 按 `offset` 合并长写；多个 `offset == 0` 的写入视为独立包；只对第一个请求 `respond(.success)` |

实现入口：

- 写入与分帧：`PeripheralManager.didReceiveWrite`、`ingest(_:)`
- 协议分发：`PeripheralManager.handle(_:)`
- 命令语义：`DemoPeripheralBehavior.handle(_:)`
- 事件推送：`PeripheralManager.emitTelemetry()`、`startTelemetryTimerIfNeeded()`
- Notify 队列：`notifyAll(_:)`、`flushPendingNotifications()`

## 3. 应用层协议

### 3.1 帧格式

10 字节定长头 + payload，整数大端：

```text
Magic "MB" (2) | Version (1) | Kind (1) | Sequence (4) | Payload Length (2) | Payload
```

| Kind | 值 | 说明 |
|---|---|---|
| request | `0x01` | 期望 `response` |
| response | `0x02` | 与 request 同 sequence |
| event | `0x03` | 外设主动推送，不期望响应 |
| raw | `0x7F` | 不透明白字节 |

- 单帧 payload 上限 `PacketCodec.maxPayloadLength = 4096`。
- **没有 CRC**。BLE 链路层自带 CRC，密文由 AEAD tag 或 HMAC 提供完整性。
  额外的 CRC 不增加安全性，只会增加字节。
- `sequence` 仅用于请求/响应关联，不是安全令牌，也不做重放校验。

### 3.2 信封格式

payload 是自描述信封，**首字节即格式版本**：

```text
AES-128-GCM   0x01 | Nonce (12)        | Ciphertext (n) | AuthTag (16)
AES-128-CBC   0x02 | IV (16)           | Ciphertext (n) | HMAC-SHA256 (32)
```

- 外设在 `providers[version]` 中按首字节选择 provider，因此 Central 可以在连接中途
  切换算法，无需重连。
- CBC 的 HMAC 覆盖 `Version | IV | Ciphertext`，**先验 MAC 再解密**。
- 主密钥 32 字节，AES 与 HMAC 密钥经 HKDF-SHA256 分离。
- 单帧可容纳的明文上限：GCM **4067 B**，CBC **4031 B**（受 4096 B 信封上限约束）。

### 3.3 命令（明文语义）

| 请求明文 | 响应明文 | 副作用 |
|---|---|---|
| `START` | `START_ACK` | 启动遥测（仅 Mock 实现） |
| `STOP` | `STOP_ACK` | 停止遥测（仅 Mock 实现） |
| `SET_RATE:<hz>` | `RATE:<hz>` | 修改频率 0.2–10 Hz（仅 Mock 实现） |
| `PING` | `PONG` | — |
| 其他任意字节 | 原样回显 | — |

命令表由 SDK 的 `DemoPeripheralBehavior` 统一提供，Mock 与 macOS 外设调用同一实现，
避免两端语义漂移。macOS 外设目前只使用回复文本，副作用留待后续阶段接入。

回显分支让任意长度的二进制负载（含多 chunk）都能端到端校验。

密钥：两端使用 `ModuBLE.DemoTestKey`。**这是公开的测试密钥，禁止用于生产。**

## 4. 传输约束

1. **请求-响应不是原子的**：写入成功 ≠ 业务响应成功；响应可能被 MTU 切片。
2. **必须自行分帧**：外设侧用 `PacketDecoder` 重组；Central 侧同样。
3. **UUID 必须可配置**：SDK 通过 `GATTProfile` 注入，不在传输层硬编码。
4. **TX 通道混有非协议数据**：`READY`、`RX #n: …` 是纯文本，帧解析必须能按 magic
   重同步（`PacketDecoder` 已实现）。
5. **Notify 载荷上限**为 `MTU - 3`；外设按所有订阅者中**最小的**
   `maximumUpdateValueLength` 切片。发送队列满时压入 `pendingNotifications`，等
   `peripheralManagerIsReady(toUpdateSubscribers:)` 补发。Central 不能假设写入后立刻回包。
6. **明文回退仍在**：组不出帧且缓冲区为空时，外设按旧式纯文本回 `RX #n: k bytes`。
   仅为迁移期兼容，生产应关闭。
7. **外设侧假设单一 Central**：多 Central 并发写入时按 offset 合并可能串包。

## 5. 安全边界

- 无重放保护：`sequence` 不校验单调性。
- 无双向认证：两端共享预置对称密钥，无法证明对端身份。
- 无密钥轮换：`DemoTestKey` 是公开测试密钥。
- 日志不记录密钥；测试会话的密文 / Nonce / IV 仅用于演示诊断。

## 6. 已验证记录

2026-11-14，iPhone ↔ macOS 外设（详见 `Device-Verification.md`）：

| 项 | 结果 |
|---|---|
| 扫描 / 连接 / 订阅 | ✅ 收到 `READY` |
| with / without response 写入 | ✅ 字节一致 |
| MTU 切片 | ✅ 1000 B → `512 + 488` |
| AES-128-GCM 闭环 | ✅ `START` → `START_ACK` |
| AES-128-CBC 闭环 | ✅ 连接中切换算法后仍闭环 |
| 加密 + 分包回显 | ✅ 1000 B 双向重组后逐字节一致 |
| 断连自动重连 | ⬜ 代码完成，未做真机验证 |

2026-11-19 复核：`swift test` 156 passed；`BLEPeripheralApp` 与 `ModuBLEDemo`
均可无签名构建通过（macOS 27 / Xcode 27 / Swift 6.4）。

## 7. 当前未实现（不要声称）

- 应用层 ACK bitmap、滑动窗口、选择性重传、重试计数。
- CRC 校验（协议层刻意不做）。
- 外设主动推送的 Telemetry / 姿态事件：Mock 与 macOS 外设均已实现，Demo Dashboard
  已展示。**真实 BLE 链路上的事件推送尚未做真机验证**（见 `Device-Verification.md`）。
- 多 Central 并发写入的隔离保证。
- 与任何商业量产设备的互操作性认证。
