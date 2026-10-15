# 04 · Mac/Windows/Git 的交接与提交流程

## 分支与仓库
- LHY 在私有 `fitcore-ios` 仓库单独实现 iOS 8个模块；数据清单与标注放在受限 `fitcore-coordination` 中，仅可追溯 metadata（不提交原始 WAV）。
- 仓库当前是否已建好、邀请是否生效、Mac 与 Windows 的 remote/权限是否一致，必须以实际 Git 检查为准，不能根据历史口头记录宣称完成。
- 每个任务一个工作分支：例如 `feat/lhy-01-wav-capture`、`feat/d01-consent-wav-manifest`；避免在 main 直接推送半成品。
- 代码按 `task_id → commit → PR → tests → review → merge` 交付。Codex 在 Windows 优先 fetch 并审查，再决定 merge；不得覆盖未提交工作。

## 提交包清单
每条 PR 必须说明：任务ID、真实变更、平台/设备、编译命令与结果、Mock/真机区别、错误案例、阻断、下一步、截图或脱敏日志、依赖API合同版本。

## 禁止提交
`.env`、`*.pem`、API Key、长效 Bearer Token、真实设备秘密、AWS配置密钥、SQLite生产库、原始授权WAV/声纹模板、参与者真实身份；提交前检查 `git diff --cached` 和仓库忽略规则。

## 如何更新进度
LHY 更新 `templates/STATUS_UPDATE.csv` 后提交 PR；你/Codex 核对再更新**唯一数据源** `fitcore-coordination/tracker/tasks.csv`；本包的 `tracker/LHY_TASKS_FOR_IMPORT.csv` 是快照切片，不可直接覆盖总表。

## 双算法协作
Codex 负责算法安全、确定性 Fact Engine、版本集成与后端合同；TRAE 负责多轮语义、ASR歧义及新AI功能。LHY 可以提数据/场景反馈但**不在 iOS 侧自行实现权威训练事实逻辑**。
