# LHY-05 独立执行 Prompt：授权语料采集与导出

请接手 Fitcore 的 LHY-05，复用已实现的手机WAV采集和D01工具，补齐最小、可追溯的本地授权/导出流程，完成后交付另一台Mac能独立使用的完整ZIP。只改本任务必要文件，不同时推进其他任务修改同一工程。

## 先读与工作边界

在解压根目录依次阅读 `README.md`、`handoff/CURRENT_STATUS.md`、`handoff/KNOWN_API_GAPS.md`、`reference/task-package/tasks/LHY-05.md`、`reference/api/WAV_HTTP_API_2026-10-15.md`，再读 `docs/LHY-01-LOCAL-HANDOFF.md`、`data/D01/README.md`、`reference/task-package/docs/03_AUDIO_DATA_CONSENT_AND_ANNOTATION.md` 和相关模板。旧 `docs/lhy-13tasks-status-2026-10-15.md` 是历史基线。

先说明理解、现有可复用部分、最小改动、当前目录与版本；有Git时只读确认仓库/分支并沿用，没有则说明。不要初始化Git、恢复旧提交覆盖源码、拉取/推送/创建PR、操作AWS或调用公网/付费服务。默认仅合成fixture和临时私密目录；不得自动开始录音或把“已批准开发”当成真人数据采集授权。保留四页布局、Mock与原采集入口。

## 已有与目标

- 基线0.3.1 (8)。LHY-01已有本机同意、麦克风权限、开始/停止等待完成、取消/重录/播放/单段删除/手动分享、重启校验恢复，输出 `UUID.wav` + `UUID.metadata.json`。标准16kHz/mono/PCM16、≤7,000,000字节。不要重写这些功能。
- D01的软件与本地测试已实现，真人样本仍为0；物理iPhone未验收，无录音豆/盒子。`data/D01/scripts/d01.py` 与新模板是入口，旧校验器字段不兼容新manifest，不得混用后宣称合格。
- 目标是补齐当前App与D01之间的授权、匿名身份关联、质量检查和撤销/导出可追溯性；不要扩成账号系统、云同步平台或全部D01–D05。

## 最小实施

1. 先列出已有D01命令、字段与App metadata可直接复用的部分。按差距新增局部界面或导出适配，优先复用D01导入/校验逻辑，不另创第二种不兼容manifest。
2. 分开记录本机录制/保存、团队共享/人工复核、云端处理及后续用途的同意、拒绝、撤销、时间、版本、到期与化名ID。LHY-01 `local_recording_consent=true` 仅代表本机许可，不能自动扩为团队或云许可。拒绝不影响其他非采集功能；撤销后阻止对应用途的新采集/导出/使用。
3. speaker_id、recording_id与consent_id建立最小关联；保留实际session顺序和scene。私人姓名、手机、声纹模板不进仓库或ZIP。真实身份映射如确需保留，只存用户指定的受控位置，不新增不必要身份字段。
4. 导出WAV/metadata与CSV manifest一一对应，使用新D01字段如 `speaker_id_pseudonym/private_storage_pointer/consent_id`，填实际哈希、格式、大小与状态；兼容字段以实际模板为准。拒绝丢失配对文件、哈希不一致、无有效授权、到期/撤销、模拟器冒充真人等情况。
5. 导入后先为needs_review；本地校验或sidecar写有iphone不能证明真人、授权或标注已复核。D02人工复核人是JZD，软件不能自动代签人工复核。
6. 增加最小撤销记录和定位清单，明确本机原音频/metadata、导出副本、已交接位置及后续处置状态。不能声称可远程删除已分享副本，也不能因本地删文件就把撤销同步标完成。删除遵循用户安全规则：无递归/通配/循环清理；需要多个文件的实际删除先让用户明确批准范围，测试只用临时合成数据。
7. 不默认上传、分享或发送消息。用户主动分享也需界面清楚显示授权用途和实际目标；导出包不夹带其他人的录音或私密登记。

## 验证与真实阻断

用临时合成WAV/metadata验证合法导入导出、CSV一一对应、SHA-256、无授权/拒绝/到期/撤销、用途不匹配、缺文件/坏格式/哈希不符、模拟器不计真人、匿名ID关联和重启恢复。跑 `python3 -B -m unittest discover -s data/D01/tests -v`、受影响Swift测试、`python3 -B scripts/verify.py` 及可用模拟器构建，记录真实结果。

真实参与者授权、私密存储位置、保留策略、物理iPhone录音/导出及人工回听仍需用户实际完成；真人数保持0直到有可核验样本。后端已部署，但HTTP Token不等于模型Key，本任务没有云处理授权，也不能开启source trust或伪造声纹。不要为等待完整采集界面阻挡现有D01手工采集流程。

## 独立 ZIP 交付条件

提供完整当前App/Xcode工程/资源、D01工具与空模板、合成fixture/测试、脱敏运行说明、授权/导出/撤销流程和LHY-05验收/阻断记录。所有软件检查可不依赖真人数据重放。排除 `.git`、缓存、SDK、签名、`Local.xcconfig`、Token/模型Key、私人WAV/metadata/授权登记/身份映射/数据库；提供清单与SHA-256。真实语料需另按批准渠道交付，不默认放本ZIP。不编造Commit/PR、授权、样本数或物理iPhone验收；后续集成按差异处理，不用旧工程覆盖新工程。
