# vRemoter 语音输入排查手册

此文档记录「遥控器语音键 → vRemoter → 豆包 / 微信输入法」链路的常见故障、判断方法与修复步骤。适用于 Chromecast Voice Remote（BLE）；X6 Remote 同样先按本文顺序确认 ATVV/音频与触发键两层。

## 1. 目标链路

```text
蓝牙遥控器（麦克风）
  └─ BLE ATVV 私有协议
       └─ vRemoter.app
            └─ 虚拟声卡 vRemoteDr 2ch
                 └─ 豆包 / 微信输入法语音输入
```

**关键认知：遥控器不是标准蓝牙麦克风。**

macOS 只把它当作 BLE HID 键盘配对（`Services: 0x400020 < HID BLE >`），系统「声音 → 输入」里不会出现它。它的麦克风走厂商私有 GATT 服务（Chromecast 为 `AB5E0001`），只有 vRemoter 这样的专门实现才能取到，再通过虚拟声卡 `vRemoteDr 2ch` 暴露给豆包。

链路本身成立，但有两处最容易断：ATVV 能力协商，以及触发键的左右侧匹配。

## 2. 典型现象

| 阶段 | 现象 |
|---|---|
| 最初 | 按遥控器语音键完全没反应，豆包也不弹 |
| ATVV 修好后 | 豆包能被唤起，但每次 `opening timeout`，认不出声音 |
| 全部正常 | 豆包打开、麦克风为 `vRemoteDr 2ch`、识别后自动上屏 |

## 3. 根因一：ATVV capabilities 协商死锁

### 症状

按遥控器语音键，日志连续出现：

```text
[CAST-BLE] micOpen gesture error: 尚未完成 ATVV capabilities 协商
[VOICE-SESSION] MIC_OPEN failed remote=chromecast
[VOICE-SESSION] MIC_OPEN retries exhausted remote=chromecast
```

遥控器语音键走的是 ATVV 私有命令，**不产生普通键盘事件**。通道一死，按下去就等于没按，所以表现为「遥控器根本不触发」。

### 原因

vRemoter 1.1.1 的 `getCapabilities` 只在连接时发送一次，响应丢失后**不重试**，状态机永久停在「未协商」，之后所有 `MIC_OPEN` 都被拒绝。

触发条件与 HID 抢占有关。事故日志中同时出现：

```text
[CAST-HID] manager open failed: 0xE00002C5   ← kIOReturnExclusiveAccess，独占冲突
[CAST-HID] waiting for Chromecast Remote     ← 反复重新枚举
mode=observe / mode=remap 来回切换
```

HID 管理器和 ATVV 抢同一个 BLE 设备，导致 GATT 通知丢失、CAPS 响应收不到。一次事故中 `尚未完成 ATVV capabilities 协商` 出现 253 次，而 `caps ok` 只有 2 次。

### 修复

**重启 vRemoter**（不是重启电脑）：

- 菜单栏 vRemoter 图标 → `控制台` → `重启 App`
- 或命令行：`pkill -x vRemote && open -a /Applications/vRemote.app`

重启后 1 秒内应看到：

```text
[CAST-BLE] TX getCapabilities
[CAST-BLE] caps ok v1.0 codec=ADPCM 16 kHz interaction=0x03 frame=160
```

**辅助措施：关闭「按键映射」**（控制台 → 按键映射 → 取消勾选「启用映射」）。映射关闭时走 `observe` 模式，不独占 HID，能显著降低复发概率。

### 判断是否复发

```bash
grep -c "尚未完成 ATVV capabilities 协商" ~/Library/Logs/vRemote/vRemote.log
grep -c "caps ok" ~/Library/Logs/vRemote/vRemote.log
```

前者持续增长、后者不增长，说明又卡死了。

## 4. 根因二：左右 ⌘ 不匹配

### 症状

ATVV 修好后，每次按键都是：

```text
[KEY] synthetic Command (⌘) DOWN
[KEY] synthetic Command (⌘) UP
[VOICE-SESSION] closed reason=opening timeout
```

遥控器有反应了，但豆包不弹。

### 原因

用 CGEvent tap 抓 vRemoter 实际注入的事件：

```text
type=12 code=54 flags=0x20100000 pid=77023   ← pid 77023 = vRemote
type=12 code=54 flags=0x20000000 pid=77023
```

