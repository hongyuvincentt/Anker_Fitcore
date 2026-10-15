# Fitcore V1.1 稳定基线冻结与 WAV HTTP 验收

日期：2026-10-15。本轮仅冻结版本、增加完整WAV HTTP入口和单实例自动Worker；不处理第三轮数字歧义或纠错语义。

## 冻结与迁移检查

工作区原先没有Git仓库，无法沿用既有分支流程。本轮在fitcore-core本身初始化本地仓库，原77个代码/文档文件完整提交，无reset、覆盖或删除旧修改。

- 基线提交：`bc264f0`，本地注释标签 `fitcore-v1.1-round2`。标签不随HTTP开发移动。
- 后续开发分支：`feature/wav-http`，本轮代码另行提交；未创建远程仓库、推送或发布。
- 基线全量：**196 passed、1 skipped、1 warning，47.80秒**。JUnit：`local-diagnostics/http_baseline_pytest.xml`。
- 第二轮原报告完整纳入基线：`docs/V1_1_ROUND2_SELECTIVE_REPARSE_2026-10-15.md`，SHA256为 `718b0cfdce0e52e45b853e9ac031444ba302303a11f67f29fff44fac9cc3f115`。
- 根目录数据库SQLite备份：`local-diagnostics/baseline-freeze/fitcore-round2.db`，清单`manifest.json`；根数据库原本无业务行。另备份第二轮真实验收的有数据数据库为`real-round2-populated.db`。
- 对空库备份及有三组事实的真实库备份，各重复执行两次现有init_db，数据保持，PRAGMA integrity_check均为ok；有数据库全量SQL dump哈希不变。本轮没有修改app/db.py，没有增加表或迁移。
- 所有真人WAV、SQLite、环境文件、local-diagnostics继续Git忽略；提交前对已配置真实Key进行精确匹配扫描，未发现Key进入版本文件。

第二轮3组与人工4组不一致的问题保留，没有通过本轮HTTP改动修正统计或改变答案。

## HTTP实现与修改文件

| 文件 | 内容 |
|---|---|
| app/audio/http.py | multipart WAV POST、作业GET、认证与来源边界、请求/文件大小限制、幂等与冲突映射 |
| app/audio/worker.py | 单线程Worker、OS单实例锁、SQLite队列恢复、有限重试、调用现有Finish完成刷包 |
| app/main.py | 路由注册、生命周期启动/停止Worker、依赖注入及配置校验 |
| app/config.py、.env.example | HTTP Token、授权测试来源开关、Worker轮询/退避/尝试预算 |
| pyproject.toml | 增加python-multipart与WAV校验所需NumPy/SciPy运行依赖 |
| scripts/serve_audio_http.py | 一条命令启动本机单进程HTTP与自动Worker |
| scripts/verify_audio_http.py | 独立数据库、真实TCP服务、原真人WAV、真实Provider观测、进程重启对照 |
| tests/test_audio_http.py | 19项离线HTTP、访问控制、队列及恢复回归 |
| README、IOS_AUDIO_CONTRACT、WAV_HTTP_API、本文 | 更新实际已实现接口，保留早期设计为历史说明 |

相对冻结标签，Training Context、Fact Engine（app/service.py）、Semantic Schema/Prompt/Selective Reparse、ASR Provider、Audio Orchestrator、Event Cursor、Finish Barrier、数据库实现均无改动。官方Provider值 `dashscope_ audio` 内部空格原样保留。

## 接口与身份边界

新增 `POST /v1/sessions/{sid}/audio-jobs`：multipart中的file为完整16kHz/mono/16-bit PCM WAV，配套utterance_id、sequence、可选audio_source。原Audio Orchestrator执行校验、哈希和SQLite持久化；返回202不等待ASR/Nova。文件上限7,000,000字节，整个multipart体上限额外允许65,536字节，流式接收时也检查实际字节，不能以缺少Content-Length绕过。

同ID/序号/音频/来源重复上传返回原作业当前状态；同ID不同字节或元数据、同序号不同ID为409。GET `/audio-jobs/{uid}`查询已接收、ASR最终文本、事实决定及错误。现有events、finish、review路径保持。

