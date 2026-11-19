# 真机联调清单

> 目标：验证 `ModuBLE` 的 BLE 传输层能真实扫描、连接、订阅、双模式写入，
> 并确认"写入的内容"与"外设收到的内容"一致。
>
> 前置：`Documentation/Peripheral-GATT.md` 里的 GATT 定义。

## 1. 准备

| 角色 | 操作 |
|---|---|
| Mac | 打开 `Demo/BLEPeripheralApp.xcodeproj`，运行 `BLEPeripheralApp`，点 **Start Advertising** |
| iPhone | 打开 `Demo/ModuBLEDemo.xcodeproj`，选择真机，运行 `ModuBLEDemo` |

确认 Mac 上显示 **Advertising: Yes**，并记下 Rx/Tx 的订阅者数量（初始为 0）。

## 2. 步骤与预期

### 2.1 扫描

1. iPhone 上点 **Scan**
2. 预期：列表出现 `MacBLE`，副标题是设备 Identifier

日志预期（按顺序）：

```text
Central state: poweredOn
Scan started for 5A0C8B3E-7D2F-4A6B-9C1D-3E5F7A9B1C2D
```

### 2.2 连接

1. 点设备进入详情，点 **Connect**
2. 预期：State 变为 `Ready`，`Status Subscription: Active`

日志预期：

```text
Connecting to MacBLE
Connected at ATT level
Service found 5A0C8B3E-…
Characteristics found, subscribing to TX
Notify subscribed
RX 5 B
```

最后那条 `RX 5 B` 是外设订阅成功后主动推的 `READY`（payload 区会显示 `READY`）。
Mac 上 **Status Subscribers** 应变成 1。

### 2.3 写入（With Response）

1. 输入框保持 `Hello from ModuBLEDemo`
2. Write Type 选 **With Response**，点 **Send Packet**

预期：

- Demo 出现 `TX 21 B`，payload 区显示 hex 和 `Hello from ModuBLEDemo`
- Mac 的 Received Packets 出现 `#1 … 21 B`，内容是同一串文本
- Demo 出现 `RX … B`，payload 是 `RX #1: 21 bytes`

### 2.4 写入（Without Response）

1. Write Type 选 **Without Response**，再发一次

预期：同样的 `TX 21 B` 与 Mac 端 `#2 21 B`。这条验证的是 `writeWithoutResponse` 分支。

### 2.5 分包（多 chunk）

1. 进入详情页，找到 **Chunk Test** 区
2. 保持 `Payload: 1000 B`（默认值），点 **Send 1000 B (auto-chunked)**

预期：日志出现**多条** `TX n B`（每条 = 一个 ATT 写入），Mac 端 `Full Message`
按 1000 字节增长，内容为 `00 01 02 … FF` 循环。

**注意**：单次写入上限实测通常是 **512**，所以 300 B 会被一次送完，根本走不到
切片逻辑。`Plan` 一行会提前算出次数；如果显示 1，就说明 payload 还不够大，App 也会
在 footer 里提示。

### 2.6 限速传输

1. 回到详情页，**Paced Transfer** 区点 **Start 500 B Transfer**
2. 预期：每 3 秒发一包，进度条推进，每包显示 ACK 与延迟毫秒数
3. Mac 端 `Full Message` 最终为 500 字节，内容为 `00 01 02 … FF` 循环

### 2.7 断连与重连

**注意：在 Mac 上点 Stop Advertising 只会停止广播，已经建立的连接不会断**，所以不会
触发重连。要真的断开链路，用下面任意一种：

- 在 Mac 上 **Cmd+Q 退出 `BLEPeripheralApp`**
- 在 Mac 上关闭蓝牙

预期（意外断连时）：

```text
Disconnected: … [CBErrorDomain:7]
Connection lost
Auto-reconnect started · delays 1, 2, 4, 8, 16, 32 s
```

界面上：`State` 变成 **Reconnecting**，并出现 `Attempt n/6` 与倒计时。
重新打开 Mac App 并 Start Advertising 后，6 次尝试内应恢复 `Ready`。

6 次都失败会弹出手动重连对话框，同时显示 "All automatic reconnect attempts failed."。

### 2.8 加密闭环（阶段 5）

1. 确认连接就绪，Detail 页 **Transport** 保持 **Encrypted**
2. 点 **Quick Commands** 里的 **START**（无需手打）

预期：

- Demo 日志：`Request #1 sealed · 5 → 34 B`，随后是密文的 `TX` 条目（肉眼不可读）
- Mac 控制台：`[BLEPeripheral] frame #1 → 5 B in, 9 B out, 38 B on air`
- Demo 日志：`Decrypted response #1 · 9 B`，payload 显示 `START_ACK`
- 详情页出现 **Last Decrypted Response**，内容 `START_ACK`

