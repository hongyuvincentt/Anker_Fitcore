# 01 · 项目现状和交接边界

## 权威版本与验收分界
- AWS 部署的冻结业务版本：`3a5cbbe`；API 基础地址（当前临时）：`https://54-254-212-127.sslip.io`。公网 IP 改变会导致该 `sslip.io` 地址失效，客户端必须支持更换 base URL。
- Ubuntu EC2 + Caddy HTTPS + `fitcore.service` + SQLite 持久化已部署。受控单人测试中，真人 WAV 经过 ASR/Nova/Fact Engine 后正确提交卧推 60 kg × 8 次，Review 1组/8次/480kg·次。
- 上述 COMMIT 采用 `server_authorized_test` 服务端授权测试模式。演后 `AUDIO_TEST_SOURCE_TRUSTED=false` 已恢复。**不是声纹识别；不是面向所有用户的可信来源能力**。
- 默认正常公网 WAV 上传属于未验证来源，可能被 `SOURCE_UNCERTAIN` 拦截；人工 `confirm_set` 在未验证来源下亦可能返回 `409 SOURCE_NOT_VERIFIED`。不得由客户端伪造 VERIFIED_USER。
- 算法实验版 R1 `001061e`、Round7 `6e3faab` 只属于开发候选，没有证据显示已替换 AWS 稳定版。LHY 对接固定 API 合同，不自行切换实验服务。

## 这次交给 LHY 的范围
- 8项原 iOS 任务：WAVCaptureKit、SoundcoreInputAdapter、BackendHTTPClient、TrainingSessionUI、CorpusCollector、SpeakerEnrollmentUI、AIInsightsUI、完整 iOS App 集成。
- 5项数据任务：D01 真人 WAV 扩展采集、D02 人工标注、D03 语义语料库、D04 held-out、D05 量化评测；全部由 LHY 作为 **执行负责人/交付责任人**。
- LHY 在 Mac 上实现、跑 Xcode/真机，使用独立私有 Git 分支和 PR 提供源码/测试证据。

## 没有交给 LHY 的权限或职责
- 不托管 AWS 主机、systemd、SQLite 生产数据与模型密钥；AWS 操作由你与 Codex 批准执行。
- 不修改 `3a5cbbe` 冻结标签，不自动合并 TRAE 算法分支，不绕过 Fact Engine。
- 不将声纹、原始 WAV、Bearer Token、`.pem`、生产数据库提交到代码仓库。
- 独立数据标注的 **审核/金标冻结** 与正式产品的安全策略批准仍归你、Codex（必要时 TRAE交叉复核），执行责任交给LHY不等于他可单人改金标。

## 必须另外向 LHY 提供的材料
1. 经脱敏 API 交接 ZIP `Fitcore_Step2_LHY_API_Handoff_2026-10-15.zip`（你本地已有；本包未重复附带实际原文件）。
2. 官网赛事 SDK、录音豆设备和开发权限；SDK 和硬件当前状态要由 LHY 复核。
3. iOS 私有 Git 仓库权限和审查人信息。
4. 如果测试真人音频：对每条样本确认授权的用途/范围/撤销方式；只走私密存储，不直接附给公开任务包。
5. 访问 AWS 测试 API 所需的临时受控凭据，通过私密、安全渠道另行分发，不能写入公开 iOS 二进制包。