所有/v1接口在配置Token后要求Bearer认证，客户端Token与模型Key分离。配置Token时旧文本/结束入口禁止来源自证。无Token只保留本机旧文本开发访问，远程403，音频上传503。源站应通过本轮启动脚本运行并关闭代理头信任。

上传拒绝speaker_status、source_type、voice_verified等额外字段。服务端默认来源UNCERTAIN，即使ASR成功也不自动形成事实；只有已授权本人测试，才由服务端开启AUDIO_TEST_SOURCE_TRUSTED。响应明确speaker_verification=not_performed，本轮没有声纹识别。

## Worker与恢复机制

启动脚本自动开启一个后台线程，通过独立OS文件锁禁止同SQLite重复消费者。现有SessionLock仍保护每个Session的按序处理；缺序号或失败前序不跳过。

默认每阶段最多2次尝试，失败退避1秒。重试次数使用既有audio_jobs持久化字段，重启不清零；FINAL存在则不再次ASR。已提交Core但音频ACK丢失时，允许原Core幂等路径补ACK，即使尝试预算已耗尽也不再请求模型。

预算耗尽返回automatic_retry_exhausted，失败事件保留，Finish不假装完成。已进入draining且所有作业done时，Worker调用原Finish实现关闭Session、保存Review，不要求手动脚本刷包。

正常关闭等待在途调用返回；强制进程退出后锁由OS释放，重启从SQLite恢复。本轮不增加Redis、额外数据库或分布式任务系统。

## 真实HTTP验收

使用原 `tests/assets/continuous_session/01_bench_first.wav`，5.0秒、160044字节、16kHz/mono/PCM16，非静音、无明显削波；SHA256为 `cf95fe997c5100ab3ba90e8ec0af94b263e93990efda441fa5b33f86852e6337`。原文件未改变。

实际启动独立Uvicorn TCP进程，非TestClient，使用独立数据库。HTTP与Provider完整脱敏日志：
`local-diagnostics/http-acceptance/2407e2bc69e94f7bbd2511e18ab6bd85/`。

- Session创建201；首次上传202、**44.42ms**，重复上传202、42.18ms。
- 上传后客户端不调用处理脚本，Worker自动执行真实ASR和Nova；Finish先返回202 draining，最后GET显示finished。
- ASR真实HTTP200、**4369ms**，最终文本“卧推60公斤做了8个。”；上游发送1.22ms已包含在ASR总耗时中，不重复相加。WAV实际5秒，上游额外时长字段为2秒，未拿该字段冒充处理延迟。
- Nova真实HTTP200、**6692ms**，Schema成功，SET_COMPLETED/current/fact、bench_press、60kg、8次。
- SQLite只有一条正式事实，来源u0。事件为TRANSCRIPT_FINAL后FACT_COMMITTED，游标1、2；Review为1组、8次、480kg·次、0 Pending。
- 完成后强制终止该测试服务进程，再启动新进程使用同数据库：事实、事件与Review完全一致；游标2之后为空。
- 重启后同ID同WAV仍202，没有增加ASR/Nova调用；新ID范围外音频409。
- 实际Provider总调用为**1次ASR、1次Nova**，没有Mock和选择性重解析，没有为验收修改语义模块。精确Fact Engine耗时未独立测量，不以差值伪造。

首次验收启动曾在本机健康检查阶段超时，记录保留在`local-diagnostics/http-acceptance/32a71e90efb449e5b0c279d47fb2c527/`，没有发送WAV或调用真实AI。验收工具随后改为45秒启动预算、2秒健康检查、显式禁用验收客户端环境代理；后续真实TCP链路成功。首次启动等待的操作系统调度/冷启动因素未完整采样，具体根因未证实；没有据此修改赛事接口参数。

## 离线测试与未验证事项