### 2.9 加密 + 分包

1. Chunk Test 保持 `1000 B`，发送
2. 预期：请求加密后变成 1029 字节，按 512 切成 3 次写入；外设回显 1000 字节，
   同样分片 Notify
3. 最终 **Last Decrypted Response** 应是 1000 字节，hex 与发送的 `00 01 02 … FF` 完全一致

这一步同时验证：分帧、MTU 切片、AEAD 认证、双向分片重组。

### 2.10 CBC 闭环

1. 连接后，Send Packet 里把 **Algorithm** 切到 `AES-128-CBC + HMAC-SHA256`
   （不需要重连，会话会原地换 provider）
2. 点 Quick Commands → **START**

预期：同样收到 `START_ACK`，但密文长度不同——CBC 有 PKCS#7 填充和 32 字节 HMAC：

```text
请求帧 = 1 + 16 (IV) + 16 (密文) + 32 (HMAC) + 10 (帧头) = 75 B
```

Mac 控制台会标出算法：

```text
[BLEPeripheral] frame #1 (AES-128-CBC + HMAC-SHA256) → 5 B in, 9 B out, 75 B on air
```

再切回 GCM 发一次，确认两种格式可以随时切换且互不干扰。

### 2.11 遥测推送（阶段 6）

1. 连接就绪后点 **START**
2. 预期：Dashboard 的 Yaw / Pitch / Roll 每秒更新；Mac 面板 `Events sent` 递增，
   `Yaw / Pitch / Roll` 同步显示同一组数值
3. 把采样率改到 4 Hz：预期更新变快，Mac 面板的 `Rate` 同步变化
4. 点 **STOP**：预期数值停止更新，`Events sent` 不再增长
5. 关闭 Mac 外设：iOS 进入重连，Dashboard 显示连接已断开

> 若这里收不到事件但 `START_ACK` 正常，先看 Mac 面板的 `Streaming` 和
> `Waiting for a subscribed central.`：没有订阅者时外设不会推送。

## 3. 判定标准

| 项 | 通过条件 |
|---|---|
| 阶段 2 扫描 | 能扫到 `MacBLE`，Identifier 稳定 |
| 阶段 2 连接 | `Notify subscribed` 出现，State = Ready |
| 阶段 2 错误处理 | 关掉 Mac 蓝牙后重试，Demo 显示 "Bluetooth is off."，不崩溃 |
| 阶段 3 明文链路 | 2.3 / 2.4 两种写入 Mac 端都收到完全一致的字节 |
| 阶段 3 分包 | 2.5 的多条 `TX` 拼起来正好等于发送内容 |
| 阶段 3 断连 | 断连后能自动重连，或 6 次失败后弹出手动重连 |
| 阶段 5 加密 | `START` 收到 `START_ACK`，且日志里的 TX 是不可读密文 |
| 阶段 5 加密+分包 | 1000 B 回显内容与发送完全一致 |

## 3.1 已验证记录

2026-11-14，iPhone ↔ macOS 外设：

| 项 | 结果 |
|---|---|
| 扫描 / 连接 / 订阅 | ✅ 收到 `READY`（5 B） |
| With Response 写入 | ✅ Mac 收到 21 B，内容一致 |
| Without Response 写入 | ✅ Mac 收到第二包 |
| 分包 | ✅ 1000 B → `512 + 488` 两次写入，累计流 322 → 834 → 1322 B |
| AES-128-GCM 闭环 | ✅ `START`（5 B）→ 44 B 请求帧 → Mac 解密 → `START_ACK`（9 B）→ 48 B 响应帧 → iPhone 解密 |
| AES-128-CBC + HMAC 闭环 | ✅ 连接中切换到 CBC（不重连），`START` → 75 B 帧 → `START_ACK` |
| 加密 + 分包回显 | ✅ 1000 B → 1029 B 信封 → 512+512+15 写入 → 外设回显 → 分片 Notify → 解密后 1000 B 完全一致 |
| 遥测事件推送 | ⬜ 待验证（Mock 已覆盖；真实链路按 2.11 执行） |
| 断连重连 | ⬜ 待验证（需 Cmd+Q 退出 Mac App，Stop Advertising 不会断连） |

2026-11-19 复核（未接真机，仅构建与单测）：

| 项 | 结果 |
|---|---|
| `swift test` | ✅ 156 passed, 0 failed |
| `BLEPeripheralApp` Debug 构建 | ✅ 通过（`CODE_SIGNING_ALLOWED=NO`，macOS 27 / Xcode 27） |
| `ModuBLEDemo` iOS Simulator 构建 | ✅ 通过（同上） |

