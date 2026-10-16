# Fitcore iOS / LHY 源码交接（基于用户 2026-10-17 上传的 zip）

本包的 `fitcore-ios/` 是用户上传的现有项目源代码的**安全过滤副本**，保留已有代码、测试、Package.swift、Xcode 项目配置；没有重做 App。排除了 `.git`、`.build`、`__MACOSX`、macOS 附带元数据、Local.xcconfig 和可能包含秘密的文件。请不要将此副本直接覆盖 LHY 的 Mac 工作树。

## 本轮候选变更
- `ios/Fitcore/Services/Soundcore/SoundcoreRecorderGateway.swift`：Phase 1 连接成功后不自动开始 Phase 2 实时音频探测（需要另外显式授权和验证）。
- `disconnect()` 向真实 SDK 请求断开，**不立即**将 UI 状态声明为 disconnected；收到 SDK `disconnected` 回调后清空连接状态和通知 UI。
- 保留现有扫描筛选、10 秒超时、重试、link 保存和音频探测代码。

## 验证状态
- 本地 Linux `swift test --scratch-path`：149 tests, 0 failures，exit 0。
- **上述测试不覆盖 iOS App target / 私有 Soundcore SDK Gateway**。本轮 iOS 编译、Xcode Build、SDK Auth、真机断连/重连、真实音频、IPA 审计均 NOT_RUN。
- 本包没有真实 QA token、license、音频或私有 SDK binary。运行时凭据生产接线与完整 iPhone → HTTP → Review 验收仍需 Launch / LHY 配合。

## LHY 的操作
1. 先 `git status --short`、备份未提交修改和本地重要资源，核对当前文件和该 ZIP 中的版本。
2. 在独立 worktree 使用 `GATEWAY_CHANGES.patch` 比对；不要盲目覆盖包含更新修复的文件。
3. 先检查 SDK `onDisconnected` 是否可靠、失败回调是否触发；如需要断开超时，应加入明确 `disconnectFailed` 状态，不得伪造成功。
4. Mac 编译 Xcode App target；运行 Swift 全量测试；在真实设备上执行三轮 connect/disconnect/reconnect 并保存脱敏 SDK 回调。
5. 依照已有仓库 `scripts/` 验证 IPA Secret，再由负责人评审 PR。不要提交私有 framework、凭据、原始录音。

## 核心限制
这是一份**完整开源可共享部分的项目源代码 + 定点候选修复**，不是包含私有 SDK 的可签名 IPA；完整硬件能力仍需要 LHY 的授权 SDK、真机和 QA 环境。本轮未修改 `main` 或远端 GitHub。