新19项离线测试使用明确标记的合成WAV与Provider夹具，不作为真实模型成功证据。覆盖异步ACK、最后音频仍在ASR时Finish等待、重复/冲突上传、来源伪造、认证、真实字节大小上限、会话缺失/格式错误、ASR/LLM各一次超时恢复、重启后FINAL复用、重试预算不重置、Core已提交但ACK丢失、重复Worker拒绝。

当前全量为 **215 passed、1 skipped、1 warning，33.30秒**，原196项全部保留。skip是原可选真实模型pytest；真实HTTP验收另行执行且成功。warning为原有Starlette/httpx弃用提示。

真实运行本次没有发生ASR/LLM超时，超时恢复通过离线注入验证；真实重启发生在链路成功后，未在真实上游请求中途强制杀进程。还未验证公网、HTTPS、并发负载或多用户会话隔离；当前Token为共享联调用凭据。默认单Worker串行外部调用，SQLite仍保存完整WAV，7MB为单文件限制，不是总存储配额；没有新增自动保留/删除策略。

数字歧义和历史纠错误分类原样保留；本轮没有进行第三轮恢复、优化Prompt、构建语料或修改UI/AWS/SDK。完成后停止开发。

## 实际请求响应与测试清单

以下从本地真实请求记录与pytest JUnit生成。Authorization仅保存脱敏标记，multipart音频以文件哈希记录，不复制私人音频字节。

### Actual TCP HTTP requests

Authorization for every request: `Bearer [redacted]`.

| Method | Path | HTTP | Elapsed ms |
|---|---|---:|---:|
| POST | `/v1/sessions` | 201 | 16.16 |
| POST | `/v1/sessions/http-2407e2bc69e9/audio-jobs` | 202 | 44.42 |
| POST | `/v1/sessions/http-2407e2bc69e9/audio-jobs` | 202 | 42.18 |
| POST | `/v1/sessions/http-2407e2bc69e9/finish` | 202 | 16.11 |
| GET | `/v1/sessions/http-2407e2bc69e9/finish` | 200 | 5.98 |
| GET | `/v1/sessions/http-2407e2bc69e9/events` | 200 | 24.15 |
| GET | `/v1/sessions/http-2407e2bc69e9/audio-jobs/u0` | 200 | 30.62 |
| GET | `/v1/sessions/http-2407e2bc69e9/facts` | 200 | 27.88 |
| GET | `/v1/sessions/http-2407e2bc69e9/review` | 200 | 6.64 |
| GET | `/v1/sessions/http-2407e2bc69e9/facts` | 200 | 11.39 |
| GET | `/v1/sessions/http-2407e2bc69e9/review` | 200 | 10.16 |
| GET | `/v1/sessions/http-2407e2bc69e9/events` | 200 | 10.89 |
| POST | `/v1/sessions/http-2407e2bc69e9/audio-jobs` | 202 | 57.83 |
| GET | `/v1/sessions/http-2407e2bc69e9/events?after=2` | 200 | 6.54 |
| POST | `/v1/sessions/http-2407e2bc69e9/audio-jobs` | 409 | 27.21 |

#### Request 1: POST /v1/sessions

```json
{
  "request_json": {
    "session_id": "http-2407e2bc69e9"
  },
  "multipart_metadata": null,
  "authorization": "Bearer [redacted]",
  "status": 201,
  "elapsed_ms": 16.16,
  "body": {
    "session_id": "http-2407e2bc69e9",
    "version": 0,
    "status": "active",
    "active_exercise_instance_id": null,
    "active_exercise_name": null,
    "last_completed_set_id": null,
    "last_reported_weight": null,
    "next_set_plan": null
  }
}
```

#### Request 2: POST /v1/sessions/http-2407e2bc69e9/audio-jobs

