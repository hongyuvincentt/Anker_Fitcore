# 完整 WAV HTTP 接口与启动

服务端：Python FastAPI + SQLite，单进程后台线程 Worker。来源为完整独立 WAV，不是流式音频块。本轮未改变 ASR、Nova、Fact Engine、选择性重解析、Event Cursor 或 Finish Barrier。

## 启动（Windows PowerShell）

在 `fitcore-core` 目录运行。真实赛事配置复用原环境；不要把 MODEL_API_KEY 给客户端。

```powershell
.venv\Scripts\python.exe -m pip install -e ".[dev]"
$env:MODEL_API_KEY = [Environment]::GetEnvironmentVariable('MODEL_API_KEY','User')
$env:MODEL_PROVIDER = 'real'
$env:MODEL_BASE_URL = 'https://ai-router-cn-pub.anker-in.com'
$env:MODEL_ID = 'hackathon/v_model/nova-pro'
$env:MODEL_API_PROTOCOL = 'openai_chat_completions'
$env:ASR_PROVIDER_HEADER = 'dashscope_ audio'
$env:DATABASE_URL = 'sqlite:///./fitcore-http.db'
$env:FITCORE_HTTP_API_TOKEN = (.venv\Scripts\python.exe -c "import secrets; print(secrets.token_urlsafe(32))")
# 仅在已授权、本人单人测试录音环境启用。此开关不是声纹验证。
$env:AUDIO_TEST_SOURCE_TRUSTED = 'true'
.venv\Scripts\python.exe -m scripts.serve_audio_http
```

该启动命令自动开启 Worker，只运行一个服务进程；不使用 `--reload` 或多进程 Worker。默认仅监听127.0.0.1:8000，关闭代理头信任。可以通过 `--host`、`--port` 配置，但本轮未部署外网、TLS或多用户权限。

直接运行 `uvicorn app.main:app` 时须显式配置 `AUDIO_WORKER_ENABLED=true`。默认关闭自动Worker以保留旧离线调试行为；上传HTTP必须配置单独的FITCORE_HTTP_API_TOKEN。启动程序缺少Token会拒绝启动，不会自动生成不可知的客户端凭据。

Token仅在本机环境中保存，用安全渠道给客户端配置，不写入Git。再次启动要保留相同Token；上面随机生成命令用于首次初始化。FITCORE_HTTP_API_TOKEN与赛事MODEL_API_KEY是不同凭据。

## 认证与来源

所有 `/v1/*` 请求使用 `Authorization: Bearer <FITCORE_HTTP_API_TOKEN>`，包括Session创建、事实、事件和Review查询。缺失或错误Token返回401；`/health`不需要认证，也不证明外部模型可用。无Token时仅保留本机旧文本调试，远程请求403，音频上传503。

配置Token后旧 `/utterances` 和 `/end` POST返回403，客户端不得以文本请求伪造 VERIFIED_USER。音频HTTP不接受 speaker_status、source_type、voice_verified 字段。

默认 `AUDIO_TEST_SOURCE_TRUSTED=false`，服务端标记 UNCERTAIN，ASR后进入来源待确认，不调用语义模型生成正式事实。仅已授权本人测试可在服务端开启该开关；服务端内部的 VERIFIED_USER 是沿用Core的测试来源门禁，不代表声纹识别。所有音频HTTP响应均包含 `speaker_verification: not_performed`。

## 上传与查询

| 方法 | 路径 | 行为 |
|---|---|---|
| POST | /v1/sessions | JSON `{ "session_id": "ios-mock-001" }`，201创建；已有ID为409 |
| POST | /v1/sessions/{sid}/audio-jobs | multipart完整WAV持久化后202，不等待ASR或LLM |
| GET | /v1/sessions/{sid}/audio-jobs/{utterance_id} | 作业状态、最终文本、ASR耗时、Core决定、重试次数和错误 |
| GET | /v1/sessions/{sid}/events?after=0&limit=100 | 复用持久化Event Cursor |
| POST | /v1/sessions/{sid}/finish | JSON `{ "finish_id": "finish-001", "last_sequence": 0 }` |
| GET | /v1/sessions/{sid}/finish | 查询刷包状态；后台自动完成已接受的draining流程 |
| GET | /v1/sessions/{sid}/review | Finish完成后读取正式事实统计 |

