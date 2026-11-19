# Demo script

A 75–90 second recording for a portfolio page or Upwork proposal. Record at
device resolution, no voice-over required — burn in short captions.

## Preconditions

- iOS demo installed on a simulator or a physical iPhone.
- Mock transport selected (no hardware needed).
- Optional second take: `BLEPeripheralApp` running on a Mac for the real-link shot.

## Shot list

| # | Time | Screen | Action | Caption |
|---|---|---|---|---|
| 1 | 0:00–0:06 | Devices | Show the transport picker, tap **Scan** | "Swift BLE SDK — discovery, encrypted sessions, telemetry" |
| 2 | 0:06–0:12 | Devices | Two mock devices appear; point at name, RSSI, source badge | "Mock peripheral: no hardware, same code path as a real link" |
| 3 | 0:12–0:20 | Devices → push Diagnostics | Tap **Mock Motion Sensor**, then connect | "Connect → GATT discovery → encrypted session" |
| 4 | 0:20–0:32 | Dashboard | Values update at 1 Hz; angle bars move | "Telemetry decoded from authenticated event frames" |
| 5 | 0:32–0:38 | Dashboard | Change the sample rate to 4 Hz | "Sample rate is a request, not a local timer" |
| 6 | 0:38–0:46 | Logs | Scroll the TX/RX entries | "Every frame, sequence and payload is logged in order" |
| 7 | 0:46–0:58 | Simulator | Raise **Drop frame** to 50%, go back, send PING | "Fault injection: dropped frames surface as request timeouts" |
| 8 | 0:58–1:04 | Simulator | Raise **Corrupt payload**, send again | "Tampered ciphertext fails AEAD authentication" |
| 9 | 1:04–1:12 | Devices | Tap **Drop link now**, watch reconnect countdown | "Unexpected disconnect → bounded backoff → fresh session" |
| 10 | 1:12–1:25 | Mac + iPhone (optional) | Start advertising on the Mac, connect from the iPhone, send START | "Same SDK against a real CoreBluetooth peripheral" |
| 11 | 1:25–1:30 | End card | — | "168 unit tests · Mock + real BLE · MIT licensed" |

## Recording notes

- Clear the log before shot 6 so the list is readable.
- Keep the Simulator percentages under 50% for the first fault shot; 100% makes
  the next request fail immediately and looks like a bug.
- Reset faults between takes (`Clear faults`), otherwise the reconnect in shot 9
  inherits the previous corruption.
- For the Mac shot, put the Mac and iPhone in the same frame; the Mac panel shows
  `Events sent` incrementing while the iPhone dashboard moves.

## Claims to avoid

- Do not say "tested with commercial hardware" — the reference device is a Mac.
- Do not say "production-ready security" — there is no replay protection, key
  agreement or key rotation.
- Do not show CRC rows or ACK-bitmap features; they do not exist in this protocol.