```json
{
  "request_json": null,
  "multipart_metadata": {
    "utterance_id": "u0",
    "sequence": "0",
    "audio_source": "http_acceptance"
  },
  "authorization": "Bearer [redacted]",
  "status": 202,
  "elapsed_ms": 44.42,
  "body": {
    "acceptance": "persisted",
    "speaker_verification": "not_performed",
    "source_assurance": "server_authorized_test",
    "job": {
      "session_id": "http-2407e2bc69e9",
      "utterance_id": "u0",
      "sequence": 0,
      "audio_sha256": "cf95fe997c5100ab3ba90e8ec0af94b263e93990efda441fa5b33f86852e6337",
      "audio_source": "http_authorized_test:http_acceptance",
      "source_type": "authenticated_audio",
      "speaker_status": "VERIFIED_USER",
      "status": "queued",
      "final_text": null,
      "asr_attempts": 0,
      "llm_attempts": 0,
      "error_type": null,
      "audio_metadata": {
        "sample_rate": 16000,
        "channels": 1,
        "bits_per_sample": 16,
        "frames": 80000,
        "duration_seconds": 5.0,
        "rms_dbfs": -23.7,
        "peak_dbfs": -2.53,
        "clipped_fraction": 0.0,
        "non_silent": true
      },
      "outcome": null,
      "asr_diagnostics": null
    }
  }
}
```

#### Request 3: POST /v1/sessions/http-2407e2bc69e9/audio-jobs

```json
{
  "request_json": null,
  "multipart_metadata": {
    "utterance_id": "u0",
    "sequence": "0",
    "audio_source": "http_acceptance"
  },
  "authorization": "Bearer [redacted]",
  "status": 202,
  "elapsed_ms": 42.18,
  "body": {
    "acceptance": "persisted",
    "speaker_verification": "not_performed",
    "source_assurance": "server_authorized_test",
    "job": {
      "session_id": "http-2407e2bc69e9",
      "utterance_id": "u0",
      "sequence": 0,
      "audio_sha256": "cf95fe997c5100ab3ba90e8ec0af94b263e93990efda441fa5b33f86852e6337",
      "audio_source": "http_authorized_test:http_acceptance",
      "source_type": "authenticated_audio",
      "speaker_status": "VERIFIED_USER",
      "status": "queued",
      "final_text": null,
      "asr_attempts": 0,
      "llm_attempts": 0,
      "error_type": null,
      "audio_metadata": {
        "sample_rate": 16000,
        "channels": 1,
        "bits_per_sample": 16,
        "frames": 80000,
        "duration_seconds": 5.0,
        "rms_dbfs": -23.7,
        "peak_dbfs": -2.53,
        "clipped_fraction": 0.0,
        "non_silent": true
      },
      "outcome": null,
      "asr_diagnostics": null
    }
  }
}
```

#### Request 4: POST /v1/sessions/http-2407e2bc69e9/finish

```json
{
  "request_json": {
    "finish_id": "http-finish",
    "last_sequence": 0
  },
  "multipart_metadata": null,
  "authorization": "Bearer [redacted]",
  "status": 202,
  "elapsed_ms": 16.11,
  "body": {
    "session_id": "http-2407e2bc69e9",
    "finish_id": "http-finish",
    "last_sequence": 0,
    "state": "draining",
    "complete": false,
    "acceptance_closed": true,
    "missing_sequences": [],
    "missing_count": 0,
    "unfinished": [
      {
        "utterance_id": "u0",
        "sequence": 0,
        "audio_sha256": "cf95fe997c5100ab3ba90e8ec0af94b263e93990efda441fa5b33f86852e6337",
        "status": "queued",
        "error_type": null
      }
    ],
    "accepted_count": 1,
    "ready_to_finalize": false,
    "review": null
  }
}
```

#### Request 5: GET /v1/sessions/http-2407e2bc69e9/finish

```json
{
  "request_json": null,
  "multipart_metadata": null,
  "authorization": "Bearer [redacted]",
  "status": 200,
  "elapsed_ms": 5.98,
  "body": {
    "session_id": "http-2407e2bc69e9",
    "finish_id": "http-finish",
    "last_sequence": 0,
    "state": "finished",
    "complete": true,
    "acceptance_closed": true,
    "missing_sequences": [],
    "missing_count": 0,
    "unfinished": [],
    "accepted_count": 1,
    "ready_to_finalize": false,
    "review": {
      "session_id": "http-2407e2bc69e9",
      "context_version": 2,
      "total_sets": 1,
      "total_reps": 8,
      "volume_kg_reps": 480.0,
      "pending_count": 0,
      "facts": [
        {
          "id": 1,
          "exercise_instance_id": 1,
          "exercise": "bench_press",
          "set_number": 1,
          "weight_kg": 60.0,
          "reps": 8,
          "weight_provenance": "EXPLICIT",
          "weight_source_fact_id": null,
          "source_utterance_id": "u0"
        }
      ]
    }
  }
}
```