上传multipart字段：`file` 必填二进制WAV、`utterance_id` 必填且最长120字符、`sequence` 必填且从0连续递增、`audio_source` 可选最长200字符，默认client_complete_wav。不支持未知字段或同名字段重复。

WAV必须16kHz、单声道、16-bit PCM、可读取且非静音，最大7,000,000字节。实际音频字节和完整multipart体均受限；multipart总上限为7,065,536字节，避免绕过Content-Length无限解析。不得上传Data URI或外部URL。

```powershell
$headers = @{ Authorization = "Bearer $env:FITCORE_HTTP_API_TOKEN" }
Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8000/v1/sessions' `
  -Headers $headers -ContentType 'application/json' -Body '{"session_id":"ios-mock-001"}'
curl.exe -i -H "Authorization: Bearer $env:FITCORE_HTTP_API_TOKEN" `
  -F 'file=@tests/assets/continuous_session/01_bench_first.wav;type=audio/wav' `
  -F 'utterance_id=u0' -F 'sequence=0' -F 'audio_source=ios_mock' `
  'http://127.0.0.1:8000/v1/sessions/ios-mock-001/audio-jobs'
Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8000/v1/sessions/ios-mock-001/finish' `
  -Headers $headers -ContentType 'application/json' -Body '{"finish_id":"finish-001","last_sequence":0}'
```

202返回 `acceptance: persisted` 和 `job`：这表示WAV及元数据已提交SQLite，不表示ASR或事实已经提交。正常状态进展：queued → asr_running → final_ready → llm_running → done；ASR最终文本和TRANSCRIPT_FINAL持久化后才进入语义阶段。done仍需检查outcome：COMMIT、DEFER或REJECT，不能把done等同于新增训练组。

同Session、同utterance_id、同文件及元数据重复上传返回202和原作业当前状态。相同ID不同音频或元数据、同sequence不同ID为409；不得换ID规避冲突。同一个已接受作业在Finish后仍可幂等重传；范围外新音频409。

其他错误：格式/来源声明/非法字段422，文件过大413，未认证401，会话不存在404，数据库写入失败503。503或网络断线重试相同ID、序号、音频和来源元数据。

## Worker、错误与恢复

Worker每0.25秒查询持久化队列，同Session按既有连续sequence规则处理，不跳过缺段或失败前序。单实例OS文件锁防止同数据库启动第二个消费者；不要并行运行旧手动处理脚本。

默认每阶段初始调用加一次自动重试：`AUDIO_WORKER_MAX_ATTEMPTS=2`，失败退避1秒。设置可配置，范围1–5；调用计数保存在既有audio_jobs表，重启不清零。超时重用原utterance_id；有FINAL时不再调用ASR；选择性重解析仍由冻结实现限制为最多一次。

预算耗尽后停止自动调用，查询作业返回 `automatic_retry_exhausted=true`，Finish保持未完成，错误事件保留。管理员检查错误后可显式调整启动预算再重启；不提供外部清空计数或跳过失败音频的接口。

正常退出等待在途Provider调用返回；进程强制退出后OS锁释放，新进程从SQLite检查点继续。Core已提交但音频ACK未落库时，即使自动调用预算耗尽也会通过原幂等检查补ACK，不再次调用模型。

客户端先停止产生音频、确认全部片段202，再发送真正尾段last_sequence；409 awaiting_audio须补齐缺段并重试同finish_id。202 draining由Worker继续推进，所有作业done才完成Review。Finish完成不代表所有语义均已确认；Review同时返回pending_count。

## 存储与边界

完整WAV继续保存在既有SQLite BLOB，本轮无新数据库表或存储迁移。每片最大7MB并不限制总数据库增长；尚无自动删除/归档、会话容量或请求速率配额，演示后由负责人按现有保留策略管理本地数据库。真人音频、数据库及诊断日志不进入Git。

当前单进程、串行Worker适合两人联调，未验证并发负载或公网部署；没有VAD、实时流式ASR或声纹。不要把网络传输分片当成最终语句。既有数字歧义与历史纠错问题保持原样，下一轮处理。
