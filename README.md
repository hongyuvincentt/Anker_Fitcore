# Fitcore 换电脑交接包 · 2026-10-16

这是最新的 **iOS 客户端与数据任务源码交接包**，版本 **0.3.1 (8)**。解压后整个文件夹就是工作目录；不是上传到 AWS 的部署 ZIP，也不是可直接安装到 iPhone 的安装包。

LHY-01 手机 WAV 采集代码和 D01 本地采集工具已实现并有离线验证证据。**物理 iPhone 录音尚未验收，真人样本为 0 段；其余 11 项并未完成。** 不要用原任务 Excel 的历史状态覆盖当前状态。

## 先做这三步

1. 将 ZIP 复制到另一台 **Mac**，解压并保留整个目录结构。Windows 可以阅读、编辑代码和资料；D01 当前在 macOS 验证，原生 Windows 直接运行未验证，可使用具备时区数据及 POSIX 私密权限的 WSL/Linux 环境。iOS 编译、签名和安装仍需要 Mac + Xcode。
2. 在新电脑的 Codex 中打开解压后的根目录，发送 [首次接手 Prompt](handoff/FIRST_RUN_PROMPT.md)。先核对环境和回归，再继续开发。
3. 按 [新 Mac 操作说明](handoff/NEW_MAC_SETUP.md) 打开 `ios/Fitcore.xcodeproj`，接上 iPhone，完成已有 LHY-01 的实际录音、播放、导出验收。

**建议顺序：** LHY-01 真机验收与 D01 首批采样 → LHY-03 HTTP 客户端 → LHY-04 页面联调 → LHY-08 整体集成。取得实际音频后并行开展 D02，JZD 负责第二人工复核。LHY-02 可准备适配，但真实设备验收等待录音豆、充电盒和授权 SDK；其余任务按依赖推进。D04 留出规则应在 D03 数据扩充和算法调参前确定。

## 目录

- `ios/`：可用 Xcode 打开的当前 App，保留已有四页布局、人物肌肉展示与 Mock。
- `Package.swift`、`tests/`：WAV 组件的 Swift 测试。
- `data/D01/`：离线采集工具、空模板、测试和采样说明。
- `scripts/`：本地回归、工程生成及 LHY-01/D01 独立交付打包工具。
- `docs/LHY-01-LOCAL-HANDOFF.md`、`docs/LHY-01-VERIFICATION.json`：已有实现说明与上一轮软件验证证据。
- `handoff/CURRENT_STATUS.md`：13 项当前状态、已知依赖和交付边界。
- `handoff/KNOWN_API_GAPS.md`：当前后端合同与旧客户端的差异。
- `handoff/prompts/`：其余 11 项的独立执行 Prompt；[索引](handoff/PROMPTS.md)，[完整可复制合集](handoff/REMAINING_TASK_PROMPTS.md)。每次选一项，不要让多个任务同时改同一份工程。
- `reference/task-package/`：2026-10-15 原始任务卡、Excel、空模板和历史清单。只作需求依据，历史进度和 Git 流程不覆盖当前用户指令。
- `reference/api/`：已提供的四份 API 材料，版本优先级见 `KNOWN_API_GAPS.md`。
- `HANDOFF_MANIFEST.json`、`SHA256SUMS`：本包范围和各文件完整性记录。

本包不含 `.git`、模型 Key、HTTP Token、个人签名、SDK 二进制、真人音频、实际授权登记、训练数据库或构建缓存。新电脑先使用 Mock 和离线测试；云端联调另行私密配置 HTTP 测试 Token，不能把服务器模型 Key 填入 App。

当前约定是**本地推进、分别交付各子任务 ZIP**。不要自动推送 Git、修改 AWS、重建后端或调用付费模型。今后若获准用 Git，先核实本地与远程状态，保留当前快照，不恢复旧提交覆盖这些文件。
