# 麦克风指示灯常亮：Output Only 方案调研

> 调研日期：2026-11-04
> 系统：macOS 27.0（26A428，Darwin 27.0.0）
> 机器：Mac mini M4
> 版本：vRemoter 1.1.1
> 设备：`vRemoteDr 2ch`（Existential Audio / BlackHole 衍生驱动）+ Chromecast Voice Remote

> **当前状态（2026-11-04）：调研完成，暂不实施。** 先保留记录；等有整块时间再按第九节的 stream usage 方案修改，不要临时改用按需启停。

---

## 一、结论

**Output Only 方案可行，而且不会影响现有语音输入链路。** 本报告结论来自独立 CoreAudio 探针；集成到 vRemoter 后仍需按第十一节做一次实机确认（首字、爆音、指示灯）。

实测在 macOS 27.0 上有两种等效实现：

1. **HALOutput AudioUnit 只启用输出**：`EnableIO(output)=1`、`EnableIO(input)=0`。
2. **保留现有 IOProc，但用 `kAudioDevicePropertyIOProcStreamUsage` 关闭输入流**。

两者都能让 vRemoter 进程的 `kAudioProcessPropertyIsRunningInput` 从 `1` 变成 `0`，同时输出侧仍然正常写声。第二种是**最小改动**：不动渲染回调、不动会话状态机、不动启停时机、不增加启动延迟，因此推荐作为 vRemoter 的实现方案。

---

## 二、橙色指示灯是怎么亮的

macOS 的橙色麦克风指示来自 CoreAudio 的「是否有进程正在使用活动输入流」状态。最精确的公开观测点是 Process 对象的：

```text
kAudioProcessPropertyIsRunningInput
```

Apple 头文件对它的定义是：

> A UInt32 where a value of 0 indicates that the process is not running any IO or there is not any active input streams, and a value of 1 indicates that the process is running IO and there is at least one active input stream.

也就是说，**不看设备级 `DeviceIsRunningSomewhere`，看进程级 `IsRunningInput`**。设备可能因为别的客户端在跑，但某个进程自己不一定在采集。

优化前实测：

```text
pid=41181  local.simaqingfeng.vRemote        isRunning=1  isRunningInput=1
pid=85593  com.bytedance.inputmethod.doubaoime isRunning=0  isRunningInput=0
device vRemoteDr 2ch                         isRunningSomewhere=1
```

`vRemoter` 是当时唯一 `isRunningInput=1` 的进程，所以橙色灯是它点亮的，不是豆包，也不是 macOS 27 的 bug。

---

## 三、当前实现为什么一直亮

`Sources/vRemote/AudioPipe.swift`：

- `init` 里一旦找到 `vRemoteDr 2ch` 就调用 `startOutputDevice(deviceID)`（第 78–85 行）。
- `startOutputDevice` 用 `AudioDeviceCreateIOProcIDWithBlock` 创建 IOProc，然后 `AudioDeviceStart`（第 440–464 行）。
- 这个 IOProc 是**双向**的：设备有输入流，`AudioDeviceStart` 之后输入流就算「活动」。
- `setRemoteActive(false)` 只把 `mixActive` 置 false，让混音输出静音（第 117–136 行）；它不会停 IOProc。
- `stop()` 只在 App 退出时调用（第 174–192 行）。

所以 vRemoter 从启动到退出，IOProc 一直在跑，`isRunningInput` 一直是 1，橙色灯常亮。日志里能看到这种长期驻留：

```text
22:39:39  [AUDIO] vRemote IOProc 已启动: id=90, 48000 Hz stereo
...
22:49:29  [AUDIO] 双麦克风混音关闭
22:49:29  [VOICE-SESSION] audio route OFF
```

「混音关闭」只是数据停了，音频 IO 没停。

---

## 四、实验设计

测试程序是本次调研临时编写的两个 Swift 探针：