- `code=54` = **右⌘（Right Command）**
- 豆包设置里配的是 **左⌘（keyCode 55）**

对照实验（vRemoter 关闭状态下直接注入）：

| 注入 | 豆包反应 |
|---|---|
| 左⌘ (55) | 立即弹出语音面板 ✅ |
| 右⌘ (54) | 无任何反应 ❌ |

vRemoter 的触发键支持 `Command / Option / Control / Shift / Fn`，但**发哪一侧是写死的**，不能在 App 内切换成左⌘。

### 修复

豆包输入法设置 → `语音输入` → **免按模式**右侧的 `左⌘` 胶囊：

1. 点一下 `左⌘`。
2. 按一下键盘**右边**的 ⌘。
3. 显示变成 `右⌘`。

> 注意：豆包用「免按模式」而不是「长按模式」。vRemoter 注入的是瞬时 tap（down/up 几乎同时），只有免按模式的「按一次开始、再按一次结束」才能匹配。

> 微信输入法：在「微信输入法设置 → 语音输入」中把免提模式快捷键保持为默认的 `Fn + 空格`，并在 vRemoter 控制台把输入法切到微信输入法、触发键选 `Fn`。vRemoter 会注入 `Fn + 空格` 来开关免提语音，而不是单按 Fn。

## 5. 最终验证

成功时日志长这样：

```text
22:41:04  physical ATVV DOWN remote=chromecast
22:41:04  [KEY] synthetic Command (⌘) DOWN / UP
22:41:04  [IME-STATE] target=doubao state=active devices=vRemoteDr 2ch   ← 豆包打开且麦克风正确
22:41:05  AUDIO_SUMMARY ... peak=14184 rms=1298 db=-28        ← 真实语音
22:41:11  [IME-STATE] target=doubao state=inactive                       ← 识别完成自动上屏
```

三个条件必须同时满足：

1. `caps ok` 出现过。
2. `state=active devices=vRemoteDr 2ch`（不是 `AB13X USB Audio` 等其他设备）。
3. `AUDIO_SUMMARY` 的 `db` 不是 `-120`（正常说话约 -25 ~ -45 dB）。

## 6. 5 分钟排查顺序

按顺序查，能快速定位是哪一层断了。

### 第 1 步：遥控器有没有被系统识别

```bash
system_profiler SPBluetoothDataType | sed -n '/Connected:/,/Not Connected:/p'
```

应看到 `Chromecast Remote`、`Minor Type: Keyboard`、`Services: < HID BLE >`。没有独立音频设备是正常的，它不是标准蓝牙麦克风。

### 第 2 步：ATVV 有没有协商成功

```bash
grep -c "caps ok" ~/Library/Logs/vRemote/vRemote.log
grep -c "尚未完成 ATVV capabilities 协商" ~/Library/Logs/vRemote/vRemote.log
```

`caps ok` 不增长 → 重启 vRemoter。

### 第 3 步：虚拟声卡有没有声音

用 ffmpeg 直接录 `vRemoteDr 2ch`（设备序号用下面命令查）：

```bash
ffmpeg -f avfoundation -list_devices true -i ""
ffmpeg -f avfoundation -i ":1" -t 8 -c:a pcm_s16le -y /tmp/vr.wav
ffmpeg -i /tmp/vr.wav -af volumedetect -f null - 2>&1 | grep volume
```

录制时按住遥控器说话：

- `max_volume` > -50 dB → 上游正常，问题在豆包。
- 一直 -91 dB → ATVV 没通，回到第 2 步。

### 第 4 步：豆包麦克风选对没有

```bash
grep "IME-STATE" ~/Library/Logs/vRemote/vRemote.log | tail -5
```

必须是 `devices=vRemoteDr 2ch`。如果是 `AB13X USB Audio` 或别的设备，去豆包设置里把「麦克风选择」固定成 `vRemoteDr 2ch`，**不要用自动检测**。

### 第 5 步：触发键对不对

查看 vRemoter 控制台 → 按键映射 → 触发键，与豆包「语音输入」里的快捷键比对。

vRemoter 实际发的是**右⌘**，所以豆包应设为 `右⌘`。

## 7. 关键路径速查

