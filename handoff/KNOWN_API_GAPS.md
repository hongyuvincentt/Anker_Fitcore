# 后端合同优先级和客户端已知缺口

## 阅读优先级

本包仅保存已收到材料，没有此次重新访问 AWS 或模型。后端当前部署版本须由负责人确认，必要时取得冻结 OpenAPI/请求响应 fixture。

1. `reference/task-package/docs/01_PROJECT_HANDOFF.md` 的部署和来源门禁说明，以及 `reference/api/WAV_HTTP_API_2026-10-15.md` 的**完整 WAV**合同。
2. `reference/api/STABLE_BASELINE_WAV_HTTP_REPORT_2026-10-15.md` 的实际脱敏请求/响应样例；用于核对 DTO 和联调结果，单条成功不等于算法普遍正确。
3. `reference/api/IOS_AUDIO_CONTRACT_2026-10-15.md` 开头的当前事实/Pending说明、`EVENT_FINISH_REPORT_2026-10-15.md` 的事件与 Finish 说明。前者后段的 `/audio-chunks`、VAD、小写事件、`last_chunk_seq` 是历史方案；后者旧版手动推进处理流程不能覆盖新 Worker 自动推进。

原任务说明提到的 Step2 API ZIP / 冻结 OpenAPI、Postman 文件未在本工作区找到，不能声称已提供。先据现有合同写离线 fixture；实际字段歧义在真实联调前向后端负责人核对。

## 新合同主链

- `POST /v1/sessions`，发送稳定 `session_id`，201 创建；已有 ID 的409不能盲目换ID，可查询已有会话核对。
- `POST /v1/sessions/{sid}/audio-jobs`：multipart 字段 `file`、`utterance_id`、从0连续递增的 `sequence`；`audio_source` 可选。完整 16kHz/mono/PCM16 WAV，非空非静音，≤7,000,000 字节；整个 multipart ≤7,065,536 字节。
- 202 `acceptance=persisted` 仅证明持久化接收。轮询 `GET .../audio-jobs/{utterance_id}`；阶段 queued→asr_running→final_ready→llm_running→done。done 后仍看 COMMIT/DEFER/REJECT，不能都显示为已记账。
- 查询 `GET /v1/sessions/{sid}`、`/facts`、`/pending`、`/events?after=0&limit=100`。Pending 的人工 resolve 使用稳定 resolution_id 和准确 context_version；409先刷新，不能靠换ID/强改上下文绕过。
- 持久化事件类型为大写 `TRANSCRIPT_FINAL`、`FACT_COMMITTED`、`OPERATION_DEFERRED`、`INPUT_REJECTED`、`PROCESSING_ERROR`。event_seq从1开始，初始 after=0；整页应用成功后存 next_cursor，按event_id去重、按fact_id更新，不重复新增组。
- 停止产生新音频，确认所有完整文件202 ACK，再 `POST .../finish`，发送稳定 `finish_id` 和实际 `last_sequence`（空会话为-1）。409 awaiting_audio补同ID缺段，202 draining继续查询，200 finished后才能读取 Review。Worker 自动推进；不能用本地假结束绕开尾包。
- `GET .../review` 完成前可能409；目前是事实统计、facts、pending_count，没有完整 AI 建议/问答接口。finished时 Pending仍可能大于0。

上传超时/503重试必须沿用**同 sid、utterance_id、sequence、原音频和来源元数据**。相同身份但内容不一致、同序号换ID返回409，不换ID规避。保留原文件与持久化重试状态；次数有界，`automatic_retry_exhausted=true` 时呈现错误，不无限触发付费模型。

## 鉴权和来源

Base URL 的历史值：`https://54-254-212-127.sslip.io`，由后端负责人确认现值。`/health`不需要Token；成功响应里的 `status/model_provider` 不是模型可用性或来源验证证明。

所有 `/v1/*` 使用 `Authorization: Bearer <HTTP测试Token>`。**HTTP测试Token不是MODEL_API_KEY**；客户端只连统一后端，不直连厂商模型，不在聊天/源码/ZIP中写完整Token。后续用本地安全输入与Keychain，日志脱敏。

公网默认 `AUDIO_TEST_SOURCE_TRUSTED=false`。未验证音源可以进入 `SOURCE_UNCERTAIN` Pending；人工 confirm_set仍可能409 `SOURCE_NOT_VERIFIED`。这是后端来源授权缺口，不是在 App 里勾选“已验证”就能修复。不得伪造 speaker_status/source_type/voice_verified/VERIFIED_USER，不擅自开信任开关。授权单人演示不等于声纹验证；LHY-06 等待真实 F02 合同。

## 当前 App 的差异

- `BackendClient.swift` 的旧 health DTO 要求 service/environment，与新 status/model_provider 不一致。
- `TrainingAnalysisService.swift` 仍用旧文字 `/v1/training/sessions/.../inputs`，不是完整WAV Job。
- `CloudHistoryClient.swift` 仍用旧 `/v1/me`、`/v1/records`、`/v1/live/...`，不能只改URL就当作新客户端。
- AppStore 和 RecorderGateway 的 Mock、原有复盘仍有演示逻辑；LHY-03/04需明确区分服务端事实、本地录音、处理中、来源待确认与模拟结果。

保持现有四页和人物肌肉布局。后端 Fact Engine 才是权威事实来源，iOS不自行实现一套权威纠错/记账引擎。后端已知数字歧义/历史纠错问题应留失败证据交负责人处理，不能让客户端掩盖成成功。真实“60kg×10→上一组8次”的同组纠错与两句原话保留仍需单独验收。

## soundcore 与后续接口

SDK不在本包。原 Mac 核对过 iOS v1.3.01 的静态 `SoundcoreWorkAppleSDK.xcframework` 和 `module_spplinkKit.xcframework`，Release/Debug选对应一套，需另行授权提供。

SDK鉴权/许可证交换不等于模型Key；实时回调为20ms裸 Opus，不能加 WAV 头伪装 PCM，需要正确解码并核验实际固件声道/采样率，再转换为标准完整WAV。底层有startRecord符号，但D3200可用性、停止/收尾与授权需厂商确认；不要延用“完全没有开始接口”的旧推断，也不要编造stop方法。硬件传输完成不等于HTTP ACK、ASR或事实提交完成。

没有录音豆与充电盒，真实蓝牙连接、尾包、断线恢复验收保持未完成。LHY-07所需建议/问答等真实接口也未随本包提供，先复用已存在UI和明确Mock/不可用状态，不能杜撰API。