- `output_only_test.swift`：创建不同形式的音频 IO，查询本进程的 `isRunning` / `isRunningInput`。
- `tone_test.swift`：向 `vRemoteDr 2ch` 写 440 Hz、4 秒正弦波，同时用 ffmpeg 录 `vRemoteDr 2ch`，确认输出真的到达虚拟声卡。

四种策略：

| 代号 | 策略 |
|---|---|
| A | 当前方式：`AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`，输入流默认启用 |
| B | 同 A，但启动前用 `kAudioDevicePropertyIOProcStreamUsage` 把输入流全部设为 0 |
| C | `kAudioUnitSubType_HALOutput`，只启用输出（`EnableIO input=0`） |
| C-control | 同 C，但启用输入（`EnableIO input=1`），用于验证测量方法 |

前两组测试（进程状态、输出录音）时 vRemoter 仍在运行，因此每个测试都是「在已有客户端之上再加一个客户端」；5.3 的菜单栏视觉对照则临时退出了 vRemoter，对照结束后已重新启动。测试只持续 1–4 秒，输出静音或 440 Hz 正弦，不影响正常录音。

---

## 五、实验结果

### 5.1 进程状态

| 策略 | `isRunning` | `isRunningInput` | 说明 |
|---|---:|---:|---|
| A 当前 IOProc | 1 | **1** | 输入流活动，指示灯会亮 |
| B IOProc + 关闭输入流 | 1 | **0** | 输出仍在跑，但不算输入 |
| C HALOutput output-only | 1 | **0** | 同上 |
| C-control 启用输入 | 1 | **1** | 证明测量方法有效 |

停止后三种方式都回到：

```text
isRunning=0  isRunningInput=0
```

### 5.2 输出是否真的可用

用 ffmpeg 录 `vRemoteDr 2ch`，检查 `volumedetect`：

| 策略 | 回调次数 / 4 秒 | 输出帧数 | 录制结果 |
|---|---:|---:|---|
| A 当前 IOProc | 375 | 192000 | 有 440 Hz，`max_volume=-20.8 dB` |
| B IOProc + 关闭输入流 | 375 | 192000 | 有 440 Hz，`max_volume=-20.8 dB` |
| C HALOutput output-only | 375 | 192000 | 有 440 Hz，`max_volume=-6.8 dB` |

A 和 B 的电平完全一致，说明**关闭输入流没有改变输出增益或回调频率**。C 的电平更高，是因为 AudioUnit 走了不同的格式/混音路径；它不是本次推荐方案，仅作为对照。

回调次数 375 / 4 秒 ≈ 每 10.67 ms 一次，约 512 帧 @ 48 kHz，和当前 IOProc 的缓冲节奏一致。

### 5.3 菜单栏视觉验证

为了确认进程属性确实对应菜单栏指示，临时退出 vRemoter 后做了对照（测试结束后已重新启动 vRemoter）：

| 状态 | 菜单栏右侧橙色圆点 |
|---|---|
| vRemoter 运行（当前实现） | 亮 |
| 退出 vRemoter | 灭 |
| 只跑 output-only tone 4 秒 | **灭** |
| 跑双向 IOProc tone 4 秒 | **亮** |
| 重新启动 vRemoter | 亮 |

这说明 output-only 不仅让 `isRunningInput=0`，系统菜单栏指示也真的熄灭。

菜单栏里还可能看到带麦克风图标的橙色胶囊，它和 App 身份/第三方监控有关；命令行探针只能复现右侧圆点。实际 vRemoter 构建后，应以「空闲时圆点和胶囊都熄灭、豆包录音时正常亮起」为准。

---

## 六、关键发现

1. **Output Only 确实能让 `isRunningInput=0`，菜单栏橙色圆点也会熄灭。**
   这直接对应橙色指示灯的熄灭条件；双向 IOProc 则会重新点亮。

2. **不一定非要换 AudioUnit。**
   现有 IOProc 只要把输入流标记为「不使用」，效果相同，改动量小得多。

3. **关闭输入流不影响输出。**
   440 Hz 正常写入 `vRemoteDr 2ch`，回调次数和帧数不变，电平与当前方式一致。