> 上面两行只证明工程可编译、单测可通过，**不构成真机验证**。

## 4. 需要回报的信息

1. 步骤 2.2 的完整日志截图（重点是 `Notify subscribed` 之后的几条）。
2. 步骤 2.5 里单条 `TX n B` 的 n 是多少 —— 这就是实测 MTU 载荷（通常 182 或 512）。
3. 任何 `lastError` 的原文。
4. Mac 端 Received Packets 的字节数是否与 `TX n B` 一致。

## 5. 常见失败与含义

| 现象 | 含义 |
|---|---|
| 扫不到设备 | 外设没在广播；或 Mac 蓝牙关闭；或 UUID 不一致 |
| 连接后卡在 `Discovering services` | Service UUID 不匹配，或外设未添加 Service |
| `Characteristic … not found` | RX/TX UUID 配错 |
| `Subscription failed` | TX 特征没有 `.notify` 属性 |
| `Write failed: …` | 写入类型与特征属性不匹配（例如对只支持 writeWithoutResponse 的特征发 write request） |
| 只收到 `READY` 没有 `RX #n` | 外设没收到写入，检查写入类型选择 |

## 6. 日志在哪看

**App 内**：进入设备详情页，往下滚到最后一节 **`Log (n)`**。每行左边是方向图标
（↑ 写入 / ↓ 通知），下面是时间、消息、以及 payload 的 hex 与 UTF-8 文本。
右上角 **Copy** 可以把整段日志复制出来，**Clear** 清空。

**Xcode 控制台**：DEBUG 构建会把同样的日志镜像到控制台，格式为

```text
[14:03:22.081] INFO    ble       Connecting to MacBLE
[14:03:22.081] DEBUG   ble       Peripheral state before connect: disconnected
```

两者顺序和内容一致。若你在 Xcode 里运行，直接看控制台最快。

## 7. 连接卡住时怎么定位

SDK 有两道超时，**超时时间与提示文案不同**，从报错就能直接判断卡在哪一段：

| 报错文案 | 阶段 | 含义 |
|---|---|---|
| `Timed out: the peripheral never accepted the connection (15 s).` | ATT 连接 | `didConnect` 没来：外设已停止广播、超出范围、或系统残留了旧链路 |
| `Timed out during service discovery or TX subscription (10 s).` | GATT 发现 | 链路已通，但外设不响应发现/订阅请求，或 UUID 不匹配 |

等待超时前，也可以点 **Cancel** 中止。看日志的**最后一条**即可判断卡在哪一跳：

| 最后一条日志 | 卡在 |
|---|---|
| `Connecting to MacBLE` | CoreBluetooth 没回 `didConnect`：外设停止广播、距离过远、或系统里残留着一条旧连接 |
| `Peripheral state before connect: connected` 之后无输出 | 系统已有链路，SDK 会直接进入服务发现；若仍无后续，说明外设不响应请求 |
| `Connected at ATT level · …` | 链路已建立，但服务发现没回：Service UUID 不匹配 |
| `Discovering characteristics` | 特征发现没回：外设未正确添加特征 |
| `Subscribing to TX …` | `setNotifyValue` 没有回调：TX 特征属性异常 |

对应处理：

1. 两台设备都**彻底退出 App 再重开**（残留的 BLE 链路通常要这样清掉）。
2. Mac 上关掉再打开蓝牙，然后重新 **Start Advertising**。
3. iPhone 上关闭再打开蓝牙。
4. 仍然卡在 `Connecting to …` 时，把 `Peripheral state before connect:` 的值一并回报。

## 8. Mac 外设侧的诊断项

Mac App 控制面板新增了「Diagnostics」区块：

| 项 | 含义 |
|---|---|
| `Keep-awake` | 广告期间持有电源断言（禁止 App Nap 与空闲睡眠）。必须是 **Active**，否则 Mac 会在后台悄悄停止响应连接 |
| `Advertising watchdog` | 系统静默丢弃广播、被自动恢复的次数。**只要大于 0，就说明之前确实被系统回收过** |
| `Last central activity` | 最近一次 central 订阅 / 读 / 写的时间。连接成功但这里一直是 `none`，说明链路建立了但没有任何交互 |

还有 **Force Restart Advertising** 按钮：手动丢弃并重启广播，用于清掉状态异常的广播。

iPhone 端设备列表现在也显示 **RSSI**：

- `-85 dBm` 以下标红：信号太弱，连接大概率超时，先把两台设备靠近。
- RSSI 数字长时间不刷新：说明广播已经停了，列表里是系统缓存，连接必然失败。
