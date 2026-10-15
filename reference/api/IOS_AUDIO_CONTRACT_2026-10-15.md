# Fitcore 音频与 iOS Mock 客户端交接契约 v0.1

> 当前完整WAV HTTP接口已落地：以[WAV HTTP API](WAV_HTTP_API_2026-10-15.md)为准。
> 使用 `/audio-jobs`，不使用本文早期 `/audio-chunks` 设计；没有实时ASR/VAD分段能力。

> 更新：Event Cursor、Finish Barrier与Review保护现已实现，实际请求字段及状态以
> [最新接口验收报告](EVENT_FINISH_REPORT_2026-10-15.md)为准；事件类型为大写，Finish使用完整WAV的last_sequence。
> 以下保留早期设计，其中audio-chunks、VAD、后台作业和推送事件尚未实现；不要照早期session_finished事件示例接入当前接口。

交接对象：罗鸿宇（iOS与部署），江振东（ASR/AI/Core）。日期：2026-10-15。
此文冻结下一层接口方向；下面明确区分已实现接口与待实现音频编排，不代表服务器已部署。

## 已实现，可立即联调

| 方法与路径 | 输入/输出 | 当前行为 |
|---|---|---|
| GET /health | status、model_provider | 进程健康，不代表外部AI可用 |
| POST /v1/sessions | {"session_id":"ios-demo-001"} | 201 Context；ID已有返回409，随后GET恢复；请客户端先持久化ID |
| GET /v1/sessions/{sid} | Context | version、active exercise、last weight、next plan |
| POST /v1/sessions/{sid}/utterances | UtteranceIn → UtteranceOut | 已有最终文本入口；Core执行去重、事务、Pending |
| GET /v1/sessions/{sid}/facts | FactRead[] | 当前有效事实快照；纠错后数值可改变 |
| GET /v1/sessions/{sid}/pending | PendingRead[] | 包含已处理项；客户端按status=open筛选 |
| POST /v1/sessions/{sid}/pending/{pid}/resolve | resolution_id、action、context_version；confirm_set须完整weight/reps | 人工confirm_set/dismiss，409冲突不可盲重试 |
| POST /v1/sessions/{sid}/end | UtteranceIn，transcript必须“今天到这里” | 通过现有语义Provider结束；不是音频刷包接口 |
| GET /v1/sessions/{sid}/review | ReviewRead | 总组/次数/训练量/事实/Pending；当前是统计，无AI评分字段 |

本地文本联调请求示例：

```json
{"utterance_id":"ios-demo-001-u0001","source_type":"trusted_test_text","speaker_status":"VERIFIED_USER","transcript":"卧推60公斤8个"}
```

真实ASR接入后由服务端签发authenticated_audio来源与speaker决策，客户端不能自证声纹验证。
当前没有公开部署认证；本地可信测试身份不代表已实现用户识别。
错误：HTTP422输入错误、404会话不存在、409冲突、503数据库失败；
最终文本接口还须检查HTTP200内decision：COMMIT、DEFER、REJECT、ERROR、DUPLICATE、STALE_CONTEXT、ID_CONFLICT。
ERROR/503重试同一utterance_id和完全相同payload。DEFER已入账为Pending，不换ID重发。
ID_CONFLICT须人工定位，不能通过换ID绕开。STALE_CONTEXT未写入，先刷新Context，明确重解析后同ID重试。
已持久化请求的指纹包含context_version；不要为网络重试修改这个字段。

## 音频编排接口（待实现；iOS可以按此制作网络Mock）

统一保持/v1/sessions命名，暂不提供/session/start别名或event-stream。

| 方法与路径 | 契约 |
|---|---|
| POST /v1/sessions/{sid}/audio-chunks | multipart音频+metadata；202持久化接收，不等于训练事实提交 |
| GET /v1/sessions/{sid}/events?after=0&limit=100 | 持久化事件增量查询；游标是会话内单调event_seq，和Context.version独立 |
| POST /v1/sessions/{sid}/finish | finish_id、last_chunk_seq；202进入draining；不丢掉尾包/正在处理的语句 |
| GET /v1/sessions/{sid}/review | 刷包完成后读取既有Review，版本随人工Pending处理更新 |

audio-chunks metadata：

```json
{"chunk_id":"ios-demo-001-c0000","chunk_seq":0,"start_ms":0,"end_ms":2000,"format":"wav","sample_rate":16000,"channels":1,"bits_per_sample":16,"sha256":"<文件字节SHA256>"}
```

音频块默认为2秒、无重叠独立PCM16 WAV；不足2秒尾包也上传。Mock发送预置音频，真实SDK解码后仍遵循同一契约。
该长度是初始工程参数，尚未验证最优延迟。start/end是同一录音时钟，不能使用网络到达时间。
每个块须连续时间、不重叠，最多256KiB、5秒；单会话初始上限30分钟，限额是待实现配置。
16kHz/mono/PCM16是上传标准；其他硬件格式在Gateway正确重采样，页面与Core不感知SDK。
块ID、序号、时间窗、SHA和文件在重试中固定；同ID同内容返回原接收结果，异内容409。
客户端保留未确认的块至服务端持久化ACK；成功ACK后是否删除由本地数据保留策略决定。
服务端对chunk_seq唯一约束，允许乱序到达，但只按连续序号处理；缺包不可悄悄跳过。
单个会话串行处理最终语句，防止乱序LLM响应覆盖Context。网络/模型可重试，Core事务不跨网络请求持锁。