4. **这是 per-IOProc 设置。**
   `AudioHardwareIOProcStreamUsage.mIOProc` 指定具体 IOProc，只影响 vRemoter 自己，不影响豆包或其他客户端读取 `vRemoteDr 2ch`。

5. **必须包含该方向的全部输入流。**
   Apple 头文件要求 `mNumberStreams` 覆盖该方向的所有流；全部 `mStreamIsOn=0` 才会关闭输入。vRemoteDr 当前是 1 条立体声输入流，所以结构体大小是 16 字节。

6. **不需要按需启停。**
   IOProc 可以继续常驻，保持零启动延迟；只是它不再被算作「正在使用输入」。

---

## 七、对语音输入链路的影响

### 7.1 不受影响的部分

- `render()` 回调、混音逻辑、`setRemoteActive()`、`AudioPipe.stop()` 都不用改。
- 会话状态机、ATVV 短按/长按、1.1.1 的持久流重开逻辑都不用改。
- IOProc 仍在 App 启动时创建并启动，第一包 BLE 音频到达前设备已绑定。
- 豆包仍然按原方式打开 `vRemoteDr 2ch`，设备仍是默认输入设备。
- 录音期间豆包自己的 `isRunningInput=1`，橙色灯会正常亮起，语义反而更准确。

### 7.2 会变化的部分

- vRemoter 空闲时不再被算作「正在采集输入」，橙色灯熄灭。
- IOProc 的输入缓冲区 `mData` 会变成 `NULL`。当前渲染回调完全忽略输入参数：

  ```swift
  { [weak self] _, _, _, outputData, _ in
      self?.render(outputData)
  }
  ```

  所以没有影响。如果以后要在 IOProc 里读取输入，需要重新打开输入流。

### 7.3 MacBook 的额外情况

这条修复只解决 `vRemoteDr 2ch` 的输入流。MacBook 上还有一条独立路径：

```swift
AudioPipe.startBuiltInMicCapture()
```

它在 App 启动时就 `captureSession.startRunning()`，只要 `macInputEnabled` 为 true，内置麦克风也会让 vRemoter 的 `isRunningInput=1`。

因此：

- **Mac mini / Mac Studio**：没有内置麦，本方案就能让指示灯只在豆包录音时亮。
- **MacBook**：还需要把 `AVCaptureSession` 也改成按需启停，或者接受空闲时常亮。`AVCaptureSession` 的启动延迟（通常 100 ms 以上）比 `AudioDeviceStart` 大，是否值得要单独评估。

---

## 八、备选方案：按需启停（未采用）

在确定 Output Only 之前，也评估过「空闲时停 IOProc、录音时再启动」。结论是：**技术上可行，但对现有链路的时序风险明显高于 Output Only，因此不推荐。**

### 8.1 当前链路时序

以 Chromecast 短按为例：

```text
物理语音键
  → BLE ATVV AUDIO_START
  → activateRemoteRoute()          ← 这里才 setRemoteActive(true)
  → beginOpening() → triggerTap()  ← 然后才合成 ⌘ 通知豆包
  → 豆包打开 vRemoteDr 2ch 开始读
```

对应代码：

- `X6SessionCoordinator.remoteAudioStarted()` 先 `activateRemoteRoute()`
- `beginOpening()` 再 `triggerTap()`
- `activateRemoteRoute()` 调用 `AudioPipe.setRemoteActive(true)`

所以「路由打开」一定早于「豆包开始读」。如果在这个点启动 IOProc，顺序上是安全的。

### 8.2 关键：只能绑 route，不能绑 transport

| 场景 | route 是否保持 ON | 说明 |
|---|---|---|
| 短按第一次 | 是 | ATVV 流结束后会重开持久流，route 不关 |
| 长按 | 是 | 松手才关闭 |
| 豆包被外部打开 | 是 | `adoptExternalActivation()` 会激活 route |
| MIC_OPEN 重试 | 是 | route 已开，只是等遥控器流 |
| 关闭验证失败、豆包仍在录 | 是 | 1.2 秒后恢复 route |
| 豆包真正关闭 | 否 | 这时才 `setRemoteActive(false)` |

