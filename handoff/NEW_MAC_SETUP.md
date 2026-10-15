# 新 Mac：从打开工程到第一段真机 WAV

## “打开工程，连接 iPhone”是什么意思

开发代码在 Mac 上，最终 App 在 iPhone 上运行。Xcode 负责将源码编译成 App，再利用你自己的开发签名安装到连接的手机；数据线只是连接方式，不会自动安装 ZIP。

1. 在 Mac 解压本交接 ZIP。进入解压目录的 `ios` 文件夹，双击 **`Fitcore.xcodeproj`**。打开的是 Xcode 工程，不是 `Package.swift`；后者用于组件测试。
2. 用数据线连接 Mac 与 iPhone，解锁手机。手机若询问“信任此电脑”，由你确认。Xcode 顶部运行目标选择自己的 iPhone，而不是模拟器或 “Any iOS Device”。首次连接可能需要等待配对及设备支持准备。
3. 顶部 Scheme 选择 **`Fitcore-Mock`**。它保留训练演示数据，同时包含真实的“手机 WAV 采集”入口；选这个 Scheme 仍然可以在物理手机上真实录音。
4. 若 Xcode 提示签名缺失，在项目导航选择 Fitcore → TARGETS 的 Fitcore → Signing & Capabilities，选择自己的 Team。必要时先在 Xcode 设置的 Accounts 登录自己的 Apple Account，并将 Bundle Identifier 改成自己可用的唯一值。签名信息只留在自己电脑，不要求另一台电脑沿用原来的 Team。
5. 如果设备提示启用 Developer Mode（开发者模式），按手机和 Xcode 的提示在手机设置中开启并完成所需重启。密码、Apple Account 登录和确认由你在设备上操作。
6. 按 **Command + R** 或 Xcode 左上角 ▶。这一步是“编译、安装并启动”。**Command + B** 只编译，不能证明 App 已安装、麦克风可用或录音合格。

现有 App 最低 iOS 17。新 Mac 应安装支持所连 iPhone 当前系统版本的完整 Xcode，并完成首次启动组件安装。旧电脑验证环境见 `docs/LHY-01-VERIFICATION.json`；不要求新电脑照抄旧电脑的个人路径或签名。

`ios/Configuration/Local.xcconfig.example` 是可选配置示例。若复制成 `Local.xcconfig`，它只属于本机，不能重新打包或提交。先保持 recorder/analysis 为 `mock`；运行本地录音不需要服务器 URL、HTTP Token 或模型 Key。不要因为有 AWS 地址就切换旧文字接口到 backend，当前完整 WAV 客户端仍属 LHY-03。

## 在手机上做第一条验收

1. 打开 App 的「我的」→右上角设置→「手机 WAV 采集」。
2. 阅读本地保存说明，勾选本机录音同意，点击开始；首次由你允许系统麦克风权限。
3. 自然说「卧推六十公斤八次」，点击「停止并校验」，等待完成，播放回听首尾。
4. 点击「导出 WAV 与信息」，手动保存到自己批准的私密位置。必须同时保留 `UUID.wav` 与 `UUID.metadata.json`。不要发送到公共仓库或未批准的群聊。
5. 再录一段，确认原文件仍在；测试取消、拒绝权限及中断场景。按 `docs/LHY-01-LOCAL-HANDOFF.md` 的验收清单逐项记录实际结果。

合格文件应为 16kHz、单声道、PCM16 的完整 WAV，非空非静音，单段不超过 7,000,000 字节。新建录音的 UUID 与原始字节保持稳定，供之后 LHY-03 幂等上传使用。

这一轮只是**本机录制与导出**；尚没有“录完自动上传 AWS”的功能。真实上传及展示结果是 LHY-03/04 的下一阶段。不要把模拟器音频或本地成功提示当成物理 iPhone、云端 ASR 或正式记账验收。

若计入 D01，录音前按 `data/D01/README.md` 完成真实用途授权登记。录音页面的本机同意不能替代团队共享或云处理许可。首批先做少量样本，JZD 回听复核，随后再扩展。

## 交给新电脑 Codex 的离线检查

在终端先 `cd` 到解压后的根目录。可以在终端输入 `cd `（末尾有空格），再从 Finder 将解压后的文件夹拖进终端，最后按回车；无需沿用原 Mac 的用户名路径。

```sh
xcodebuild -version
python3 --version
swift test --scratch-path /private/tmp/fitcore-handoff-swift-tests
python3 -B scripts/verify.py
python3 -B -m unittest discover -s data/D01/tests -p 'test_*.py'
python3 -B -m unittest discover -s scripts -p 'test_package_lhy_tasks.py'
xcodebuild -quiet -project ios/Fitcore.xcodeproj -scheme Fitcore-Mock \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/fitcore-handoff-simulator CODE_SIGNING_ALLOWED=NO build
```

Python 3.9+、系统 `Asia/Shanghai` 时区数据及 POSIX 文件权限即可运行 D01，不需要安装 Python 第三方包。当前已验证环境是 macOS；原生 Windows 常缺少 IANA 时区数据，且工具的 0700/0600 权限约束不能直接等同于 Windows ACL，原生 Windows 未验证。若用 Windows，先阅读/编辑资料，实际采集管理建议在 Mac 或具备时区数据的 WSL/Linux 中运行，私密数据放在该 Linux 文件系统内；不要仅为通过检查移除权限保护。

Swift 与 Xcode 检查必须在 Mac 上进行。将构建缓存放在 `/private/tmp`，避免 Desktop/Finder 扩展属性影响 Swift 测试 bundle 签名。

如果 Xcode 尚未装好，先完成环境安装；如果没有物理 iPhone，继续离线代码工作，真机项保持未验收。不要为了消除状态提示伪造验收记录。

## 需要单独迁移的东西

- HTTP 测试 Token：后端负责人通过私密方式提供；只在本机安全配置，不能写进源码、Prompt 或 ZIP。
- 模型 Key：保留在已部署后端；本地 iPhone 主链开发不需要拿到它。
- soundcore SDK 与鉴权材料：经授权单独迁移；本包不含 SDK。设备和充电盒到手后才能完成真实连接验收。
- 真实 WAV、授权证据、身份映射与金标：只按实际授权和访问范围迁移，默认不随源码包传输。
- Apple 签名：新电脑自行设置自己的 Team，不迁移个人证书来冒充已完成配置。

私有 iOS 仓库的已提供地址是 `https://github.com/Dnlock/fitcore-ios.git`。本包不含 Git 历史，也不声称已推送；当前先做本地工作。以后启用 Git 时先检查远程，避免覆盖当前最新快照；coordination 仓库地址仍待提供。
