# Event Cursor + Finish Barrier 交付与验收

日期：2026-10-15；按Event Cursor先完成验收、随后Finish Barrier的顺序开发。
基线88 passed、1 skipped。

## 分阶段测试与代码范围

- Event Cursor先独立运行全量：99 passed、1 skipped、1 warning，17.09秒。
  见[第一阶段记录](EVENT_CURSOR_REPORT_2026-10-15.md)。
- Finish专项：12 passed、1 warning，9.96秒。
- 最终全量：**111 passed、1 skipped、1 warning，16.95秒**，原有88项保留。
  skip是默认opt-in真实LLM pytest；警告为既有Starlette/httpx测试客户端弃用提示。

| 修改文件 | 内容 |
|---|---|
| app/events.py（新增） | 事务事件追加、稳定去重键、会话内单调游标、快照分页查询 |
| app/finish.py（新增） | Finish请求、固定范围/清单、短事务关闭入口、完成快照与恢复状态 |
| app/db.py | 增量创建session_events与session_finishes |
| app/service.py | 提交前事件钩子、Pending确认事件；Finish期间阻止旁路文本写入和提前SESSION_END |
| app/audio/orchestrator.py | update_job增加原子事件钩子；enqueue原有事务内检查Finish接收限制 |
| app/main.py | events与finish API；音频Review未完成保护；旧/end入口保护 |
| tests/test_events.py、tests/test_finish.py（新增） | 11项事件、12项Finish验收 |
| README、交接契约、本文及第一阶段记录 | 当前接口与运行边界 |

未重写Fact Engine、Audio Orchestrator流程或ASR Provider，未变更Nova提示词。
Provider继续为`x-model-provider: dashscope_ audio`，内部空格不变，既有回归通过。
未开发iOS、AWS、S3、声纹、非语言事件或复杂流式识别。

## 数据表与一致性

session_events：会话外键、event_seq、稳定event_key、type、utterance_id、payload_json、时间。
PRIMARY KEY(session_id,event_seq)，UNIQUE(session_id,event_key)。从1开始，0为初始游标。
没有历史删除/裁剪，也没有为旧数据库未记录过的操作自动回填事件。
Core的事实、纠错审计、输入、Pending、人工确认与对应业务事件共用同一SQLite事务。
audio_jobs.final_text和TRANSCRIPT_FINAL共用同一事务；发生写失败一起回滚。
重试/提交后崩溃复用既有Core幂等机制，不产生第二份业务事件。
PROCESSING_ERROR按utterance和阶段去重，保留第一次失败事件，不把每次网络重试都当成新业务事件。

session_finishes：session_id主键、finish_id、last_sequence、state、manifest_json、review_json、创建/关闭/完成时间。
每Session只允许一个稳定finish_id和范围；修改ID或last_sequence返回409。
manifest固定每条已接受任务的utterance_id、sequence、audio_sha256；状态允许继续推进，不允许改变任务身份/音频。
完成时，Session结束、版本更新、Review快照及finished状态在同一事务提交；失败则全部回滚。

## 当前API（全部位于/v1/sessions）

### GET /v1/sessions/{sid}/events?after=0&limit=100

返回events、next_cursor、has_more；每事件含event_seq、event_id、type、utterance_id、payload、created_at。
event_seq是会话内持久化顺序，和Context.version独立；仅返回大于after的事件。
重复查询不修改游标，客户端保存已应用的next_cursor即可恢复；limit范围1..100。
负游标/非法limit为422，游标超前为409，会话不存在404。

五类事件：TRANSCRIPT_FINAL、FACT_COMMITTED、OPERATION_DEFERRED、INPUT_REJECTED、PROCESSING_ERROR。
FACT_COMMITTED包含正式组/纠错/训练备注的Core操作；纯计划、切动作和Session结束不伪装成已完成组。
Pending人工确认产生事实事件，人工丢弃产生INPUT_REJECTED；纠错/确认后按fact id刷新事实快照。
错误事件是历史记录，后续成功会新增事实事件，不删除之前的错误。

### POST /v1/sessions/{sid}/finish

```json
{"finish_id":"finish-001","last_sequence":1}
```

last_sequence为完整WAV片段的最终序号，不是网络分片号；空会话填-1。
客户端须先停止产生新片段，声明真正尾段；不能仅凭服务器当前收到的最大序号推断尾段已到。

- **409 awaiting_audio**：声明范围内还有未接收的片段，返回missing_sequences与missing_count，complete=false、acceptance_closed=false。
  这是不满足前置条件的Finish请求，尚未接受关闭，不会假装尾段已刷完。finish_id及声明范围已持久化；
  仅允许补齐该范围内的缺失输入，范围外新片段拒绝。补齐后重复相同Finish请求。
- **202 draining**：范围内片段已全部入库。在同一BEGIN IMMEDIATE事务中固定已接受清单并关闭新音频接收。
  所有新任务拒绝，即使序号位于旧范围也不能换ID；同ID/内容的幂等重传返回原任务。
  已在ASR/LLM处理的任务继续运行，Session业务状态保持active，不被提前关闭。
  返回unfinished、error_type、missing_count、complete=false、review=null，失败不会冒充完成。