如果把停 IOProc 绑在「遥控器音频流结束」上，Chromecast 短按第一次结束、持久流还没重开时会出现 100ms 级静音，直接回退 1.1.1 修过的问题。

### 8.3 如果按 route 启停，链路不会断的原因

- route ON 发生在 trigger 之前，IOProc 有机会先就绪；
- 第一包 BLE 音频已经进入 `pendingRemote`，不会因为晚启动几毫秒就丢失；
- route OFF 时 `mixActive` 已经是 false，`feed()` 不再收数据，`render()` 本来就在输出静音；
- 虚拟设备始终注册，豆包的选择不变。

### 8.4 但需要一起改 6 个地方

1. **设备状态解耦**：`outputDeviceID` 现在被 `stop()` 清空，`driverAvailable` 依赖它；要拆成「设备已解析」和「IOProc 正在跑」。
2. **只按 route 停**：不能按 transport 停，否则短按持久流会断。
3. **锁外启停**：`render()` 在 HAL 线程拿 `stateLock`；持有 `stateLock` 调 `AudioDeviceStart/Stop` 可能死锁。
4. **快速连按**：加 0.2–0.5 秒延迟或状态机，避免 start/stop 抖动和爆音。
5. **设备重载**：`coreaudiod` 重启或驱动重载后要重新解析设备 ID。
6. **MacBook 内置麦**：`AVCaptureSession` 也要按需启停，否则指示灯还是亮；但它的启动延迟通常 100ms 以上。

### 8.5 风险表

| 风险 | 严重度 | 说明 |
|---|---|---|
| 绑错 transport | 高 | 短按持久流静音，回退 1.1.1 |
| `driverAvailable` 误判 | 中高 | 控制台显示驱动不可用 |
| 锁内启停死锁 | 中高 | 偶发卡死，难复现 |
| 冷启动首帧损失 | 中 | `AudioDeviceStart` 几 ms–几十 ms |
| 首帧爆音/咔哒 | 中 | 从无写入切到有写入 |
| MacBook 内置麦仍亮 | 中 | 需要另一条改动 |
| 频繁 start/stop 稳定性 | 低中 | 需要压测 |

### 8.6 1.1.1 回归风险

git 历史里 `AudioPipe.swift` 从 1.0 之后没改过，1.1.1 的修复主要在会话状态机。所以按需启停不会直接改掉 1.1.1 的代码，但 Chromecast 短按依赖「route 在持久流重开期间保持 ON」，这个时序必须原样保留。

### 8.7 结论

按需启停可以做，但它是「动链路时序」的方案；Output Only 只动 IOProc 的流使用标记，不动时序。两者收益相同，优先选后者。

### 8.8 方案对比

| 方案 | 代码改动 | 链路风险 | 启动延迟 | 结论 |
|---|---|---|---|---|
| 按需启停 | 中 | 中高 | +几 ms | 不推荐 |
| Output-only AudioUnit | 大 | 中 | 无 | 备选 |
| IOProc stream usage | 小 | 低 | 无 | **推荐** |

### 8.9 当前决定

**2026-11-04：暂不实施，先记录。** 当前版本继续保留常驻 IOProc 和橙色指示灯常亮的行为；等有整块时间再做。届时按第九节的 stream usage 方案修改，不要临时改成按需启停。

---

## 九、推荐实现

### 9.1 改动点

只改 `AudioPipe.startOutputDevice`：在 `AudioDeviceCreateIOProcIDWithBlock` 成功之后、`AudioDeviceStart` 之前，关闭该 IOProc 的输入流。

