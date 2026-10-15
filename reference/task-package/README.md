# Fitcore · LHY 独立开发与语料评测交接包

**版本：** 2026-10-15 / 任务移交版 1.0  
**交接对象：** LHY（Mac / iOS / Soundcore SDK / D01–D05 全部五项语料与评测）  
**内容：** 8 项 iOS 任务 `LHY-01…08` + 5 项数据任务 `D01…05`，共 **13项**。

## 先从这里开始

1. 打开 `Fitcore_LHY_13Tasks_2026-10-15.xlsx` 查看总表；原优先级与编号保留，但 **D01–D05 的执行负责人全部调整为 LHY**。
2. 阅读 `docs/01_PROJECT_HANDOFF.md`，了解已经部署的 AWS 能力、可信来源限制、LHY 的交付边界。
3. 阅读 `docs/02_IOS_API_AND_MODULES.md`，再实现 LHY-01→03→04 与 LHY-02 的真实设备适配。
4. 阅读 `docs/03_AUDIO_DATA_CONSENT_AND_ANNOTATION.md`，先建立授权/元数据，再开始 D01–D05 数据工作。
5. 根据 `tasks/` 13 个任务卡实施；每项交付 Commit / PR、测试/真机证据、`templates/STATUS_UPDATE.csv` 状态更新。
6. 最终将 `tracker/LHY_TASKS_FOR_IMPORT.csv` 作为**待 Codex 合并的任务切片**，不可覆盖主仓库 `tracker/tasks.csv`。

## 比赛前重点

P0：LHY-01、LHY-02、LHY-03、LHY-04、LHY-08、D01、D02。  
P1/P2 可以分阶段实现，不得以“大而全”推迟真机录音、API、训练展示与可复现演示。

## 请明确两点

- 这是 **需求与任务交接包，不是 iOS 工程源码、设备 SDK 或已授权 WAV 数据包**；本包没有任何密钥、Token、私钥、原始录音、声纹模板或用户身份资料。
- AWS 冻结业务 `3a5cbbe` 已经完成**受控单人来源授权**下的 ASR→Nova→Fact Engine 正式 COMMIT 验收，但 **iOS/soundcore 真机、公开 App 的身份来源闭环、安卓真机未验收**。不能宣传成已经全部完成。

## 文件索引

- `Fitcore_LHY_13Tasks_2026-10-15.xlsx`：任务看板、13项明细、交付门槛。
- `tracker/LHY_TASKS_FOR_IMPORT.csv`：仅属 LHY 的13项任务，Codex 用于安全导入。
- `tracker/OWNER_CHANGE_PATCH.csv`：D01–D05 所有权变更申请。
- `tasks/`：每项单独目标、产物、依赖、验收、风险。
- `docs/`：系统交接、iOS API、授权标注、Git、验收、交接问题。
- `templates/`：匿名录音索引、授权登记、标注、held-out切分、指标、状态更新等空模板。
- `checklists/RELEASE_ACCEPTANCE.csv`：最后的 iOS、数据质量及 Demo 验收门槛。
- `SHA256SUMS.txt`：交接包内各文件校验和。

**同步规则：** 任务主表只允许 `fitcore-coordination/tracker/tasks.csv` 做唯一写入源；当前 Excel 为交接快照，更新由 Codex 合并/再生成。LHY只提交切片状态，避免覆盖其他项目。
