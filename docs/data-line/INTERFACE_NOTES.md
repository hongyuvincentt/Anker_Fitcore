# 给移动端/后端的说明（不改共享接口）

本设备只实现D01～D05离线数据工具，不改变LHY-03 HTTP请求、LHY-04状态/UI或服务器合同。另一台设备继续独立开发。本文件仅列出后续联调输入需求；字段未具备时，报告未测/阻断，不由客户端捏造。

## 手机采集交接

继续沿用原`UUID.wav`与`UUID.metadata.json`（schema_version=1）。D01新增原sidecar字节留存与hash/ID/time关联检查，不要求iOS修改schema。utterance_id应沿用recording_id，file_name应为ID.wav；输入WAV仍16k mono PCM16≤7,000,000字节。不得传虚构VERIFIED_USER或把本地verify-human当成服务端来源认证。

授权不是客户端默认开关：当前真实两段只local许可，不能随源码包发给JZD、后端、模型或云存储。实际采样清单与D02人工文本保留在私密位置。模型草稿24条只是公开开发案例，不是手机录音或金标。

## 未来评测日志需求（任务内离线适配）

D05输入是离线伴随记录，不是新增API DTO。需要实际可追溯的recording/case/session/utterance关联、稳定fact_id与纠错目标、每条实际自动决策(COMMIT/DEFER/REJECT)、人工确认与自动结果区分、时间语义和完整结构字段，以及被测Git SHA、模型/提供方/数据集版本。

若要测ASR数字/语义/Fact Engine错误，须真实转写、独立人工reference和已复核的分层裁定。若要测延迟/费用，须真实计时/账单证据，缺少时保留null/unmeasured，不以健康检查或Job done推断准确率。

格式和字段见`data/D05/docs/INPUT.schema.json`、`RUN.schema.json`及README。`docs/data-line/examples/`只提供明确synthetic的离线样例，不能发送到云接口或记入实测成果。HTTP合同若缺字段，只提交说明给负责人，不修改另一台设备的客户端代码。

## 当前验收缺口

真人2段待本人回听；原sidecar已找回核验补入2份；团队/云用途未授权；D02实际初标与双人审核0；D04独立held-out/批准冻结0；真实系统评测0。后端来源Pending门禁保持原样，不为获得COMMIT而调整AWS或绕过身份限制。