```swift
private func startOutputDevice(_ deviceID: AudioDeviceID) {
    var ioProcID: AudioDeviceIOProcID?
    let createStatus = AudioDeviceCreateIOProcIDWithBlock(
        &ioProcID,
        deviceID,
        nil
    ) { [weak self] _, _, _, outputData, _ in
        self?.render(outputData)
    }
    guard createStatus == noErr, let ioProcID else {
        print("[AUDIO] ⚠️ 创建 vRemote IOProc 失败: OSStatus=\(createStatus)")
        return
    }

    // 关键：只输出，不占用输入流。
    disableInputForIOProc(deviceID: deviceID, ioProcID: ioProcID)

    let startStatus = AudioDeviceStart(deviceID, ioProcID)
    guard startStatus == noErr else {
        AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        print("[AUDIO] ⚠️ 启动 vRemote IOProc 失败: OSStatus=\(startStatus)")
        return
    }

    outputDeviceID = deviceID
    outputIOProcID = ioProcID
    print("[AUDIO] vRemote IOProc 已启动: id=\(deviceID), 48000 Hz stereo")
}
```

关闭输入流的辅助函数：

```swift
private func disableInputForIOProc(
    deviceID: AudioDeviceID,
    ioProcID: AudioDeviceIOProcID
) {
    var streamAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var streamSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        deviceID, &streamAddress, 0, nil, &streamSize
    ) == noErr else { return }

    let streamCount = Int(streamSize) / MemoryLayout<AudioStreamID>.size
    guard streamCount > 0 else { return }

    let usageSize = MemoryLayout<AudioHardwareIOProcStreamUsage>.size
        + (streamCount - 1) * MemoryLayout<UInt32>.size
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: usageSize,
        alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
    )
    defer { raw.deallocate() }

    let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
    usage.pointee.mIOProc = unsafeBitCast(
        ioProcID,
        to: UnsafeMutableRawPointer.self
    )
    usage.pointee.mNumberStreams = UInt32(streamCount)
    let flags = raw
        .advanced(by: MemoryLayout<AudioHardwareIOProcStreamUsage>.size)
        .assumingMemoryBound(to: UInt32.self)
    for index in 0..<streamCount {
        flags[index] = 0
    }

    var property = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyIOProcStreamUsage,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var qualifier = ioProcID
    let status = AudioObjectSetPropertyData(
        deviceID,
        &property,
        UInt32(MemoryLayout<AudioDeviceIOProcID>.size),
        &qualifier,
        UInt32(usageSize),
        raw
    )
    print(
        "[AUDIO] IOProc 输入流已禁用: status=\(status), " +
        "streams=\(streamCount)"
    )
}
```

### 9.2 实现注意

1. **必须在 `AudioDeviceStart` 之前设置。**
   实测先设置再启动有效；启动后也可以设置，但没有必要。
2. **失败不要阻断启动。**
   如果 `AudioObjectSetPropertyData` 返回非 0，只打日志，继续原来的行为（指示灯常亮），不能影响语音。
3. **qualifier 必须是 IOProcID。**
   `kAudioDevicePropertyIOProcStreamUsage` 是按 IOProc 生效的；qualifier 传错会写入失败或影响别的 IOProc。
4. **`mNumberStreams` 要覆盖全部输入流。**
   不能只传 0；要按设备输入流数量分配数组并全部置 0。
5. **不改变 `setRemoteActive` / `stop` / 会话状态机。**
   这是本方案最大的优势，不会碰 1.1.1 已经修好的时序。
6. **设备没有输入流时直接返回。**
   避免对没有输入方向的设备做无意义设置。

---

## 十、边界与风险