#### Request 6: GET /v1/sessions/http-2407e2bc69e9/events

```json
{
  "request_json": null,
  "multipart_metadata": null,
  "authorization": "Bearer [redacted]",
  "status": 200,
  "elapsed_ms": 24.15,
  "body": {
    "events": [
      {
        "event_seq": 1,
        "event_id": "http-2407e2bc69e9:event:1",
        "type": "TRANSCRIPT_FINAL",
        "utterance_id": "u0",
        "payload": {
          "text": "卧推60公斤做了8个。",
          "audio_source": "http_authorized_test:http_acceptance",
          "audio_sha256": "cf95fe997c5100ab3ba90e8ec0af94b263e93990efda441fa5b33f86852e6337",
          "sequence": 0
        },
        "created_at": "2026-10-15 03:26:52"
      },
      {
        "event_seq": 2,
        "event_id": "http-2407e2bc69e9:event:2",
        "type": "FACT_COMMITTED",
        "utterance_id": "u0",
        "payload": {
          "decision": "COMMIT",
          "context_version": 1,
          "committed": [
            {
              "type": "SET_COMPLETED",
              "id": 1,
              "exercise_instance_id": 1,
              "exercise": "bench_press",
              "set_number": 1,
              "weight_kg": 60.0,
              "reps": 8,
              "weight_provenance": "EXPLICIT"
            }
          ],
          "reason": null
        },
        "created_at": "2026-10-15 03:26:59"
      }
    ],
    "next_cursor": 2,
    "has_more": false
  }
}
```

#### Request 7: GET /v1/sessions/http-2407e2bc69e9/audio-jobs/u0

```json
{
  "request_json": null,
  "multipart_metadata": null,
  "authorization": "Bearer [redacted]",
  "status": 200,
  "elapsed_ms": 30.62,
  "body": {
    "speaker_verification": "not_performed",
    "automatic_retry_exhausted": false,
    "job": {
      "session_id": "http-2407e2bc69e9",
      "utterance_id": "u0",
      "sequence": 0,
      "audio_sha256": "cf95fe997c5100ab3ba90e8ec0af94b263e93990efda441fa5b33f86852e6337",
      "audio_source": "http_authorized_test:http_acceptance",
      "source_type": "authenticated_audio",
      "speaker_status": "VERIFIED_USER",
      "status": "done",
      "final_text": "卧推60公斤做了8个。",
      "asr_attempts": 1,
      "llm_attempts": 1,
      "error_type": null,
      "audio_metadata": {
        "sample_rate": 16000,
        "channels": 1,
        "bits_per_sample": 16,
        "frames": 80000,
        "duration_seconds": 5.0,
        "rms_dbfs": -23.7,
        "peak_dbfs": -2.53,
        "clipped_fraction": 0.0,
        "non_silent": true
      },
      "outcome": {
        "utterance_id": "u0",
        "decision": "COMMIT",
        "context_version": 1,
        "committed": [
          {
            "type": "SET_COMPLETED",
            "id": 1,
            "exercise_instance_id": 1,
            "exercise": "bench_press",
            "set_number": 1,
            "weight_kg": 60.0,
            "reps": 8,
            "weight_provenance": "EXPLICIT"
          }
        ],
        "reason": null,
        "semantic_diagnostics": [],
        "reparse": null
      },
      "asr_diagnostics": {
        "transcript": "卧推60公斤做了8个。",
        "audio_duration_seconds": 5.0,
        "provider_duration_seconds": 2.0,
        "elapsed_ms": 4369,
        "http_status": 200
      }
    }
  }
}
```

