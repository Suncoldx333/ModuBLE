# 参考外设 GATT 契约

> 来源：`bleProject/BLEPeripheralApp/`（macOS 外设 App）实测代码
> 记录时间：2026-11-14
> 状态：**已确认，可直接用于 SDK 实现**

本文件是 iPhone 端 SDK 与 Mac 外设之间唯一的事实来源。任何一方要改动 UUID、
属性或载荷格式，必须先改这里。

## 1. GATT 定义

| 项 | 值 | 备注 |
|---|---|---|
| Service | `5A0C8B3E-7D2F-4A6B-9C1D-3E5F7A9B1C2D` | primary，唯一 Service |
| RX（代码中名为 Data） | `9F8E7D6C-5B4A-3F2E-8D7C-6B5A4F3E2D1C` | 属性 `.read, .write, .writeWithoutResponse`；权限 `readable, writeable` |
| TX（代码中名为 Status） | `1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D` | 属性 `.read, .notify`；权限 `readable` |

代码位置：`PeripheralManager.swift:7-11`（常量）、`:61-85`（特征构造）。

两个特征挂在同一个 Service 下。**iPhone 端写入 RX，订阅 TX。**

## 2. 当前外设的真实行为

| 时机 | 行为 |
|---|---|
| Central 订阅 TX 成功 | 立即 Notify 一次 UTF-8 字符串 `READY`（`:132`） |
| 收到**非协议**写入 | 保存字节，并 Notify `RX #<序号>: <字节数> bytes`（兼容旧链路） |
| 收到**协议帧** | 解密 → 按命令生成响应 → 加密 → Notify 同 sequence 的响应帧 |
| Central 读取 RX | 返回最后一次写入的原始字节（`:145-162`） |
| Central 读取 TX | 返回最后一次 Notify 的原始字节（`:145-162`） |
| Central 连接/断开 | 不产生任何 Notify |
| 广播存活 | 广告期间持有电源断言，禁止 App Nap / 空闲睡眠；每 5 秒自检，若系统静默回收广播则自动重启 |

设计约束（`:164-201`）：

- **没有命令解析**：外设不识别 `START` 之类的业务指令，因此**不会返回 `START_ACK`**。
- **没有加密**：收发都是裸字节，无 AES/HMAC 痕迹。
- **没有应用层重组**：每次 `offset == 0` 的写入算独立一包；`receivedStream` 只是把
  所有字节按到达顺序拼接。长写（prepare/execute）仅在 offset 连续时被合并。
- **Notify 载荷上限**受 ATT MTU 限制（`MTU - 3`）。外设发送队列满时会把数据压入
  `pendingNotifications`，等 `peripheralManagerIsReady(toUpdateSubscribers:)`
  再补发（`:245-270`）。SDK 必须容忍 Notify 的延迟到达，不能假设写入后立刻回包。

## 3. 对 SDK 的约束

1. **不能假设请求-响应是原子的**。写入成功 ≠ 业务响应成功。
2. **必须自行分帧**。外设不会重组，所以逻辑帧要么放进单次写入，要么在帧头带长度并
   由接收方缓冲（`PacketDecoder` 已实现）。
3. **UUID 必须可配置**。当前两端各自硬编码了一份常量
   （`PeripheralManager.swift:7-11`、`ScannerManager.swift:7-9`），SDK 用
   `GATTProfile` 注入。
4. **Notify 通道里混有非协议数据**。阶段 3（明文）会收到 `READY` / `RX #n: …` 这类
   纯文本；SDK 的帧解析必须能跳过它们（`PacketDecoder` 按 magic 重同步）。
5. **RX 可读**，可用于"写入后回读"做字节一致性校验，这条通路不需要改外设。

## 4. 应用层协议（阶段 5 已实现）

外设现在能识别 `ModuBLE` 的协议帧，与纯文本状态共存：

```text
帧：     Magic "MB" (2) | Version (1) | Kind (1) | Sequence (4) | Length (2) | Payload
Payload：密文信封（默认 AES-128-GCM）
            Version 0x01 | Nonce (12) | Ciphertext | AuthTag (16)
         若换用 CBC 则为
            Version 0x02 | IV (16) | Ciphertext | HMAC-SHA256 (32)
```

命令与响应（明文语义）：

| 请求明文 | 响应明文 |
|---|---|
| `START` | `START_ACK` |
| `PING` | `PONG` |
| 其他任意字节 | 原样回显 |

回显分支让任意二进制载荷（含多 chunk）都能端到端校验。

密钥：两端使用 `ModuBLE.DemoTestKey.aes128GCM`，**这是公开的测试密钥，禁止用于生产**。

外设侧判断逻辑（`PeripheralManager.ingest`）：

1. 字节进入 `PacketDecoder`，按 magic 重同步；
2. 组出完整帧 → 解密 → 生成响应 → 加密 → 按 `maximumUpdateValueLength` 分片后 Notify；
3. 组不出帧且缓冲区为空 → 视为旧式纯文本，回 `RX #n: k bytes`。

## 5. 分阶段验收标准的调整

原计划阶段 3 要求 `START` → `START_ACK`，当时外设没有命令处理，验收降级为"写入 + 回读"。
**阶段 5 之后该标准已恢复**：外设理解协议帧并能返回 `START_ACK`。

## 6. 已验证的环境事实

- Mac App：macOS 13.0+，entitlement 含 `com.apple.security.device.bluetooth`，沙盒开启。
- iPhone App：iOS 17.0（工程用 `$(RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET)`，当前解析为 17.0）。
- 两端 `SWIFT_VERSION = 5.0`，均无测试 target。
- 两端均使用 `CBPeripheralManager` / `CBCentralManager` 的默认 main queue。