| 项目 | 说明 |
|---|---|
| 系统版本 | 实测仅 macOS 27.0（26A428）。`kAudioDevicePropertyIOProcStreamUsage` 和 `AudioHardwareIOProcStreamUsage` 是长期存在的 CoreAudio API，macOS 12+ 应该都可用，但未逐版本验证。 |
| 驱动 | 实测 `vRemoteDr 2ch`（BlackHole 衍生）正常。其他虚拟声卡理论上同样适用。 |
| 输入缓冲区 | 关闭后输入缓冲区 `mData` 为 `NULL`。当前代码忽略输入，安全；未来若读取输入需要回退。 |
| 豆包 | 不受影响。它仍然可以打开 `vRemoteDr 2ch`；录音时它自己的 `isRunningInput=1`，指示灯正常亮。 |
| MacBook 内置麦 | 本方案不解决 `AVCaptureSession` 的常驻输入，需要单独处理或接受。 |
| 指示灯判定 | Apple 没有公开文档直接写「橙色灯 = IsRunningInput」，但进程级 `IsRunningInput` 是 CoreAudio 公开的「活动输入流」状态，也是社区检测麦克风占用的权威信号。本次已用独立探针确认系统圆点会熄灭；实际 App 构建后再确认一次。 |
| 未来系统变化 | 如果未来 macOS 改变 stream usage 语义，备选是 HALOutput output-only（本报告已验证在 27.0 可用）。 |
| 回退 | 如果设置失败或出现任何音频异常，删掉 `disableInputForIOProc` 调用即可回到当前行为。 |

---

## 十一、验证清单

实现后按这个顺序验证：

1. **空闲状态**
   - 启动 vRemoter，不按遥控器。
   - 用本报告附件的探针确认 `vRemote isRunningInput=0`。
   - 菜单栏橙色麦克风图标应熄灭。

2. **正常录音**
   - 短按遥控器，豆包弹出。
   - 确认 `[IME-STATE] target=doubao state=active devices=vRemoteDr 2ch`。
   - 确认豆包进程 `isRunningInput=1`，指示灯亮。
   - 说一句话，确认首个字没有被截掉，`AUDIO_SUMMARY` 的 `db` 在 -25 ~ -45 之间。

3. **交互场景**
   - 短按第一次 / 第二次。
   - 长按说话、松手关闭。
   - 豆包打开超时（1 秒内没有 active）。
   - 快速连按两次。
   - 遥控器断连重连。
   - `coreaudiod` 重启后重新插拔/重启 App。

4. **麦克风选择**
   - 豆包固定选 `vRemoteDr 2ch`，不要用自动检测。
   - 确认没有回授、没有爆音。

5. **MacBook（如有）**
   - 观察空闲时是否仍因内置麦采集而亮灯。
   - 如果亮，评估是否要把 `AVCaptureSession` 也按需启停。

---

## 十二、参考

- Apple CoreAudio 头文件 `AudioHardware.h`：
  - `AudioHardwareIOProcStreamUsage`（约 849–867 行）
  - `kAudioDevicePropertyIOProcStreamUsage`（约 971–979 行）
  - `kAudioProcessPropertyIsRunningInput`（约 1962–1966 行）
- Apple Developer Documentation:
  - `AudioHardwareProcess.isRunningInput`
  - `kAudioProcessPropertyIsRunningInput`
  - `kAudioDevicePropertyIOProcStreamUsage`
- Stack Overflow: "How to exclude input or output channels from an aggregate CoreAudio device?"（`kAudioDevicePropertyIOProcStreamUsage` 的实际使用经验）
- Mac Note Taker: "How macOS tells you exactly which app is using the microphone (CoreAudio process objects)"（进程级麦克风状态检测）

---

## 附：进程状态探针（核心代码）

```swift
func processObject(for pid: pid_t) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var pid = pid
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<pid_t>.size),
        &pid,
        &size,
        &object
    )
    return status == noErr && object != kAudioObjectUnknown ? object : nil
}

func isRunningInput(pid: pid_t) -> UInt32 {
    guard let process = processObject(for: pid) else { return 0 }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<UInt32>.size)
    var value: UInt32 = 0
    let status = AudioObjectGetPropertyData(
        process, &address, 0, nil, &size, &value
    )
    return status == noErr ? value : 0
}
```

用这个探针可以在不重启 App 的情况下，确认优化前后 vRemoter 的 `isRunningInput` 是否真的从 1 变成 0。