#### Request 8: GET /v1/sessions/http-2407e2bc69e9/facts

```json
{
  "request_json": null,
  "multipart_metadata": null,
  "authorization": "Bearer [redacted]",
  "status": 200,
  "elapsed_ms": 27.88,
  "body": [
    {
      "id": 1,
      "exercise_instance_id": 1,
      "exercise": "bench_press",
      "set_number": 1,
      "weight_kg": 60.0,
      "reps": 8,
      "weight_provenance": "EXPLICIT",
      "weight_source_fact_id": null,
      "source_utterance_id": "u0"
    }
  ]
}
```

#### Request 9: GET /v1/sessions/http-2407e2bc69e9/review

```json
{
  "request_json": null,
  "multipart_metadata": null,
  "authorization": "Bearer [redacted]",
  "status": 200,
  "elapsed_ms": 6.64,
  "body": {
    "session_id": "http-2407e2bc69e9",
    "context_version": 2,
    "total_sets": 1,
    "total_reps": 8,
    "volume_kg_reps": 480.0,
    "pending_count": 0,
    "facts": [
      {
        "id": 1,
        "exercise_instance_id": 1,
        "exercise": "bench_press",
        "set_number": 1,
        "weight_kg": 60.0,
        "reps": 8,
        "weight_provenance": "EXPLICIT",
        "weight_source_fact_id": null,
        "source_utterance_id": "u0"
      }
    ]
  }
}
```

#### Request 10: GET /v1/sessions/http-2407e2bc69e9/facts

```json
{
  "request_json": null,
  "multipart_metadata": null,
  "authorization": "Bearer [redacted]",
  "status": 200,
  "elapsed_ms": 11.39,
  "body": [
    {
      "id": 1,
      "exercise_instance_id": 1,
      "exercise": "bench_press",
      "set_number": 1,
      "weight_kg": 60.0,
      "reps": 8,
      "weight_provenance": "EXPLICIT",
      "weight_source_fact_id": null,
      "source_utterance_id": "u0"
    }
  ]
}
```

#### Request 11: GET /v1/sessions/http-2407e2bc69e9/review

```json
{
  "request_json": null,
  "multipart_metadata": null,
  "authorization": "Bearer [redacted]",
  "status": 200,
  "elapsed_ms": 10.16,
  "body": {
    "session_id": "http-2407e2bc69e9",
    "context_version": 2,
    "total_sets": 1,
    "total_reps": 8,
    "volume_kg_reps": 480.0,
    "pending_count": 0,
    "facts": [
      {
        "id": 1,
        "exercise_instance_id": 1,
        "exercise": "bench_press",
        "set_number": 1,
        "weight_kg": 60.0,
        "reps": 8,
        "weight_provenance": "EXPLICIT",
        "weight_source_fact_id": null,
        "source_utterance_id": "u0"
      }
    ]
  }
}
```

#### Request 12: GET /v1/sessions/http-2407e2bc69e9/events

```json
{
  "request_json": null,
  "multipart_metadata": null,
  "authorization": "Bearer [redacted]",
  "status": 200,
  "elapsed_ms": 10.89,
  "body": {
    "events": [
      {
        "event_seq": 1,
        "event_id": "http-2407e2bc69e9:event:1",
        "type": "TRANSCRIPT_FINAL",
        "utterance_id": "u0",
        "payload": {
          "text": "卧推60公斤做了8个。",
          "audio_source": "http_authorized_test:http_acceptance",
          "audio_sha256": "cf95fe997c5100ab3ba90e8ec0af94b263e93990efda441fa5b33f86852e6337",
          "sequence": 0
        },
        "created_at": "2026-10-15 03:26:52"
      },
      {
        "event_seq": 2,
        "event_id": "http-2407e2bc69e9:event:2",
        "type": "FACT_COMMITTED",
        "utterance_id": "u0",
        "payload": {
          "decision": "COMMIT",
          "context_version": 1,
          "committed": [
            {
              "type": "SET_COMPLETED",
              "id": 1,
              "exercise_instance_id": 1,
              "exercise": "bench_press",
              "set_number": 1,
              "weight_kg": 60.0,
              "reps": 8,
              "weight_provenance": "EXPLICIT"
            }
          ],
          "reason": null
        },
        "created_at": "2026-10-15 03:26:59"
      }
    ],
    "next_cursor": 2,
    "has_more": false
  }
}
```