- **200 finished**：全部已接受任务status=done且清单一致，原子结束Session并保存Review快照。
  重复请求返回相同完成结果，不增加Context版本，不重复训练事实或业务事件。

声明范围不能小于已接受的最大序号；否则409 FINISH_RANGE_EXCLUDES_ACCEPTED_AUDIO，不能静默丢尾段。
数据库失败返回503 FINISH_DATABASE_ERROR_RETRY_SAME_ID；关闭入口与完成快照不会部分生效。
pending_count可以非零：语义不确定项已处理为Pending，Review明确展示待审核数量，不猜测成事实。
网络失败/超时则任务尚未done，必须恢复后再完成Finish。

### GET /v1/sessions/{sid}/finish

只读状态，未请求时404。ready_to_finalize表示任务已全部完成但还需重复POST同一Finish提交最终关闭。
没有后台调度器：调用者负责继续运行Orchestrator，恢复失败任务，然后重复POST。
Finish不会在HTTP请求中等待网络AI，也不会持有跨ASR/LLM调用的SQLite事务或争用音频Session锁。

### GET /v1/sessions/{sid}/review

音频会话未Finish或尚未完成：409明确未完成状态，不返回伪完整Review。
完成后200返回当前Review；文本测试会话保持原接口行为。
Finish内的review是第一次完成时的不可变快照；后续人工Pending处理可更新GET /review及其context_version。
Review状态检查与数据读取共用同一只读快照，避免检查与读取之间插入新任务。

旧/end不能用于音频会话。口述SESSION_END也不会提前关闭仍有尾段的音频会话，保守转Pending。
Finish期间未经已接受音频任务绑定的文本写入被拒绝，避免旁路新增组。
Finish完成没有另加第六类事件，客户端通过Finish响应/状态接口判断完成。
本轮仍未增加音频HTTP上传接口；完整WAV通过既有Orchestrator.enqueue或本地脚本入队。

## 离线故障与恢复验收

Event Cursor 11项：分页、重复读、快照/重启一致性、4种非法游标输入、会话隔离、
事实事件事务失败回滚、Pending确认事务失败及重试、FINAL与事件事务失败恢复、重复超时事件去重、提交后崩溃不重复事件。

Finish 12项：关闭入口与重复Finish/重启、缺尾段补齐恢复、拒绝遗漏已接收尾段、
ASR/LLM两类超时恢复、ASR/LLM两种在途处理、Finish完成事务失败回滚、
旧/end和文本旁路保护、口述结束不丢尾段、入队/Finish并发、空会话幂等结束。
原有真实子进程os._exit恢复测试继续通过。

这些测试使用本地真实SQLite与FastAPI TestClient，AI由固定适配器或故障注入模拟；不是压测或AI识别准确率证明。

## 真实服务补充验收（含一次真实超时）

使用原有已授权真人WAV，在新Session events-finish-acceptance-001实际调用赛事服务：

| 步骤 | 实测结果 |
|---|---|
| 官方ASR | HTTP200，4816ms，FINAL“卧推60公斤做了8个。” |
| 首次Nova Pro | NETWORK_TIMEOUT，32598ms，无HTTP状态；不是Mock故障 |
| 超时后数据库 | FINAL持久化、retry_llm、Context.version=0、正式事实0条 |
| 超时后本地Finish API | 202 draining，review=null，unfinished含retry_llm/NETWORK_TIMEOUT |
| 超时后本地Review API | 409；事件只有TRANSCRIPT_FINAL与PROCESSING_ERROR |
| 新Python进程恢复同一任务 | 只重试LLM，HTTP200、5562ms，Schema通过 |
| 恢复后数据库 | ASR尝试仍1次，Final阶段派发2次，仅1条bench_press 60kg×8事实 |
| 重复同一Finish | 200 finished，Review为1组、8次、480kg·次，Pending=0 |
| 重启后重复Finish/事件查询 | 返回相同完成快照和稳定事件；after=2只返回最后一条事实事件 |

真实事件顺序与游标：1 TRANSCRIPT_FINAL → 2 PROCESSING_ERROR → 3 FACT_COMMITTED。
SQLite独立查询确认没有重复业务事实。保留真实超时，不声称服务长期稳定。
ASR/LLM调用是真实网络；上述API HTTP状态来自本机TestClient，不代表外网部署。
本次来源仍是已授权本地录音的人工可信测试假设，不代表声纹验证。

本地私有验收记录：local-diagnostics/event-finish-live-before.json、event-finish-live-after.json；
数据库local-diagnostics/final-processor/core.db。未输出密钥或出口IP，未创建云资源。

## 未验证能力

未验证外网客户端、生产并发/压测、多主机或网络文件系统、Linux进程锁分支、复杂ASR流式边界。
只有既有一条真人语音的真实恢复验收，不代表多动作/多人/噪声环境准确率已达标。
没有自动后台唤醒恢复进程，没有实时推送；事件采用轮询，恢复与Finish最终提交由调用者驱动。
