# LHY-02 独立执行 Prompt：录音豆 SDK 适配准备

请接手 Fitcore 的 LHY-02，只做本任务必要的本地工程工作，完成后交付可在另一台 Mac 独立打开的完整 ZIP。不要同时启动其他任务修改同一工程。

## 先读与工作边界

在解压根目录依次阅读 `README.md`、`handoff/CURRENT_STATUS.md`、`handoff/KNOWN_API_GAPS.md`、`reference/task-package/tasks/LHY-02.md`、`reference/api/WAV_HTTP_API_2026-10-15.md`，再读 `reference/task-package/docs/02_IOS_API_AND_MODULES.md`、`docs/LHY-01-LOCAL-HANDOFF.md` 及现有硬件接入文档。旧 `docs/lhy-13tasks-status-2026-10-15.md` 只作历史基线；冲突以当前交接状态和源码为准。

先说明理解、最小改动、当前目录与版本；若有 Git 元数据，只读确认仓库/分支，沿用当前分支；没有则如实说明。不要初始化 Git、恢复旧提交覆盖当前源码、拉取、推送、创建 PR、操作 AWS 或调用公网/付费服务。新授权到来前只做本地 fixture。保留今日、历史、AI 分析、我的四页布局和现有 Mock。

## 已有与目标

- 基线为 0.3.1 (8)。LHY-01 已实现「我的→设置→手机 WAV 采集」，输出 `UUID.wav` 与 `UUID.metadata.json`，停止后等待完成回调，格式为 16kHz/mono/PCM16 RIFF WAV、≤7,000,000 字节；不要重写这条链路。
- 物理 iPhone 尚未验收，真人语料为 0；目前没有 soundcore 录音豆和充电盒。iPhone 麦克风或模拟器结果不能算录音豆验收。
- 目标是隔离 SoundcoreInputAdapter 的厂商回调、状态和真实编码转换边界，复用已有文件校验和上层输入约定。没有硬件时可验收适配准备，不能宣称硬件闭环完成。

## 最小实施

1. 先检查 `ios/Fitcore/Services/Recorder/`、`Services/Training/TrainingSessionConnection.swift`、`Core/Audio/` 及当前工程配置。用现有边界接入，避免另造录音系统或改四页架构。
2. 当前 ZIP 不含厂商 SDK。历史资料指出两套静态 XCFramework 为 `SoundcoreWorkAppleSDK`、`module_spplinkKit`；必须另行取得用户授权与合法 SDK 文件后才迁移。未提供前不要下载、复制其他目录的 SDK 或假造 SDK API，可完成独立协议、明确未接入态和本地模拟适配器。
3. 建立与现有状态协调的连接、开始、接收、停止等待尾包、完成、断线/失败/取消过程；重复停止与迟到回调不能产生重复文件或训练事实。记录音频顺序、来源、设备时间及合并策略，区分设备录音停止、尾包收齐、云端 Job 完成三种状态。
4. 历史资料中的输出是约 20ms 的裸 Opus 包，绝不是 WAV。确认采样率、声道、帧边界、解码器与重采样策略后才能形成 PCM16 WAV；禁止仅改扩展名或加 WAV 头冒充解码。解码依赖未获授权或资料不足时，保留阻断与接口，不输出假有效音频。
5. 顶层 pause/resume 有前置条件；低层出现 `startRecord` 符号不证明 D3200 支持新建录音，也不证明 stop/终结/尾包语义。把这几个问题列入厂商确认清单；不能从符号自行承诺支持。
6. 模拟输入显式 `isSimulated`/Mock，来源与 iPhone 分开。只有成功完成并通过现有 WAV 校验的真实文件才能交给上层；失去设备、取消或未收齐尾包不得自动完成训练组。

## 验证与真实阻断

用本地模拟回调验证连接失败、开始失败、正常停止等待尾包、断线、乱序/重复/迟到回调及取消；如果没有解码器，只验证协议与状态，明确没有验证 Opus→WAV。跑受影响的离线测试、`python3 -B scripts/verify.py` 和可用的 `Fitcore-Mock` 模拟器构建，记录命令与真实结果。保留 LHY-01 测试通过证据；未运行的检查说明原因。

硬件、盒子、厂商鉴权/授权、真实 SDK、D3200 录音与 stop 支持、原始包/尾包时序、物理 iPhone 均是真实阻断。后端已部署，但 HTTP Token 不等于模型 Key；本任务不联调云端。默认服务端来源不可信，禁止伪造 `VERIFIED_USER` 或声纹结果。

## 独立 ZIP 交付条件

交付完整当前源码、Xcode 工程、资源、离线 fixture/测试、运行说明及 LHY-02 状态/阻断/验收清单；没有 SDK 时 ZIP 应能在 Mock 路径打开构建，明确真实 SDK 未链接。若后续获得授权引入 SDK，记录许可和可分发边界，不默认放进转交 ZIP。排除 `.git`、构建缓存、个人签名、`Local.xcconfig`、Token、模型 Key、私人 WAV 与数据库。提供 SHA-256、文件清单、实际检查记录；不伪造 Commit/PR、硬件视频或验收。后续主线优先 LHY-03→LHY-04→LHY-08；合并其他任务时只选择相关差异，不整包覆盖更新工程。