#### Request 13: POST /v1/sessions/http-2407e2bc69e9/audio-jobs

```json
{
  "request_json": null,
  "multipart_metadata": {
    "utterance_id": "u0",
    "sequence": "0",
    "audio_source": "http_acceptance"
  },
  "authorization": "Bearer [redacted]",
  "status": 202,
  "elapsed_ms": 57.83,
  "body": {
    "acceptance": "persisted",
    "speaker_verification": "not_performed",
    "source_assurance": "server_authorized_test",
    "job": {
      "session_id": "http-2407e2bc69e9",
      "utterance_id": "u0",
      "sequence": 0,
      "audio_sha256": "cf95fe997c5100ab3ba90e8ec0af94b263e93990efda441fa5b33f86852e6337",
      "audio_source": "http_authorized_test:http_acceptance",
      "source_type": "authenticated_audio",
      "speaker_status": "VERIFIED_USER",
      "status": "done",
      "final_text": "卧推60公斤做了8个。",
      "asr_attempts": 1,
      "llm_attempts": 1,
      "error_type": null,
      "audio_metadata": {
        "sample_rate": 16000,
        "channels": 1,
        "bits_per_sample": 16,
        "frames": 80000,
        "duration_seconds": 5.0,
        "rms_dbfs": -23.7,
        "peak_dbfs": -2.53,
        "clipped_fraction": 0.0,
        "non_silent": true
      },
      "outcome": {
        "utterance_id": "u0",
        "decision": "COMMIT",
        "context_version": 1,
        "committed": [
          {
            "type": "SET_COMPLETED",
            "id": 1,
            "exercise_instance_id": 1,
            "exercise": "bench_press",
            "set_number": 1,
            "weight_kg": 60.0,
            "reps": 8,
            "weight_provenance": "EXPLICIT"
          }
        ],
        "reason": null,
        "semantic_diagnostics": [],
        "reparse": null
      },
      "asr_diagnostics": {
        "transcript": "卧推60公斤做了8个。",
        "audio_duration_seconds": 5.0,
        "provider_duration_seconds": 2.0,
        "elapsed_ms": 4369,
        "http_status": 200
      }
    }
  }
}
```

#### Request 14: GET /v1/sessions/http-2407e2bc69e9/events?after=2

```json
{
  "request_json": null,
  "multipart_metadata": null,
  "authorization": "Bearer [redacted]",
  "status": 200,
  "elapsed_ms": 6.54,
  "body": {
    "events": [],
    "next_cursor": 2,
    "has_more": false
  }
}
```

#### Request 15: POST /v1/sessions/http-2407e2bc69e9/audio-jobs

```json
{
  "request_json": null,
  "multipart_metadata": {
    "utterance_id": "late",
    "sequence": "1",
    "audio_source": "http_acceptance"
  },
  "authorization": "Bearer [redacted]",
  "status": 409,
  "elapsed_ms": 27.21,
  "body": {
    "detail": "AUDIO_ACCEPTANCE_CLOSED"
  }
}
```

### Real provider observations

