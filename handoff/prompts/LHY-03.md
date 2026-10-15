# LHY-03 独立执行 Prompt：完整 WAV HTTP 客户端

请接手 Fitcore 的 LHY-03，在现有工程实现新 WAV HTTP 契约的最小完整客户端和离线合同测试，完成后交付可在另一台 Mac 独立打开的完整 ZIP。先完成本任务，再依次交接 LHY-04、LHY-08；不要让多个任务同时修改同一工程。

## 先读与工作边界

在解压根目录依次阅读 `README.md`、`handoff/CURRENT_STATUS.md`、`handoff/KNOWN_API_GAPS.md`、`reference/task-package/tasks/LHY-03.md`、`reference/api/WAV_HTTP_API_2026-10-15.md`，再读 `reference/task-package/docs/02_IOS_API_AND_MODULES.md`、`docs/LHY-01-LOCAL-HANDOFF.md`。旧 `docs/lhy-13tasks-status-2026-10-15.md` 是历史基线，不能据此重做已完成的 LHY-01。

先报告理解、最小改动、当前目录与版本；有 Git 元数据时只读确认仓库/分支并沿用当前分支，没有则如实说明。不要初始化 Git、恢复旧提交覆盖源码、拉取/推送/创建 PR、操作 AWS 或调用公网/付费 API。默认使用本地 URLProtocol/fixture；本轮没有真实模型、上传真人音频或费用授权。保留四页布局与 Mock。

## 已有与目标

- 基线为 0.3.1 (8)。LHY-01 已有「设置→手机 WAV 采集」、`UUID.wav`/`UUID.metadata.json`、完成回调等待、标准文件校验。复用原文件及稳定身份，禁止重写录音链路。物理 iPhone 未验收，真人样本 0，无录音豆/盒子。
- `Core/Networking/BackendClient.swift`、`CloudHistoryClient.swift`、`Services/Training/TrainingAnalysisService.swift` 是旧 health/历史/文字接口基础，新链路不能仅改 Base URL。App 内本地生成复盘的旧流程也不能当成云端 Review。
- 目标：创建 Session→上传完整 WAV→轮询 Job→读取 Facts/Pending/Events→Finish→Review，且每一步有显式状态和可测试错误。

## 最小实施

1. 对照给定合同和可用脱敏响应逐项建立 DTO/请求及错误映射，复用现有网络注入方式。`/health` 新字段为 `status/model_provider`，旧 `service/environment` 解码不能照搬。冻结 OpenAPI/Postman 若仍缺失，记录字段级缺口；不要把臆造响应称为真实合同，合成 fixture 要标注来源和假设。
2. 实现 `POST /v1/sessions`（201；重复 ID 409）、`GET /v1/sessions/{sid}`、`POST /v1/sessions/{sid}/audio-jobs`、`GET /v1/sessions/{sid}/audio-jobs/{utterance_id}`、Facts/Pending/Events、`POST/GET .../finish`、`GET .../review`。Pending resolve 只按已有合同实现；确认请求字段未提供时保留缺口，不发明请求体或端点。
3. Multipart 仅带 `file`（原始 WAV 二进制）、`utterance_id`、`sequence`，可选 `audio_source`；不发送未知或重复字段。sequence 从 0 连续递增。音频须16kHz/mono/PCM16、非空非静音、文件≤7,000,000字节，multipart体≤7,065,536字节，不发送 Data URI/外部 URL。
4. 保留 sid、utterance_id、sequence、文件哈希、相同字节和来源元数据。503/网络超时重试复用整套身份；同ID不同内容、同sequence不同ID为409，不得换ID规避。区分创建会话冲突、上传冲突、来源确认冲突和 finish 缺段，不能把所有409归为成功或无限重试。
5. 上传202只代表持久化接受；轮询 `queued/asr_running/final_ready/llm_running/done`，done还要看 COMMIT/DEFER/REJECT。Facts/Review是正式训练记录来源，转写文本与Job done都不能直接增加完成组。轮询应可取消、有退避/限时；视图离开或会话变化后的旧响应不得写入新会话。
6. Finish前停止输入、等录音完成及全部预期片段被202接受，传稳定 `finish_id` 和真实 `last_sequence`。409 awaiting_audio提示/补齐缺段后重试同finish_id；202 draining继续查询；Review409明确尚未可用。`automatic_retry_exhausted=true` 应停止自动请求重试并展示错误，不通过新ID或重启UI重置预算。
7. 所有 `/v1/*` 使用私密注入的 HTTP Bearer Token，它不是 MODEL_API_KEY，不硬编码、不进日志/截图/ZIP；`/health`不代表模型可用。401/403给明确配置/权限错误，422/413/404/503按合同处理，只记录脱敏关联ID。
8. 正常公网模式 `AUDIO_TEST_SOURCE_TRUSTED=false`，SOURCE_UNCERTAIN→Pending 是正常结果，`speaker_verification=not_performed`。人工confirm也可能409 SOURCE_NOT_VERIFIED。禁止客户端自报speaker_status/source_type/voice_verified/VERIFIED_USER、调用旧文本端点、修改数据库或开启服务器可信测试开关绕过闸门。

## 验证与真实阻断

离线合同测试覆盖全部路由、multipart字段/字节、从0连续序号、相同上传重试、三种outcome、Facts为空但Pending非空、401/403/413/422/503、不同409、轮询取消、Finish202/409/Review409与耗尽预算。只用临时合成WAV/脱敏fixture，不读取私人音频、不调用ASR/Nova。跑受影响测试、现有 `swift test`、`python3 -B scripts/verify.py` 及可用的 `Fitcore-Mock` 模拟器构建；记录实际通过项和未执行原因。

后端已部署；历史文档中的“未部署”是旧时间点，不能据此重建 AWS。真实联调仍需用户另外批准范围/费用并私密配置有效 HTTP Token；字段级冻结合同、物理 iPhone、身份/来源 AUTH-01、声纹后端是未解决依赖。本轮最多宣布“本地客户端/fixture已验收”，不能宣布 AWS 音频端到端或声纹验收。

## 独立 ZIP 交付条件

ZIP包含完整当前App、Xcode工程/资源、新客户端/测试/fixture、更新后的运行入口与配置占位、LHY-03状态及路由/错误覆盖记录。所有测试可在无远程凭据时重放，保留原Mock和LHY-01。排除 `.git`、构建缓存、SDK、个人签名、`Local.xcconfig`、Token/模型Key、私人WAV/数据库；提供文件清单与SHA-256。没有Git就记录源码指纹，不编造Commit/PR。给LHY-04说明真实DTO/状态接点；其他任务成果须按差异集成，不整包覆盖较新代码。
