# 当前状态 · 2026-10-16

## 接手基线

- App：**0.3.1 (8)**，以本包文件为准。原任务包中 0.3.1 (7) 和“待核查”是历史快照。
- 责任范围：LHY-01～08 与 D01～D05，13 项；本轮只实现了 LHY-01 软件切片与 D01 离线工具。
- 用户有 iPhone，没有 soundcore 录音豆及充电盒；JZD 为第二人工标注复核人。
- 当前工作目录没有 `.git`；Git Commit/PR **未关联**。已提供私有 iOS 仓库 `https://github.com/Dnlock/fitcore-ios.git`，当前没有验证远程最新状态；coordination 仓库地址未提供。
- 最新用户要求：先本地处理，各子任务独立 ZIP。原交接卡里的默认分支、PR、推送安排不构成本轮自动执行授权。不要初始化/切换仓库、恢复旧提交覆盖当前文件，或擅自上传。

## 13 项实际进度

| 任务 | 当前可确认状态 | 下一步 / 依赖 |
| --- | --- | --- |
| LHY-01 | 录音控制、原生采集页、标准 WAV 校验、播放/分享和元数据已实现；30 项组件测试有通过证据 | 物理 iPhone 许可、录制/播放/导出、中断和 D01 导入仍待实际验收 |
| LHY-02 | SDK 尚未集成；设备/充电盒缺失；SDK 不在本包 | 另行获授权 SDK 和鉴权合同，可先做离线适配设计；真实 Opus/尾包/连接验收等设备 |
| LHY-03 | 旧网络客户端可复用部分基础；新完整 WAV 合同未实现 | 优先实现 Session→Audio Job→轮询→Facts/Pending/Events→Finish/Review |
| LHY-04 | 训练、复盘、历史等页面与 Mock 已有 | 保持布局，绑定 LHY-03 的服务端事实与处理/待确认状态 |
| LHY-05 | App 内采集管理未实现；D01 CLI 已可离线准备 | 复用现有录音和 D01 规则做按用途授权、索引与手动导出 |
| LHY-06 | 声纹注册/撤销未实现 | 依赖真实来源/声纹后端合同；不能用测试信任标志冒充声纹 |
| LHY-07 | 现有分析/问答 Mock 卡片可复用 | 真实问答/建议接口未交付；Review 统计不等于 AI 建议 |
| LHY-08 | 当前 Mock、录音软件已整合；曾通过模拟器及 unsigned iPhone SDK 编译 | 真实 WAV 云端链路、签名安装、iPhone 与 soundcore 实测仍缺 |
| D01 | 本地工具和空模板完成，25 项测试有通过证据；**真人 0 段、已核验说话者 0 人，待验收** | 先真实用途登记，再采本人小批次、导入/回听/来源复核；之后扩展约40段/3–5人 |
| D02 | 未标注；21 列空模板已提供；第二复核人 JZD 已指定 | 等 D01 已授权真人录音，人工回听、结构标注、争议处理与金标冻结 |
| D03 | 未建立实际100–150条语义集 | 按来源、语义场景、重复与留出约束扩展；不要编造真实样本 |
| D04 | 未建立独立冻结测试集 | 扩充与调参前先定说话者/会话/场景隔离，真实数据到位后复核冻结 |
| D05 | 未有可验证算法量化评测 | 等独立数据和金标；0样本不生成准确率，单样本成功不代表泛化 |

原始任务卡保留全部验收要求；“已完成软件工具”不等于任务整体已验收。

## 已有实现位置

- `ios/Fitcore/Core/Audio/`：WAVFileValidator、WAVCaptureController，共享组件测试位于 `tests/WAVCaptureKitTests/`。
- `ios/Fitcore/Services/Audio/IPhoneMicrophoneBackend.swift`：物理 iPhone 内建麦克风、权限、AVAudioRecorder 完成回调和音频中断处理。
- `ios/Fitcore/Features/Capture/WAVCaptureView.swift`：设置中的「手机 WAV 采集」。不改变原有训练页面布局。
- 输出一段 `UUID.wav` 配对 `UUID.metadata.json`；sidecar 的 `schema_version=1`，`utterance_id` 沿用稳定 UUID，格式与 hash 放在 `inspection` 内。每段独立保存，不覆盖前一段。
- `data/D01/scripts/d01.py`：init/import/validate/report/eligible/verify-human/withdraw；授权区分 local/team/cloud，导入不自动确认真人、不生成转写或金标。
- `scripts/package_lhy_tasks.py`：只打包 LHY-01/D01 的公开源文件白名单，不代表其他任务的打包器。

## 验证证据及限度

上一轮实际软件验证见 `docs/LHY-01-VERIFICATION.json`：Swift 30 项、D01 25 项、独立打包器11项测试通过；旧 Mock 核心/动态记录检查通过；模拟器编译与 unsigned iPhone SDK 编译通过。LHY-01/D01 独立 ZIP 曾在全新目录解压后重新测试/编译。

这些是**原 Mac 的软件证据**，不能替代新 Mac 的环境检查、物理手机安装/麦克风验收、真实 ASR/模型调用或人工作业。新电脑请按 `NEW_MAC_SETUP.md` 重跑适用检查并另记结果。

本次换电脑交接只整理文件、说明和 Prompt，不改变业务代码。根目录 manifest 记录源文件范围及哈希；包外校验回执记录本次 ZIP 的完整性与新解压目录检查。

## 后端与数据边界

后端负责人报告 AWS 已完成受控真人 WAV→ASR→Nova Pro→Fact Engine 验收；原材料记载冻结业务版本 `3a5cbbe`，临时地址 `https://54-254-212-127.sslip.io`。**本次未重新在线核验**，新电脑应先核对部署合同。这里不含后端源代码，不需要重新开发或部署一套旧后端。

公网默认未信任音源，`SOURCE_UNCERTAIN` Pending 以及 `409 SOURCE_NOT_VERIFIED` 可能是预期行为。客户端不能自行宣称 VERIFIED_USER/声纹成功。详见 `KNOWN_API_GAPS.md`。

本包没有任何真实参与者授权行、真实音频、金标、密钥、SDK 或个人签名。测试仅用临时合成 fixture；不得将它们算作 D01 真人成果。数据任务的真人操作需要用户和 JZD 实际参与，Codex 不能代签同意、代听不存在的音频或冒充人工复核。