```json
[
  {
    "kind": "asr",
    "result": {
      "transcript": "卧推60公斤做了8个。",
      "audio_duration_seconds": 5.0,
      "provider_duration_seconds": 2.0,
      "elapsed_ms": 4369,
      "http_status": 200
    },
    "diagnostics": {
      "request_sent": true,
      "http_status": 200,
      "elapsed_ms": 4369,
      "schema_parse_success": true,
      "error_type": null,
      "transport": "real_network",
      "upstream_body_send_ms": 1.22
    }
  },
  {
    "kind": "nova",
    "transcript": "卧推60公斤做了8个。",
    "context": {
      "session_id": "http-2407e2bc69e9",
      "version": 0,
      "status": "active",
      "active_exercise_instance_id": null,
      "active_exercise_name": null,
      "last_completed_set_id": null,
      "last_reported_weight": null,
      "next_set_plan": null
    },
    "result": {
      "operations": [
        {
          "operation_index": 0,
          "intent": "SET_COMPLETED",
          "who": "self",
          "when": "current",
          "modality": "fact",
          "exercise": "bench_press",
          "weight_kg": 60.0,
          "weight_delta_kg": null,
          "reps": 8,
          "set_number": null,
          "note": null,
          "target_set_id": null,
          "exercise_instance_id": null
        }
      ],
      "ambiguities": []
    },
    "diagnostics": {
      "request_attempted": true,
      "request_sent": true,
      "http_status": 200,
      "elapsed_ms": 6692,
      "schema_parse_success": true,
      "error_type": null,
      "transport": "real_network",
      "finish_reason": "stop",
      "content_chars": 263,
      "single_json_code_fence": false
    }
  }
]
```

### SQLite verification

Database: `local-diagnostics/http-acceptance/2407e2bc69e94f7bbd2511e18ab6bd85/http.db`.

```json
{
  "facts": [
    {
      "id": 1,
      "exercise_instance_id": 1,
      "exercise": "bench_press",
      "set_number": 1,
      "weight_kg": 60.0,
      "reps": 8,
      "weight_provenance": "EXPLICIT",
      "weight_source_fact_id": null,
      "source_utterance_id": "u0"
    }
  ],
  "review": {
    "session_id": "http-2407e2bc69e9",
    "context_version": 2,
    "total_sets": 1,
    "total_reps": 8,
    "volume_kg_reps": 480.0,
    "pending_count": 0,
    "facts": [
      {
        "id": 1,
        "exercise_instance_id": 1,
        "exercise": "bench_press",
        "set_number": 1,
        "weight_kg": 60.0,
        "reps": 8,
        "weight_provenance": "EXPLICIT",
        "weight_source_fact_id": null,
        "source_utterance_id": "u0"
      }
    ]
  },
  "restart_verified": true,
  "audio_unchanged": true,
  "passed": true
}
```

### New offline tests

| Test case | Result |
|---|---|
| `test_ack_does_not_wait_for_asr_and_finish_waits_for_tail` | PASS |
| `test_duplicate_upload_and_conflicting_bytes_or_metadata` | PASS |
| `test_client_cannot_assert_voice_trust[speaker_status-VERIFIED_USER]` | PASS |
| `test_client_cannot_assert_voice_trust[source_type-trusted_test_text]` | PASS |
| `test_client_cannot_assert_voice_trust[voice_verified-true]` | PASS |
| `test_unverified_upload_never_generates_fact` | PASS |
| `test_token_protects_all_data_and_text_claim_is_disabled` | PASS |
| `test_remote_without_configuration_fails_closed` | PASS |
| `test_wav_and_total_body_limits[7000001]` | PASS |
| `test_wav_and_total_body_limits[7100000]` | PASS |
| `test_chunked_body_cannot_bypass_size_cap` | PASS |
| `test_invalid_wav_missing_session_and_sequence` | PASS |
| `test_worker_timeout_recovers_same_id_without_repeating_final[asr]` | PASS |
| `test_worker_timeout_recovers_same_id_without_repeating_final[llm]` | PASS |
| `test_restart_resumes_persisted_accepted_job` | PASS |
| `test_worker_instance_lock_prevents_second_consumer` | PASS |
| `test_retry_budget_survives_restart` | PASS |
| `test_restart_after_llm_timeout_reuses_final_checkpoint` | PASS |
| `test_acknowledgement_after_commit_crash_does_not_spend_more_model_budget` | PASS |

JUnit: `local-diagnostics/wav_http_pytest.xml`.

Local recovery bundle after the HTTP commit: `local-diagnostics/baseline-freeze/fitcore-local-history.bundle`. Private WAV and DB files are excluded; database backups remain separate.