## 块、语句与最终转写

音频块仅是传输单位，**不等于一句话**。服务端缓存连续块，用VAD/停顿边界或finish关闭语句，
静音阈值初始800ms、最长语句15秒作为待校准配置；无VAD时可先在预置音频清单显式标注边界，
这是Mock输入边界，不冒充真实ASR或真实VAD。超过最大时长切断须记录reason=max_duration，不能静默拼接语义。
一块可包含多句，一句也可跨块：用[start_ms,end_ms)及chunk引用范围标识语句，而非仅用chunk_id。
官方当前适配器是非SSE整段文件ASR，最终响应output.text；sentence_end=false时拒绝提交。
当前没有滚动ASR或VAD实现。preview文本只展示，不进Fact Engine；仅final提交一次。
utterance_id在语句关闭时由服务端分配并持久化，格式建议sid-u000001（全长<=120字符），
同一语句范围重试保持ID；时间重叠或ASR措辞相同不能单凭文本去重，不同训练组可能说相同句子。
一次成功ASR的final文本与来源决策必须持久化冻结，LLM超时重试不再次ASR改变文本。
已提交后ASR修订须作为新纠错输入，不能覆盖同utterance_id，不能变成新训练组。
ASR超时没有final，不调用LLM；LLM超时保持final等待重试；两者均不得推进Context或产生训练事实。
单环节自动重试最多一次、退避1秒；仍失败发送明确failed事件，交用户重试，不无限阻塞。
必须保存重试次数与幂等标识；当前离线管线验证固定ID重试，持久化音频作业队列尚待实现。

## 事件游标与客户端更新

```json
{"events":[{"event_seq":12,"event_id":"ios-demo-001-e000012","type":"utterance_final","utterance_id":"ios-demo-001-u000002","start_ms":2000,"end_ms":6400,"payload":{"text":"同样重量7个，有点重，下一组减5公斤"}}],"next_cursor":12,"has_more":false}
```

事件种类：chunk_received、transcript_preview、utterance_final、core_result、pending_created、
fact_updated、processing_failed、session_draining、session_finished。
事件event_seq与持久化outbox在同一事务生成；Core提交后不能丢事件。实现时须补事务outbox，当前尚无事件表。
core_result.payload使用现有UtteranceOut，附Context version；操作映射到卡片，不引入另一个事实来源。
纠错/人工Pending事件发出后客户端刷新facts与review快照，以fact id替换卡片，不增加组数。
客户端只在应用完整事件页后保存next_cursor；重复事件按event_id忽略，断线恢复同游标。
只查询event_seq>after，按序返回；空页next_cursor保持after。每1秒轮询，前台暂停时停止。
cursor无效/超过服务端最大值返回409，明确请求快照恢复，不能悄悄推进游标。
事件不提前裁剪：初版会话全程保留，不引入无法恢复的游标过期行为。

## finish刷包

```json
{"finish_id":"ios-demo-001-finish-001","last_chunk_seq":17}
```

空音频会话last_chunk_seq=-1。服务端状态：accepting → draining → finished；Core的active/ended独立。
客户端停止录音→上传不足整块的尾包→确认所有ACK→发送finish。客户端done只能在session_finished事件之后。
finish声明不可变，重复同finish_id及last_chunk_seq返回同结果；修改边界返回409。
进入draining后仍接收边界内缺失块及重复块，拒绝边界之后新块，缺序号返回missing_chunk_seqs。
服务端等待0..last_chunk_seq完整、语句final化、ASR和LLM终态、Core事务完成，然后提交SESSION_END，
发布session_finished，payload包含review_version、pending_count、failed_utterance_ids和complete/degraded。
存在未重试完的ASR/LLM失败：保持draining并提供blocked_on，不返回虚假的完整复盘；
用户明确放弃失败项后才以degraded结束。Pending可留给人工审核，不等于网络失败，结束后仍可按现有API处理。
客户端等待30秒后显示“仍在处理”及重试/恢复选项，不发送新的finish_id；服务端deadline初始180秒。
当前/end没有这些保证，不得当作finish；音频编排落地前仅适合明确文本测试。

## 性能与联调验收

分别记录录音时长、客户端上传、分段等待、服务端到ASR的body发送、ASR请求总耗时、LLM请求耗时、
Core执行与SQLite事务、事件轮询等待；ASR请求耗时包含上游上传，报告总时间时不要重复相加。
usage.duration是服务端音频时长字段，不是推理时间；没有测量的环节写未测。
当前真实全段ASR→LLM串行，目标5–8秒尚未验收，不能将模型单段耗时当成端到端延迟。

交接验收：乱序/缺包恢复、重复块不重复ASR或记账、一块多句/一句多块、超时同ID重试、
游标重连、纠错替换、尾包刷完才结束、失败不假装完成。客户端可先实现该契约Mock，
服务端音频路由、VAD、事件outbox、持久化作业和finish屏障是接下来的实现任务。