| 项目 | 路径 / 值 |
|---|---|
| vRemoter 日志 | `~/Library/Logs/vRemote/vRemote.log` |
| vRemoter 配置 | `defaults read local.simaqingfeng.vRemote` |
| 遥控器 UUID 缓存 | `~/Library/Application Support/vRemote/chromecast-remote-uuid.txt` |
| 虚拟声卡 | `vRemoteDr 2ch`（Existential Audio Inc.） |
| 豆包 IME | `/Library/Input Methods/DoubaoIme.app` |
| 微信输入法 IME | `/Library/Input Methods/WeType.app` |
| 豆包设置 App | `/Library/Input Methods/DoubaoIme.app/Contents/Applications/DoubaoImeSettings.app` |
| 微信输入法设置 App | `/Library/Input Methods/WeType.app/Contents/MacOS/WeTypeSettings.app` |
| ATVV 服务 | `AB5E0001`（command `0002` / audio `0003` / control `0004`） |
| 音频编码 | ADPCM 16 kHz，frame=160 |

## 8. 已知脆弱点

1. **ATVV 死锁会复发** —— 1.1.1 的 `getCapabilities` 无重试。出现「完全没反应」先重启 App。
2. **不要开按键映射** —— remap 模式独占 HID，是死锁的主要诱因。
3. **启动后别立刻按** —— caps 协商需要 1 秒左右，刚启动就按会失败。
4. **Mac mini 没有内置麦克风** —— 日志里的「双麦克风混音」可能实际只有遥控器一路，属正常。
5. **不要把系统输出设成 `vRemoteDr 2ch`** —— 会形成回授啸叫。

## 9. 空闲时麦克风指示灯常亮（macOS 27）

### 现象

没有按遥控器、豆包也没有在录音，菜单栏的橙色麦克风指示一直亮着。退出 vRemoter 后熄灭。

### 原因

不是 macOS 27 的 bug，也不是豆包在偷听。vRemoter 为了让遥控器按下时零延迟出声，从启动到退出一直让 `vRemoteDr 2ch` 的 IOProc 跑着：

- `AudioPipe.init` 调用 `startOutputDevice()`；
- IOProc 是双向的，`AudioDeviceStart` 后设备的输入流也算活动；
- `setRemoteActive(false)` 只停止混音数据，不停 IOProc；
- `AudioPipe.stop()` 只在 App 退出时调用。

用 CoreAudio 进程属性查到的状态：

```text
pid=41181  local.simaqingfeng.vRemote        isRunningInput=1
pid=85593  com.bytedance.inputmethod.doubaoime isRunningInput=0
```

vRemoter 是空闲时唯一占用输入流的进程，所以指示灯常亮。

### 结论

功能上没问题，只是指示灯的语义变差了：空闲和录音时都亮，无法一眼判断豆包是否真的在录。常驻音频 IO 也可能影响闲置睡眠和功耗。

### 当前决定

2026-11-04：**暂不优化，先记录。** 当前版本继续保留常亮行为。以后要做时，按报告的 stream usage 方案改，不要用按需启停；后者需要改会话时序，回归风险更高。

完整实验数据、代码和风险分析见 [MIC-INDICATOR-RESEARCH.md](MIC-INDICATOR-RESEARCH.md)（第 8 节对比按需启停，第 9 节是推荐实现）。

### 可选修复

调研结论：保留常驻 IOProc，用 `kAudioDevicePropertyIOProcStreamUsage` 关闭它的输入流即可。macOS 27.0 实测 `isRunningInput` 从 1 变为 0，菜单栏橙色圆点随之熄灭，输出音频不受影响，也不需要改会话状态机。

临时让灯熄灭：退出 vRemoter。

---

## 附：诊断用事件监听器

用来确认某个 App 实际注入了什么按键。保存为 `/tmp/tap.swift`，`swift /tmp/tap.swift` 运行：

```swift
import CoreGraphics
import Foundation

let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: CGEventMask(mask),
    callback: { _, type, event, _ in
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        print("type=\(type.rawValue) code=\(code) flags=0x\(String(flags, radix: 16)) pid=\(pid)")
        fflush(stdout)
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil
) else { print("tap failed"); exit(1) }

let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
CFRunLoopRun()
```

常用 keyCode：

| 键 | keyCode |
|---|---|
| 左⌘ | 55 |
| 右⌘ | 54 |
| 左⌥ | 58 |
| 右⌥ | 61 |
| 左⌃ | 59 |
| 右⌃ | 62 |

判断方法：看 `pid` 是否为 vRemote 进程号，看 `code` 是 54 还是 55。
