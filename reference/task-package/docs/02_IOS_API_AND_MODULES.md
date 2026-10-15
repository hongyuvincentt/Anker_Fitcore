# 02 · iOS 架构与 API 对接说明

## 模块化边界
`WAVCaptureKit`（手机录音） / `SoundcoreInputAdapter`（录音豆） -> 统一 `AudioInput`（录音文件 URL + 来源类别 + 时间/设备元数据） -> `BackendHTTPClient`（Session、上传、Job、Events/Review） -> `TrainingSessionUI`。

可选 `CorpusCollector` 单独导出到授权数据区域；`SpeakerEnrollmentUI` 和 `AIInsightsUI` 分别独立 Feature Flag，未实现时展示不可用态，不影响记录主链。

## 稳定 API
Base URL 当前为 `https://54-254-212-127.sslip.io`；以 Codex 冻结的 Step2 OpenAPI/Postman 为字段级合同，本说明只列已确认的路由与交互，不编造响应结构。

| 操作 | 方法与路径 | 注意 |
| --- | --- | --- |
| 创建会话 | `POST /v1/sessions` | 既有合同：`session_id` 可选 |
| 上传完整WAV | `POST /v1/sessions/{sid}/audio-jobs` | multipart 必需 `file`、`utterance_id`、`sequence`；额外字段是否接受以 OpenAPI 为准 |
| Job | `GET /v1/sessions/{sid}/audio-jobs/{uid}` | `202` 仅接收成功；Job 需等待 `done`/错误 |
| Session | `GET /v1/sessions/{sid}` | 获取真实上下文版本 |
| Facts | `GET /v1/sessions/{sid}/facts` | 唯一正式训练事实来源 |
| Pending | `GET /v1/sessions/{sid}/pending` | 未验证或歧义时正常存在 |
| Events | `GET /v1/sessions/{sid}/events` | 游标/范围按 OpenAPI 处理 |
| Finish | `POST /v1/sessions/{sid}/finish` | 必需 `finish_id`、`last_sequence`；202 draining、409 awaiting_audio需显式处理 |
| Review | `GET /v1/sessions/{sid}/review` | Review 409 不能表现为训练成功 |
| Pending 处理 | `POST /v1/sessions/{sid}/pending/{pending_id}/resolve` | 服务端来源/权限闸门决定可否 confirm，不可绕过 |

## 格式与消息处理规则
1. 16kHz 单声道、16-bit PCM WAV，完整 RIFF，非空非静音，大小 ≤7,000,000 bytes。来源录音豆的音频若不是该格式必须先正确转换，禁止重命名后缀冒充 WAV。
2. 使用 `Authorization: Bearer <token>`，**Token不得在客户端仓库、截图、演示安装包或公开网页中硬编码**；赛事受控客户端先用安全分发临时凭据，正式产品必须用用户级短期身份令牌替换共享Bearer。
3. 提交后存储 sid/uid/sequence 与音频哈希并复用：网络重试不得换 utterance_id 反复计费、重复COMMIT。
4. 同 Session 的 sequence 连续、不可跳序；上传完成≠完成记账。处理中 UI 显示等待；正式训练记录仅从 Facts/Review 读取。
5. `AUDIO_TEST_SOURCE_TRUSTED=false` 的正常公网模式下，一条真实音频可以被安全 DEFER 到 Pending。**禁止客户端冒充 VERIFIED_USER、写 `trusted_test_text`、修改数据库或直接调用禁用的文本接口**。
6. Session 尾段处理完成后再 Finish；202/draining 继续等待，409/awaiting_audio 报缺段；Job done 后如果有 Pending 不能谎称自动记账成功。
7. 测试 ASR/Nova 会产生额度/费用：必须事先由你批准，默认全部使用 Mock/fixture。

## 必须明确告知用户的已知缺口
- 当前服务端单人测试可信归因不是声纹验证；正式移动用户身份与来源授权属 AUTH-01，由 Codex 主导。
- 原生 Soundcore SDK 真机接入未提供核验结果；不能以 iPhone 麦克风录音声称录音豆已打通。
- Android 将来复用 REST 合同，平台录音和 SDK 层独立实现；本包不包含 Android 客户端。

## LHY 需要回传的验收证据
- Mock HTTP 所有主路由的请求/响应测试与错误分支；不包含 Token。
- 音频 RIFF 元数据/大小检查结果，iPhone 和录音豆分别标记来源。
- UI 视频显示 Job 排队→处理中→Facts/Pending→Finish/Review，必要时提供脱敏日志。
- PR/Commit ID 与测试设备/Xcode版本。不得记录原始密钥、私人音频正文或私人身份信息。
