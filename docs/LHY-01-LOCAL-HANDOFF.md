# LHY-01 手机 WAV 采集本地交付

版本：Fitcore 0.3.1 (8)。状态：录音组件、页面、格式校验和离线测试已实现；物理 iPhone 录音、导出文件和实际中断时序仍待使用者验收。这个 ZIP 不含真人声音、模型 Key、HTTP Token、个人签名或 SDK。

## 现在可以做什么

- 用 iPhone 内建麦克风录一段训练描述，停止后等待录音器完成回调，再检查文件。
- 标准为真实 RIFF/WAVE、经典整数 PCM16、小端、16kHz、单声道、非空、≤7,000,000 字节；本地额外筛查静音。
- 支持本机录音同意、系统麦克风许可、取消、重录、播放、单段删除与手动分享。每段有独立 UUID，录制新的一段不会覆盖之前的有效文件。
- 每次导出两份同名配对文件：`UUID.wav` 和 `UUID.metadata.json`。JSON 保存文件哈希、格式、时长、录制时间、音源、本机同意和模拟器标记；没有团队或云端处理许可。
- 本功能不调用服务器，不生成训练事实，也不接录音豆。原训练页面与 Mock 仍保留，后续 LHY-03 使用这里的原文件与稳定 `utterance_id` 接 HTTP。

## 你在 Mac 和 iPhone 上的操作

1. 解压 LHY-01 ZIP，打开 `ios/Fitcore.xcodeproj`，选择 `Fitcore-Mock` Scheme。
2. 连接并解锁 iPhone，在 Xcode 选择自己的签名 Team 和该 iPhone。个人配置可以使用 `ios/Configuration/Local.xcconfig.example` 创建本机 `Local.xcconfig`，不提交或重新打包个人配置。
3. 按 Command+R 安装运行。
4. 在 App 点击「我的」→右上角设置→「手机 WAV 采集」。
   如果这段录音将计入 D01，先按 D01 包说明登记实际授权，再开始采样；本机录音、团队复核和云处理的许可分别记录。
5. 阅读本机保存用途，打开「我同意录制并保存在本机」，点击「开始录音」，系统询问时由你允许麦克风。
6. 自然说一句「卧推六十公斤八次」，点击「停止并校验」。首批建议每段5–20秒；最长200秒自动结束，以免超过文件上限。
7. 在「已录制」中播放回听首尾。点击「导出 WAV 与信息」，通过系统分享选择你批准的本地保存位置或 AirDrop 接收人，两份文件都要保留。
8. 再录下一段。纠错/上下文句按真实顺序录制，D01 导入时填写相同的 session_id；不把单独一句省略表达当成完整独立真值。

如果麦克风被拒绝，页面会提示原因并提供「打开 iPhone 设置」。拒绝权限、中断、转到后台或取消的片段不会被列为有效样本。被中断/失败的原始片段仅保留在 App 私有目录用于定位，不进入有效导出列表；主动取消会移除当前未完成音频。重新启动 App 会重新校验已保存录音及其元数据后恢复列表。

文件保存在 App 私有 Application Support 中。卸载 App 可能使本机文件丢失，完成回听后请及时主动导出到自己的私密保存位置。导出可能包含可识别的人声；请选择已批准的接收人与位置。系统分享是用户操作，不会默认远程上传。

## 交给 D01 工具

在 D01 包中先登记真实的按用途授权，不能仅凭 `local_recording_consent=true` 推断团队或云许可。运行方式见 D01 包 README。

```sh
python3 -B data/D01/scripts/d01.py import \
  --root /PRIVATE_LOCATION/d01-collection \
  --wav /PRIVATE_INBOX/UUID.wav \
  --metadata /PRIVATE_INBOX/UUID.metadata.json \
  --consent-id CONSENT_ID --speaker-id SPEAKER_ALIAS \
  --session-id SESSION_ID --scene-id ordinary
```

以上为占位符路径和匿名编号，需替换为真实本机位置和登记编号。D01 先标 `needs_review`，不能因 sidecar 写有 iphone 就自动认定真人；JZD 根据实际授权和录音复核。模拟器导出 `is_simulated=true`，不能计入真人样本。

## 测试与独立运行

本包是可打开的 iOS 工程，并附 Foundation/Combine/CryptoKit 共享组件的 Swift 单元测试；没有第三方依赖。`swift test` 是 macOS 上的组件测试，不能代替 iPhone 音频验收。

在解压根目录执行：

```sh
swift test --scratch-path /private/tmp/fitcore-lhy01-unit-tests
python3 -B scripts/verify.py
xcodebuild -quiet -project ios/Fitcore.xcodeproj -scheme Fitcore-Mock \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/fitcore-lhy01-build CODE_SIGNING_ALLOWED=NO build
```

用临时目录存放构建结果，避免 Desktop/Finder 扩展属性导致本机测试 bundle 的签名检查失败。新增 Swift 文件后可运行 `python3 -B scripts/generate_xcode_project.py`；本交付的工程已更新，无需为了运行而重新生成。

`docs/LHY-01-VERIFICATION.json` 记录本轮实际软件检查与未验收项。WAV 测试使用临时合成数据；不会读取个人录音、启动麦克风或调用模型。

## 真机验收清单（尚未执行）

- [ ] 物理 iPhone 的首次许可、拒绝后恢复许可可用。
- [ ] 真人录音能停止、播放并导出 WAV/JSON，首尾完整。
- [ ] 原始格式、时长、大小、哈希与导出文件一致，D01 可导入。
- [ ] 取消与重录不覆盖之前的有效文件；重进页面与重启后仍能查看。
- [ ] 音频中断、进入后台、输入设备改变时不显示虚假成功。
- [ ] 私密保存、团队共享和云处理分别按真实授权执行。

这些项须实际完成后再记录设备/iOS版本、脱敏日志与视频。本交付不声称物理 iPhone、soundcore、AWS WAV 主链或 D01 的40段真人数据已验收。

实现参考：[Apple AVAudioRecorderDelegate](https://developer.apple.com/documentation/avfaudio/avaudiorecorderdelegate)、[record(forDuration:)](https://developer.apple.com/documentation/avfaudio/avaudiorecorder/record(forduration:))。本地静音筛查不是人声检测，也不证明声音身份。
