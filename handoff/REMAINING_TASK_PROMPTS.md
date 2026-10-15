# 其余11项交接Prompt全文

先将整个源码ZIP解压，在Codex中打开根目录。首次先用handoff/FIRST_RUN_PROMPT.md；以下每次只复制执行一项，不要同时改同一份工程。当前进度以handoff/CURRENT_STATUS.md为准。


---

## LHY-02


# LHY-02 独立执行 Prompt：录音豆 SDK 适配准备

请接手 Fitcore 的 LHY-02，只做本任务必要的本地工程工作，完成后交付可在另一台 Mac 独立打开的完整 ZIP。不要同时启动其他任务修改同一工程。

## 先读与工作边界

在解压根目录依次阅读 `README.md`、`handoff/CURRENT_STATUS.md`、`handoff/KNOWN_API_GAPS.md`、`reference/task-package/tasks/LHY-02.md`、`reference/api/WAV_HTTP_API_2026-10-15.md`，再读 `reference/task-package/docs/02_IOS_API_AND_MODULES.md`、`docs/LHY-01-LOCAL-HANDOFF.md` 及现有硬件接入文档。旧 `docs/lhy-13tasks-status-2026-10-15.md` 只作历史基线；冲突以当前交接状态和源码为准。

先说明理解、最小改动、当前目录与版本；若有 Git 元数据，只读确认仓库/分支，沿用当前分支；没有则如实说明。不要初始化 Git、恢复旧提交覆盖当前源码、拉取、推送、创建 PR、操作 AWS 或调用公网/付费服务。新授权到来前只做本地 fixture。保留今日、历史、AI 分析、我的四页布局和现有 Mock。

## 已有与目标

- 基线为 0.3.1 (8)。LHY-01 已实现「我的→设置→手机 WAV 采集」，输出 `UUID.wav` 与 `UUID.metadata.json`，停止后等待完成回调，格式为 16kHz/mono/PCM16 RIFF WAV、≤7,000,000 字节；不要重写这条链路。
- 物理 iPhone 尚未验收，真人语料为 0；目前没有 soundcore 录音豆和充电盒。iPhone 麦克风或模拟器结果不能算录音豆验收。
- 目标是隔离 SoundcoreInputAdapter 的厂商回调、状态和真实编码转换边界，复用已有文件校验和上层输入约定。没有硬件时可验收适配准备，不能宣称硬件闭环完成。

## 最小实施

1. 先检查 `ios/Fitcore/Services/Recorder/`、`Services/Training/TrainingSessionConnection.swift`、`Core/Audio/` 及当前工程配置。用现有边界接入，避免另造录音系统或改四页架构。
2. 当前 ZIP 不含厂商 SDK。历史资料指出两套静态 XCFramework 为 `SoundcoreWorkAppleSDK`、`module_spplinkKit`；必须另行取得用户授权与合法 SDK 文件后才迁移。未提供前不要下载、复制其他目录的 SDK 或假造 SDK API，可完成独立协议、明确未接入态和本地模拟适配器。
3. 建立与现有状态协调的连接、开始、接收、停止等待尾包、完成、断线/失败/取消过程；重复停止与迟到回调不能产生重复文件或训练事实。记录音频顺序、来源、设备时间及合并策略，区分设备录音停止、尾包收齐、云端 Job 完成三种状态。
4. 历史资料中的输出是约 20ms 的裸 Opus 包，绝不是 WAV。确认采样率、声道、帧边界、解码器与重采样策略后才能形成 PCM16 WAV；禁止仅改扩展名或加 WAV 头冒充解码。解码依赖未获授权或资料不足时，保留阻断与接口，不输出假有效音频。
5. 顶层 pause/resume 有前置条件；低层出现 `startRecord` 符号不证明 D3200 支持新建录音，也不证明 stop/终结/尾包语义。把这几个问题列入厂商确认清单；不能从符号自行承诺支持。
6. 模拟输入显式 `isSimulated`/Mock，来源与 iPhone 分开。只有成功完成并通过现有 WAV 校验的真实文件才能交给上层；失去设备、取消或未收齐尾包不得自动完成训练组。

## 验证与真实阻断

用本地模拟回调验证连接失败、开始失败、正常停止等待尾包、断线、乱序/重复/迟到回调及取消；如果没有解码器，只验证协议与状态，明确没有验证 Opus→WAV。跑受影响的离线测试、`python3 -B scripts/verify.py` 和可用的 `Fitcore-Mock` 模拟器构建，记录命令与真实结果。保留 LHY-01 测试通过证据；未运行的检查说明原因。

硬件、盒子、厂商鉴权/授权、真实 SDK、D3200 录音与 stop 支持、原始包/尾包时序、物理 iPhone 均是真实阻断。后端已部署，但 HTTP Token 不等于模型 Key；本任务不联调云端。默认服务端来源不可信，禁止伪造 `VERIFIED_USER` 或声纹结果。

## 独立 ZIP 交付条件

交付完整当前源码、Xcode 工程、资源、离线 fixture/测试、运行说明及 LHY-02 状态/阻断/验收清单；没有 SDK 时 ZIP 应能在 Mock 路径打开构建，明确真实 SDK 未链接。若后续获得授权引入 SDK，记录许可和可分发边界，不默认放进转交 ZIP。排除 `.git`、构建缓存、个人签名、`Local.xcconfig`、Token、模型 Key、私人 WAV 与数据库。提供 SHA-256、文件清单、实际检查记录；不伪造 Commit/PR、硬件视频或验收。后续主线优先 LHY-03→LHY-04→LHY-08；合并其他任务时只选择相关差异，不整包覆盖更新工程。


---

## LHY-03


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


---

## LHY-04


# LHY-04 独立执行 Prompt：训练状态与复盘 UI

请接手 Fitcore 的 LHY-04，只在现有四页布局和训练界面内接入可信的状态呈现，完成后交付可在另一台 Mac 独立打开的完整 ZIP。推荐顺序 LHY-03→LHY-04→LHY-08；不要同时开多个任务修改同一工程。

## 先读与工作边界

在解压根目录依次阅读 `README.md`、`handoff/CURRENT_STATUS.md`、`handoff/KNOWN_API_GAPS.md`、`reference/task-package/tasks/LHY-04.md`、`reference/api/WAV_HTTP_API_2026-10-15.md`，再读 `reference/task-package/docs/02_IOS_API_AND_MODULES.md`、`docs/LHY-01-LOCAL-HANDOFF.md`、若存在则读LHY-03的新交付说明。旧 `docs/lhy-13tasks-status-2026-10-15.md` 只作历史基线。

先说明理解、最小改动、当前目录与版本；有Git时只读确认仓库/分支并沿用当前分支，没有则说明。不要初始化Git、恢复旧提交覆盖源码、拉取/推送/创建PR、操作AWS或调用公网/付费服务。默认离线fixture；保留今日、历史、AI分析、我的四页布局与明确Mock路径。

## 已有与目标

- 0.3.1 (8) 已有训练、复盘、历史、问答卡片及Mock状态机；LHY-01在设置内完成手机WAV本地采集，输出UUID配对文件，停止后等待录音完成。不要重写录音或整体页面。物理iPhone未验收，真人样本0，无录音豆与盒子。
- 旧 `BackendClient/CloudHistoryClient/TrainingAnalysisService` 不是新WAV合同。先检查当前工作副本是否已经整合LHY-03；未整合时先完成UI状态和fixture注入，明确依赖，不能只换URL或自行造一个第二套客户端。
- 目标是训练前/中/结束/复盘可清楚显示输入、上传、处理、正式Facts、Pending、事件和Finish状态，候选识别结果不得冒充正式训练记录。

## 最小实施

1. 检查 `App/AppStore.swift`、`Features/Training/LiveWorkoutView.swift`、`Features/Review/WorkoutReviewView.swift` 和现有模型；使用已有局部组件/状态边界，避免大改AppStore或增加无必要的导航。
2. 接LHY-03状态：创建session、WAV上传202、Job排队/处理中/done/失败、Facts/Pending/Events刷新、Finish/Review。输入标明iPhone、soundcore或Mock，未验证的身份与来源不得显示成“已认证”。本地录音同意不代表云处理同意，用户未批准上传前只演示fixture。
3. 正式完成组只来自Facts/Review，并按真实fact/event身份防重复。转写、COMMIT候选或done均不直接+1；DEFER保留Pending原因，REJECT显示失败/原因，done但无事实允许显示“处理完成，暂无正式记录”。
4. Facts与Pending分区。正常服务端source trust默认false，SOURCE_UNCERTAIN需显示来源待确认，声纹`not_performed`。人工confirm可能409 SOURCE_NOT_VERIFIED，应保留Pending并说明来源尚未验证；禁止UI伪造MATCH/VERIFIED_USER、写可信字段或绕过确认闸门。
5. 事件按合同使用持久化cursor和范围过滤，刷新可取消、不重复、不跨session污染；缺少明确事件结构时使用标注为合成的fixture并记录字段缺口。
6. 结束训练先等待录音完成/尾包、上传接受，再等云端finish。202 draining展示继续处理中，409 awaiting_audio展示缺段与可恢复操作，Review409不呈现成功。只有服务端Review可用后更新正式云复盘；不要简单删除当前“真实设备未就绪”保护后继续本地生成复盘。
7. 用现有交互表达断网、超时、取消、401/403、重试耗尽、来源待确认、无事实、可复盘但仍有Pending。建议/问答失败不能阻断事实或Review。保留Mock脚本，Mock与真实状态有明确标识。

## 验证与真实阻断

以离线可重放场景验证：上传202不记账；Job done+DEFER仍Pending；confirm409保持Pending；重复事件不增组；切换会话旧响应失效；Finish202→等待→Review、Finish409缺段、Review409；断网和Mock恢复。检查四页及现有Mock基本流程，保留LHY-01录音入口。跑受影响状态测试、`python3 -B scripts/verify.py`、可用的 `Fitcore-Mock` 模拟器构建，截图/录屏仅标注实际运行环境。

真实API联调、有效HTTP Token、物理iPhone、录音豆/盒子、AUTH-01与声纹接口仍是外部依赖。后端已部署，HTTP Token与模型Key不同；未经后续用户批准不进行远程或付费调用。若LHY-03尚未交付，只声明本地UI状态/fixture完成，不声称真实链路已接通。

## 独立 ZIP 交付条件

交付完整当前App、Xcode工程/资源、局部UI变更、场景fixture/测试、运行说明及LHY-04状态/缺口/场景证据。包含已整合的LHY-03时记录准确来源与实际检查结果；未整合时明确如何注入fixture和后续接点。排除 `.git`、缓存、SDK、个人签名、`Local.xcconfig`、Token/模型Key、私人WAV/数据库；提供清单与SHA-256，不编造Commit/PR或物理iPhone验收。交给LHY-08时说明状态来源和恢复路径，禁止以较旧ZIP整包覆盖新成果。


---

## LHY-05


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


---

## LHY-06


# LHY-06 独立执行 Prompt：声纹授权与撤销交互

请接手Fitcore的LHY-06，先交付可以验收的本地授权/撤销交互和安全状态映射。当前没有声纹后端合同，不能声称真实注册、验证或远程撤销已完成。完成后交付另一台Mac能独立打开的完整ZIP；只做本任务，不与其他任务同时改同一工程。

## 先读与工作边界

在解压根目录依次阅读 `README.md`、`handoff/CURRENT_STATUS.md`、`handoff/KNOWN_API_GAPS.md`、`reference/task-package/tasks/LHY-06.md`、`reference/api/WAV_HTTP_API_2026-10-15.md`，再读 `reference/task-package/docs/02_IOS_API_AND_MODULES.md`、`docs/LHY-01-LOCAL-HANDOFF.md` 与现有授权相关实现。旧 `docs/lhy-13tasks-status-2026-10-15.md` 只作历史基线。

先说明理解、最小本地范围、当前目录与版本；有Git时只读确认仓库/分支并沿用，没有则说明。不要初始化Git、恢复旧提交覆盖源码、拉取/推送/创建PR、操作AWS、公网或付费调用。保留四页布局、Mock和原手机录音。默认未启用真实声纹功能；不能从任务标题推断用户已同意采集生物特征。

## 已有与目标

- 基线0.3.1 (8)，LHY-01已有本地手机WAV与UUID配对metadata、16kHz/mono/PCM16≤7,000,000字节、停止完成等待；不要重写，也不要把现有录音自动转作声纹样本。物理iPhone未验收，真人样本0，无录音豆/盒子。
- 后端已部署，但稳定WAV接口没有声纹注册/匹配/撤销API。正常 `speaker_verification=not_performed`、source trust默认false。HTTP Token不同于模型Key，不提供声纹能力。
- 目标是明确的注册授权、未录入/不可用、等待结果、撤销与样本清理原型；MATCH/UNKNOWN/NON_MATCH仅作为待后端确认的结果语义，不作为伪造服务合同。

## 最小实施

1. 复用设置/我的现有局部入口；真实功能默认不可用或Feature Flag关闭，文案说明“声纹能力尚未接入”。演示状态标Mock，与真实训练来源判定隔离。
2. 独立记录用途、授权版本、同意/拒绝/撤销、时间、匿名标识和本机处理状态；声纹授权与本机录音、团队复核、云端处理分别记录。没有明确声纹采集授权时不录样本、不生成模板、不上传。
3. 如展示结果映射，用测试fixture明确覆盖未录入/UNKNOWN/NON_MATCH/MATCH，但fixture不得写入生产可信身份、解除Pending或更改正式Facts。真实路径只接受后续服务端经过验证的结果，UI不能自行构造MATCH、VERIFIED_USER或voice_verified。
4. 撤销立即阻止本机相应用途继续使用；记录本地样本清理和远程撤销“未提交/待后端支持”等状态。无后端接口时不能显示“云端已撤销”或“所有副本已删除”。不新增自创 `/enroll`、`/verify`、`/revoke` HTTP路由或用客户端相似度阈值冒充声纹服务。
5. 明确未知来源不能自动视为可信。SOURCE_UNCERTAIN仍Pending，人工confirm可能409 SOURCE_NOT_VERIFIED；不能开服务端可信测试开关或发送speaker_status/source_type等非法字段绕过。
6. 整理后端待提供合同清单：注册与撤销鉴权、样本授权/保留/删除、任务与匹配结果字段、版本/置信与错误语义、UNKNOWN处理、撤销传播证据。只写缺口，不创建服务实现。
7. 删除遵循单个明确路径规则，不做递归/通配/循环清理；需要清理多个真实文件先让用户明确批准范围。默认测试只用临时合成记录，不读取私人声音或身份材料。

## 验证与真实阻断

本地测试未同意/拒绝/撤销/到期路径、不可用态、Mock标识、UNKNOWN/NON_MATCH不升级可信、Mock MATCH不流入Facts/上传身份、撤销后不能继续使用、重启恢复及远程撤销未完成提示。跑受影响离线测试、`python3 -B scripts/verify.py` 和可用的 `Fitcore-Mock` 模拟器构建；记录实际结果及未检查原因。

F02/来源鉴权合同、真实声纹模型、授权样本、物理iPhone和远程撤销服务是实际阻断。后续真实联调和任何付费调用需用户明确批准；不阻挡优先LHY-03→04→08主链。不能把受控本人测试或HTTP认证写成说话人验证。

## 独立 ZIP 交付条件

ZIP含完整当前App/Xcode工程/资源、局部原型、合成fixture/测试、功能默认值、运行说明、后端问题清单、LHY-06本地已验收与真实阻断。排除 `.git`、缓存、SDK、签名、`Local.xcconfig`、Token/模型Key、私人WAV/声纹模板/授权登记/数据库；提供文件清单与SHA-256。不编造Commit/PR、样本、声纹准确率或真机验收。未来整合只应用相关差异，不以旧ZIP覆盖当前新代码。


---

## LHY-07


# LHY-07 独立执行 Prompt：训练建议与解释 UI

请接手Fitcore的LHY-07，复用现有AI分析/问答卡片，完成来源明确的本地建议展示、不可用态和错误降级，交付另一台Mac能独立打开的完整ZIP。当前没有正式问答/建议API，不要自建服务或阻挡LHY-03→04→08。只做本任务，不同时让其他任务改同一工程。

## 先读与工作边界

在解压根目录依次阅读 `README.md`、`handoff/CURRENT_STATUS.md`、`handoff/KNOWN_API_GAPS.md`、`reference/task-package/tasks/LHY-07.md`、`reference/api/WAV_HTTP_API_2026-10-15.md`，再读 `reference/task-package/docs/02_IOS_API_AND_MODULES.md`、`docs/LHY-01-LOCAL-HANDOFF.md` 与当前AI分析/问答实现。旧 `docs/lhy-13tasks-status-2026-10-15.md` 只作历史基线。

先报告理解、最小改动、当前目录与版本；有Git时只读确认仓库/分支并沿用，没有则说明。不要初始化Git、恢复旧提交覆盖源码、拉取/推送/创建PR、操作AWS或访问公网/付费模型。保留今日、历史、AI分析、我的四页布局与明确Mock；不重写训练或录音架构。

## 已有与目标

- 基线0.3.1 (8)；已有问答/分析/建议Mock卡片和旧文字模型基础。LHY-01已提供设置内手机WAV本地采集与配对文件，停止后等待完成；物理iPhone未验收，真人样本0，无录音豆/盒子。
- 旧 `TrainingAnalysisService/BackendClient/CloudHistoryClient` 不能只改URL接新WAV合同。稳定Review提供事实统计，不等于AI建议、问答或解释服务。
- 目标是保留现有布局，区分正式事实、建议、证据/来源、演示数据与未上线能力；建议失败不能阻断记录、Finish或Review。

## 最小实施

1. 先检查 `Features/Review/WorkoutReviewView.swift`、`Features/Training/LiveWorkoutView.swift`、现有模型/fixture与AppStore接点，优先局部改文案、状态和组件，避免新增导航或重复服务。
2. 正式Facts/Review只读展示；AI建议分区，带明确数据来源、适用时间和证据引用（仅真实存在的ID/内容）。缺证据时如实说明，不能从转写或建议创建完成组、回写事实、伪造训练效果。
3. 真实问答/建议接口未提供时，入口呈现“尚未接入”或用户明确选择的Mock演示。静态建议标“演示建议”，不显示“云端已分析”。不发明新HTTP路由、供应商请求或伪造返回结构为正式合同。
4. 本地fixture覆盖加载、成功、空结果、超时/失败、不可用、缺证据与反馈确认状态。建议失败或重试不触发事实重算、重复上传、Finish失败或Review丢失；训练主链可继续。
5. 解释展开/反馈入口只在当前范围内表达本地状态；没有反馈后端时不宣称已发送给团队。不要发送消息、遥测或上传私人语音/转写。
6. 声音来源与训练事实来源继续明确：默认source trust=false，SOURCE_UNCERTAIN可Pending，confirm可能409 SOURCE_NOT_VERIFIED；声纹未执行，不能用“AI认为是本人”解除来源闸门。
7. 列出后端待提供的最小合同问题：建议/问答是否独立任务、请求上下文/事实版本、输出与证据字段、权限/预算、取消/错误/重试语义、反馈接收。保留扩展接点，不实现未授权服务或新的客户端直连模型Key入口。

## 验证与真实阻断

本地验证：建议与Facts分离；不可用态可理解；Mock来源可见；建议失败/空结果/缺证据不影响记录和Review；重复加载无事实副作用；反馈只呈现真实本地状态。跑受影响离线状态测试、`python3 -B scripts/verify.py`、可用的 `Fitcore-Mock` 模拟器构建，并回归四页与现有Mock；截图/录屏明确是模拟器还是物理设备。

F03/F04/F05建议/问答/解释合同与服务、远程权限及费用授权是真实阻断。后端已部署不表示这些接口存在；HTTP Token不同于模型Key，ZIP没有私密配置。后续用户明确批准后才做真实API联调；本轮仅声明本地UI/fixture已验收，不声称AI能力已上线。

## 独立 ZIP 交付条件

ZIP含完整当前App/Xcode工程/资源、局部UI与fixture/测试、运行步骤、默认不可用/Mock说明、后端缺口与LHY-07验收记录；保持不需要远程凭据即可演示。排除 `.git`、缓存、SDK、签名、`Local.xcconfig`、Token/模型Key、私人WAV/转写/数据库；提供清单与SHA-256，不编造Commit/PR、真实建议证据或真机验收。后续只按相关差异整合，不用较旧ZIP覆盖更新工程。


---

## LHY-08


# LHY-08 独立执行 Prompt：iOS 集成与完整交付

请接手Fitcore的LHY-08，在当前工作副本整合已完成的手机WAV、HTTP客户端、训练UI与Review，交付可跨Mac重现的完整ZIP和真实验收记录。按LHY-03→LHY-04→LHY-08推进，不同时把多个独立任务开在同一工程。没有硬件/授权时先完成可验收的本地集成，不虚报物理iPhone或soundcore完成。

## 先读与工作边界

在解压根目录依次阅读 `README.md`、`handoff/CURRENT_STATUS.md`、`handoff/KNOWN_API_GAPS.md`、`reference/task-package/tasks/LHY-08.md`、`reference/api/WAV_HTTP_API_2026-10-15.md`，再读 `reference/task-package/docs/02_IOS_API_AND_MODULES.md`、`docs/LHY-01-LOCAL-HANDOFF.md` 以及实际存在的LHY-02/03/04新交付记录。旧 `docs/lhy-13tasks-status-2026-10-15.md` 仅是历史基线，不能代替当前成果。

先报告理解、现有依赖完成度、最小集成范围、当前目录与版本；有Git元数据时只读确认仓库/分支并沿用，没有则如实记录。不要初始化Git、恢复旧提交覆盖源码、拉取/推送/创建PR、操作AWS、公网或付费调用。默认全部本地fixture；真实联调、模型费用、私人音频上传和SDK迁移均须后续用户明确批准。保留四页布局、现有Mock及设置内录音。

## 已有与目标

- 基线0.3.1 (8)，LHY-01与D01软件已本地实现和验证。手机采集在「我的→设置→手机WAV采集」，输出 `UUID.wav`/`UUID.metadata.json`，16kHz/mono/PCM16、≤7,000,000字节，停止等待完成。不要重写或用旧版本覆盖。
- 物理iPhone没有验收，真人样本0，无soundcore录音豆与充电盒，SDK不在ZIP。当前包里的旧网络客户端与本地复盘不能充当新云端链路。
- 集成目标是同一源码快照内完成：标准文件→创建session→multipart上传→Job→Facts/Pending/Events→Finish/Review，支持恢复与明确降级。LHY-06/07缺服务不应阻挡主链。

## 最小实施

1. 先核对当前源码中LHY-03/04的实际状态、DTO与测试；如收到其他任务ZIP，先比对文件和源码指纹，只合入相关差异，保留本副本更新的LHY-01/D01及四页。不要整包覆盖，不把未收到的模块写成已整合。
2. 复用LHY-01有效原文件、稳定utterance_id/哈希；同session sequence从0连续。重试复用ID、序号、字节和来源。multipart只用合同字段，不走旧文本/audio-chunks接口；手机文件不能冒充soundcore。
3. 绑定录音完成与上传生命周期，完成回调前不校验/上传；取消、后台/中断、会话切换后的旧回调不污染新会话。若后续接硬件，设备stop/尾包收齐与云端draining分别等待，不能用硬件完成信号直接进入Review。
4. 上传202仅接受，Job done仍看COMMIT/DEFER/REJECT，正式记录仅Facts/Review。默认source trust=false，SOURCE_UNCERTAIN→Pending、confirm409 SOURCE_NOT_VERIFIED均需保留真实状态，声纹not_performed；不伪造可信身份、修改服务端开关或数据库。
5. Finish使用稳定finish_id、真实last_sequence，在停止输入及全部应有片段202后提交；202 draining继续查，409 awaiting_audio补缺段或显示阻断，Review409不呈现成功。预算耗尽与无事实/Pending场景不能“空成功”。
6. 对断网、401/403、超时、取消、来源待确认、失去设备提供现有界面可理解的恢复/降级。Mock明确标识，录屏标录屏；不能自动切Mock后宣称真实成功。只在真实Review可用时更新正式云复盘，保留明确的本地Mock路径。
7. SDK需另行授权迁移，历史为静态 `SoundcoreWorkAppleSDK`/`module_spplinkKit` 两套XCFramework；约20ms裸Opus须真实解码/重采样，禁止加头冒充WAV。低层startRecord不等于D3200新录制/stop能力已确认；硬件未验收时保持禁用/未接入并列阻断，不为凑LHY-08完成状态发明实现。
8. 后端已部署，无需新建AWS资源。HTTP Token不同于模型Key，只用私密本机配置，不能硬编码、输出、打包或截图；/health可用不证明模型/新端到端成功。缺声纹/建议后端显示不可用，不自建权威Fact Engine或服务。

## 验证与真实阻断

先在无远程凭据条件下重放本地fixture全链，覆盖正常Facts、SOURCE_UNCERTAIN/Pending、确认409、重复上传、缺段/Finish202与409/Review409、断网与超时/预算耗尽、取消/会话切换和Mock恢复。跑现有 `swift test`、`python3 -B scripts/verify.py`、`python3 -B -m unittest discover -s data/D01/tests -v` 及新合同/状态测试。

可用Mac上执行并记录实际结果：

```sh
swift test --scratch-path /private/tmp/fitcore-lhy08-unit-tests
xcodebuild -quiet -project ios/Fitcore.xcodeproj -scheme Fitcore-Mock \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/fitcore-lhy08-build CODE_SIGNING_ALLOWED=NO build
```

模拟器构建不等于物理iPhone验收，generic iOS无签名构建也不等于安装运行。若用户提供物理iPhone并授权本机安装/本人录音，再按清单实际完成签名安装、权限拒绝恢复、录制/停止/回听/导出、取消/重录、中断/后台、重启恢复及四页/Mock演示；记录型号、iOS、Xcode、源码指纹与脱敏视频。真实云联调须另有范围/费用/云处理授权和有效HTTP Token，硬件需录音豆及盒子；未执行项保持未验收，不能用合成WAV或模拟器替代。

## 独立 ZIP 交付条件

提供完整当前源码、Xcode工程/资源、必要脚本与本地测试/fixture、D01空模板、已整合任务清单、跨Mac打开/签名/运行步骤、源码指纹、文件清单、SHA-256及本地/模拟器/物理iPhone/云/录音豆分项验收矩阵。ZIP解到新目录无需旧机器绝对路径、私密文件或父目录资源即可跑Mock和离线检查。排除 `.git`、构建缓存、SDK（除非另获分发授权）、个人签名、`Local.xcconfig`、Token/模型Key、私人WAV/授权记录/数据库。不伪造Commit/PR；无Git时用源码指纹追溯。明确本轮已实现、已验证、未验收与真实阻断，用户后续批准远程操作前保持本地交付。


---

## D02


# D02｜真人转写与结构化人工标注：跨电脑独立接手 Prompt

以下全文可复制给另一台电脑上的 Codex。请实施 D02；不要顺带实施 D03–D05，也不要把本 Prompt 当成已经完成任务的证据。

## 目标与先读文件

你接手 Fitcore 的 D02，负责人 LHY，第二人工复核人为 JZD。目标是建立可追溯的人工逐字转写和结构化标注流程，让事实标签独立于算法预测；最终交付可离线复现的 D02 独立 ZIP。

先定位解压后的工程根目录，按顺序阅读：

1. `README.md`
2. `handoff/CURRENT_STATUS.md`
3. `handoff/KNOWN_API_GAPS.md`
4. `reference/task-package/tasks/D02.md`
5. `reference/task-package/docs/03_AUDIO_DATA_CONSENT_AND_ANNOTATION.md`
6. `reference/task-package/templates/ANNOTATIONS.csv`、`CONSENT_REGISTER.csv`、`WAV_MANIFEST.csv`
7. `data/D01/README.md`、`data/D01/SAMPLING_MATRIX.md`

先报告工程目录、资料缺失和实际输入数量。若目录含 Git，仅只读确认仓库和当前分支；沿用当前分支，不自动建仓库、切分支、提交或推送。ZIP 没有 `.git` 不构成阻断。若上述文件互相冲突，列明原字段与映射，保留来源，不静默覆盖。

## 接手时必须保留的现状

- 当前 App 为 **0.3.1 (8)**。LHY01 iPhone 采集代码已经本地验证，**真机采集尚未验收**。已有布局与 Mock 链路继续保留。
- 本次交接基线：**真人录音 0 段、已核验说话者 0 人、实际采集同意登记 0 条**。历史“7 段”不在此交付内，不能假设可访问或有再次使用许可。10 段首批、约 40 段和 3–5 人均为目标。
- D01 已有 Python 标准库工具、精确 CSV schema、iOS 嵌套 `inspection` 元数据导入、人工 `verify-human`、SHA-256 去重、撤回/到期排除、安全路径和 25 项测试；**复用，不重写**。已有测试通过不等于真人数据通过验收。
- D01 的 `local`、`team`、`cloud` 是独立用途许可。iOS 的 `local_recording_consent=true` 不是团队或云处理同意。授权、保存期限和撤回状态每次使用都要重新核对。
- 后端已部署。本任务不重新开发后端、不改 source trust 绕过 Pending、不把 HTTP token 当模型 Key。密钥不进聊天、Git、日志和 ZIP。

## 最小实施范围

1. 只在 `data/D02/` 增加本任务所需的标注规范、数据字典、空模板、离线校验工具、必要的合成 fixtures 和核验说明；优先 Python 标准库，不加服务或新依赖。先给出会修改的具体文件和可检查结果，再实施。
2. 保留原 `ANNOTATIONS.csv` 表头和列序。显式记录规范映射：文档 `temporal_modality` 对应模板 `tense_or_modality`，`annotator_id` 对应 `annotator_id_pseudonym`，`ambiguity` 对应 `ambiguity_type`；`reviewer_id_pseudonym` 记录 JZD 的实际复核。多片段使用唯一 `(recording_id, segment_index)`；一段多事实/多意图的拆分规则和上下文关联须写清楚。若需要额外的 revision 或上下文字段，使用有版本的附属文件并说明关联，不改 D01 schema。
3. 原始 WAV、人工 reference/gold、ASR 假设分别存储。先听实际音频完成人工稿，再独立复核；ASR 只作诊断参考，不能批量复制成 gold，也不能根据脚本、文件名或预期说法补全文本。模板的 `asr_hypothesis_separate` 不表示允许混合来源：默认保持空值，用独立 ASR 工件及匿名关联记录诊断结果。
4. 区分：当前已完成事实、历史事实、未来计划、主观状态、非训练内容、上下文补充、明确纠错。纠错必须记录实际目标组/事实；“上一组”“改一下”无法唯一定位时保留 UNKNOWN/歧义并等待复核，不能擅自修改当前组。计划和历史不得标成当前完成记账。
5. 重量、次数、动作、对象、上下文缺失或听不清时，使用规范化的 `UNKNOWN` 或待审状态，保留原始歧义，不按常识、模型输出或 Fact Engine 预测补数。映射 `needs_audio_review`/`needs_review` 等状态时建立明确字典，禁止悄悄当成已审核。
6. 每条保留匿名标注者、实际复核者、`gold_version`、审核状态、证据引用和变更原因。LHY 初标，JZD 依据真实原音频独立复核；工具检查/Codex 方法审查不能冒充第二次人工听音。建立不一致列表及争议裁决日志。未经双方实际复核的样本不得标为已复核；争议交用户最终裁决。
7. 只从当前有效、已 `verify-human`、具备所需用途许可的 D01 私有数据读入。给 JZD 共享前还需实际 `team` 许可；本地许可不能推导共享许可。D02 不覆盖原始音频，不擅改 D01 manifest，不宣称完成 D04 划分。冻结 gold 的修改必须有原音频证据、变更申请、独立审核和新版本；不得为了提高模型分数改标。
8. 若真实音频和同意仍为 0，只完成流程、空模板和明确标为 synthetic 的离线用例，实际标注数报告 0；不要生成虚构参与者、同意登记或“真人金标”填充结果。状态写“准备工具已验证；真人标注/双人验收待进行”。

## 验证与验收证据

先用离线 synthetic fixtures 验证：普通已完成句、计划/历史、数字不清、上下文不足、纠错目标不明、多意图、无训练内容；正常记录通过，缺必填字段、重复主键、错版本、未复核冒充已复核、无效跨表引用等被明确拒绝。不得把这些文本计入真人标注数量。

针对实际修改运行最窄的有效检查，记录命令、退出码、测试数量和失败原因。若没有改 D01，不重写或扩大其测试；引用已有 25 项测试只能注明来源，未在本机重跑时不能说“本机通过”。记录真人输入数、初标数、JZD 实际复核数、争议数和冻结数；没有证据就填 0 或未验收。

默认全程离线。真实 API、收费模型或音频云处理，只能在用户明确批准用途、数据范围、服务和预算后做；参与者的云许可与用户批准缺一不可。不申请假 Key，不以真实 API 调通作为本任务离线流程的前提。

## 独立 ZIP 交付

交付 `D02-delivery.zip`，顶层 `D02-delivery/`，包含本任务源码、空模板、规则/字段映射、synthetic fixtures、验证记录、匿名争议模板和 `README.md`。README 说明 Python 版本、离线运行方式、相对路径依赖、输入/输出 schema、实际完成数、未验收项、JZD 复核流程和安全迁移边界；不要依赖原电脑的绝对路径或相邻交付目录。所需公共参考可按白名单复制，不打包整个工作区。

默认代码 ZIP 排除真人 WAV、真实 sidecar、实际同意/manifest 行、授权证据、身份映射、私密日志、私人转写、密钥、构建缓存、`.git` 和个人绝对路径。真实音频以及需受限的标注数据另行按实际许可受控迁移；不得因为用了化名就默认可以分享。没有真实数据时只交空结构，清楚写“真人 0、未验收”。

生成 ZIP 后检查成员清单和解压后的独立离线运行结果，记录 ZIP SHA-256；不得用测试 fixtures 充当实录。最后按“Assumption / Changed / Verified / Remaining risk”报告文件、实际命令、统计、阻断和交付位置。不要默认 Git 推送，也不要默认删除任何输入资料。


---

## D03


# D03｜100–150 条语义语料：跨电脑独立接手 Prompt

以下全文可复制给另一台电脑上的 Codex。请实施 D03；不要顺带重做 D01、D02、D04、D05，也不要把本 Prompt 当作语料已经完成的证明。

## 目标与先读文件

你接手 Fitcore 的 D03，负责人 LHY，人工复核协调人为 JZD。目标是交付有来源、覆盖说明、用途和版本的语义文本集合，以及离线结构/重复检查。**100–150 条是目标，当前并无已完成的真人语料证据。**

先定位解压后的工程根目录，按顺序阅读：

1. `README.md`
2. `handoff/CURRENT_STATUS.md`
3. `handoff/KNOWN_API_GAPS.md`
4. `reference/task-package/tasks/D03.md`
5. `reference/task-package/docs/03_AUDIO_DATA_CONSENT_AND_ANNOTATION.md`
6. `reference/task-package/templates/ANNOTATIONS.csv`、`SPLITS.csv`、`WAV_MANIFEST.csv`
7. `data/D01/README.md`、`data/D01/SAMPLING_MATRIX.md`
8. 若已交付，阅读 `data/D02/` 的数据字典、复核状态及 `data/D04/` 的冻结清单；缺失时如实记为未提供。

先报告目录、文件可用性、实际真人/人工编写/模拟文本数量及是否存在冻结 held-out。若目录含 Git，仅只读确认仓库和当前分支；沿用当前分支，不自动建仓库、提交或推送。没有 `.git` 时继续按 ZIP 交付，不编造 commit。

## 接手基线与边界

- App 为 **0.3.1 (8)**；LHY01 iPhone 采集代码已本地验证，**真机尚未验收**。保留 App 布局和 Mock。
- 此交付基线为**真人录音 0 段、已核验说话者 0 人、实际同意登记 0 条**；首批 10 段、约 40 段/3–5 人以及 D03 的 100–150 条均为目标。历史 7 段未随包交付，不视为可用来源。
- D01 标准库工具已有精确 schema、用途许可 `local/team/cloud` 分离、iOS 嵌套 metadata 导入、人工来源复核、hash 去重、到期/撤回、安全路径及 25 项测试。只复用必要接口，不重写 D01，不伪造同意或金标。
- 后端已部署，不重新开发；不改 source trust 绕过 Pending。HTTP token 不等于模型 Key，密钥不进聊天、Git、日志或 ZIP。

## 最小实施范围

1. 只在 `data/D03/` 建设最小的文本数据字典、CSV/JSONL、覆盖计划、来源/版本记录、离线校验和重复检查，优先 Python 标准库；先列具体文件和可检查结果。不要新增 App 功能、后端服务或训练架构。
2. 为每条记录保留稳定唯一 ID、文本、来源类型、来源引用、场景、意图/事实标签、时间模态、歧义、用途、版本和审核状态。来源至少明确区分 `human_transcript`、`human_authored`、`model_simulated`；若由 Codex/其他模型生成，必须归为模拟来源，不能称人工编写或真人实录。真人转写必须关联 D02 已实际复核、许可有效的匿名来源；没有来源证据不得升级类别。
3. 明确事实、历史、计划、上下文、纠错目标、指代、多意图、动作别名、主观感受和来源不确定；覆盖数字歧义、纠错对象错误、完成/计划混淆等关键反例。保留 UNKNOWN 和待审状态，不用模型预测自动补重量、次数或上下文。字典说明多事实如何拆分以及样本/事实粒度。
4. 在扩充前读取 D04 冻结范围；禁止复制、改写、翻译或由冻结测试样本派生训练/dev 案例。若 D04 尚未冻结，先建立候选池与来源组，标为待分配/未冻结；可准备规则和不依赖 held-out 的设计用例，但不擅自宣称独立测试完成，不以“test”标签冒充正式 held-out。遇到选样冲突先保护冻结集合，由 D04 独立审核后再扩充。
5. 对明显重复做规范化文本精确检查，对近重复用清楚、可复现的轻量规则列候选，例如同模板仅换数字/动作、词序或轻微同义改写。保留原文，输出重复组/派生来源及人工复核结论，不自动吞掉内容；无需新向量库或线上模型。不能把同源改写分散到 train/dev/held-out 来增加样本数或分数。
6. 用途明确列为 train/dev/test；未分配和正式 test/held-out 的映射另有说明。附来源组/近重复组标识，避免同组跨受保护划分。不要改 D01 原表 schema；D02 文档与模板的 `temporal_modality`/`tense_or_modality`、匿名 ID 等差异采用显式映射。
7. 单独报告目标数、实际总数、各来源实际数量、有效/待审/排除数、各场景覆盖、重复与近重复数。100–150 条即使以编写/模拟案例达到，也只能称相应来源的文本集合；不能说真人 100–150 条或已证明真实音频表现。模拟预期标签只算测试 oracle，须人工审查后才成为该模拟集合的参考标签，永不冒充真人 gold。
8. 无真实输入时，先完成空的真人来源结构和明确标为模拟的离线 fixtures。需要扩到目标数量时可以准备来源如实标注的设计案例，并保持未人工审核状态；不得编造 JZD 审核、授权、采集时间、音频哈希或录音引用。真人及双人审核阶段继续标记待进行。

## 验证与证据

离线检查必填/枚举/唯一 ID/数值与 UNKNOWN/来源引用/版本/用途；验证精确重复、近重复、同源改写、跨冻结集合引用能够被报告或拒绝。测试应包含完成和计划、历史和当前、明确与不明确纠错、数字歧义、多意图和非训练文本，不以实现细节堆测试。

记录实际执行命令、退出码、样本计数、覆盖分布、待人工确认的近重复候选与未解决规范差异。若依赖的 D02/D04 未交付，明确受影响的验收项，继续完成不依赖真人输入的离线准备；不能将 0 真人样本写成已完成采集。

默认离线，不调用真实 API/模型，不上传音频。用户明确批准具体用途、服务、数据范围及预算之后，才能开展对应真实调用；真人音频云处理还须独立有效的云许可，团队许可不能替代。不要以模型返回内容替换冻结 gold 或人工答案。

## 独立 ZIP 交付

交付 `D03-delivery.zip`，顶层 `D03-delivery/`；包含最小源码、字典、来源/变更记录、可交付文本集合或空模板、synthetic fixtures、重复/覆盖报告和验证记录。`README.md` 必须说明 Python 版本、相对路径、数据 schema、离线命令、实际来源数量、D02/D04 依赖、冻结保护和待审清单；新电脑解压后不依赖原电脑绝对路径或相邻目录即可跑离线验证。

默认代码 ZIP 排除真人 WAV、真实 sidecar、实际 consent/manifest 行、授权证据、身份映射、私密日志、私人转写、密钥、`.git`、缓存和个人绝对路径。经明确许可范围核验后的脱敏文本也要先检查内容和交接对象；未获许可的真实音频/转写另行受控迁移，不能因为匿名就自动进入 ZIP。模拟案例必须保留明显来源标记。

按白名单打包并检查成员清单，解压验证离线命令，记录 ZIP SHA-256。最后按“Assumption / Changed / Verified / Remaining risk”给出文件、实际数量、验证和缺口；不默认 Git 推送，不修改冻结测试 gold，不删除输入资料。


---

## D04


# D04｜独立 Held-out 冻结：跨电脑独立接手 Prompt

以下全文可复制给另一台电脑上的 Codex。请实施 D04；不要顺带调模型、开发后端或修改冻结 gold，也不要将本 Prompt 当成已完成独立测试的证据。

## 目标与先读文件

你接手 Fitcore 的 D04，LHY 负责制作与维护，JZD 为第二人工复核人。目标是形成可追溯、可校验、按说话者/会话/录制环境独立留出的测试集及冻结流程；用户或独立于调参工作的审核者批准冻结。

先定位解压后的工程根目录，按顺序阅读：

1. `README.md`
2. `handoff/CURRENT_STATUS.md`
3. `handoff/KNOWN_API_GAPS.md`
4. `reference/task-package/tasks/D04.md`
5. `reference/task-package/docs/03_AUDIO_DATA_CONSENT_AND_ANNOTATION.md`
6. `reference/task-package/templates/SPLITS.csv`、`WAV_MANIFEST.csv`、`ANNOTATIONS.csv`
7. `data/D01/README.md`、`data/D01/SAMPLING_MATRIX.md`
8. 已存在的 `data/D02/` 人工复核/版本记录和 `data/D03/` 来源/近重复清单；缺失时明确说明。

先报告实际目录、可用样本数、权限与来源证据、是否已有冻结版本。若有 Git，仅只读确认仓库/当前分支并沿用；无 `.git` 时照常离线交付，不自动建仓库、提交或推送。先列实际输入、拟修改文件与独立性判据，再实施。

## 必须保留的事实与边界

- App **0.3.1 (8)**；LHY01 iPhone 采集代码已本地验证，**真机未验收**；保留当前布局与 Mock。
- 此交付基线：**真人录音 0、已核验说话者 0、实际采集同意登记 0**。历史 7 段未随包提供，不能用于声称 held-out；10 段/约 40 段/3–5 人和 D03 100–150 条均是目标。
- D01 标准库工具、精确 schema、iOS 嵌套 metadata、人工 `verify-human`、hash 去重、到期撤回、安全路径及 25 项测试已经实现，不重写。`data_split=unassigned` 不表示冻结完成，成功导入也不表示人工 gold 已验收。
- `local/team/cloud` 许可分别核验；只读本地可用不代表允许给 JZD/团队共享或上传第三方模型。源文件、转写和标签均须遵循当前许可与保存期限。
- 后端已经部署，不重新开发，不改 source trust 绕过 Pending；HTTP token 不等于模型 Key。密钥不进聊天、Git、日志或 ZIP。

## 最小实施范围

1. 仅在 `data/D04/` 增加分组划分规则、空模板、离线冲突检测、冻结清单/访问及审批模板、版本说明和必要的 synthetic fixtures。优先 Python 标准库，复用 D01 清单，不修改其 schema 或回填其运行数据。
2. 先明确数据粒度和来源组。最少检查同一原始 recording/hash、说话者、会话、录制环境，以及 D03 的派生/近重复组。此轮严格基准要求同一 `speaker_id_pseudonym`、`session_id`、实际环境组分别都不得跨 train/dev 与 held-out；同录音切片、ASR 文本、转写、改写和其他派生形式也不能跨保护边界。不可仅随机逐行切分。
3. **先解决 scene 语义差异。** D01 采样矩阵的 `scene_id=ordinary/numeric_ambiguity/...` 目前表达语义场景类别，D04 所需的录制环境隔离是另一维。不能据此直接声称环境独立，也不要悄悄重定义 D01 字段。用最小附属元数据记录真实环境组并与现有 `scene_id` 对照，分别报告语义覆盖与录制环境隔离；环境信息缺失则冻结阻断，不编造地点或设备信息。
4. 以来源/说话者/会话/环境/近重复的关联组作整体分配。发现维度冲突时优先保留完整组、调整候选划分或排除冲突候选并说明原因；若只有同一人或同一环境等导致无法独立留出，就明确“独立 held-out 未建立”。任务卡提到的例外评测设计不能被默认为本轮严格基准豁免；只有用户另行批准的设计才能单独命名和报告，不能冒充严格独立集。
5. 保留 `SPLITS.csv` 精确表头/列序，记录实际 `dataset_version`、split、音频及 gold 的 SHA-256、冻结时间、审核者、排除原因。音频 hash 使用不可变原始字节；gold hash 指向清楚定义、稳定编码/序列化的标签工件；补充冻结 manifest 的 hash 和算法说明。音频不存在、标签未审或 hash 不符就不能填“已冻结”。
6. 先通过污染检测，再由独立审核者核验并批准冻结。LHY 不能兼任采集者、调参者和独立验收人；JZD 只有实际参与复核才能署名。Codex 可以核验规则/哈希，但不得声称完成未做的人类听音或用户审批。独立审核与冻结操作须留真实时间、版本和审批证据引用。
7. 冻结后标签/样本不进入开发 prompt、训练材料、回归调参集或演示选例；算法端/TRAE 只接收获准的汇总反馈，不直接改锁定标签。访问、解封和重标留审计；有原音频证据的更正先提出申请，由用户或独立审核者批准后发布新版本，保留旧 hash/差异，不能为了分数调测试。
8. 同意撤回/到期后立即排除后续用途并记录版本失效或重建理由；不可为了维持已冻结数量继续评测。冻结不覆盖参与者撤回权，不擅自批量删除原件；实际删除按授权由负责人逐项处理并留记录。
9. 当前真实样本仍为 0 时，只交付规则、空冻结清单、明确标为 synthetic 的隔离/哈希测试和阻断列表；状态保持“冻结流程已离线验证；真人独立集未建立”。样本不足的实测最多标“探索性”，不声称泛化已证明。

## 验证与证据

用离线 fixtures 验证：合法分组可通过；同 speaker/session/实际环境跨 held-out、相同音频 hash、同源切片/改写、近重复跨 split、缺真实环境映射、gold/hash 改动、未批准冻结均被报告或拒绝。synthetic fixture 中的虚构标识与时间只能用于测试，不能混入真实冻结清单。

记录实际命令、退出码、冲突清单、排除数、每个 split 的实际样本/说话者/会话/环境分母及各语义覆盖；0 就写 0。不要用 D01 原有 25 测试声称 D04 通过。若未执行本机检查或没有独立审批，明确未执行/未批准及原因。

默认离线，D04 无需调用真实模型。任何真实 API、收费模型或音频云处理要等用户明确授权用途、服务、样本范围和预算，并核对参与者对应许可后再做；不使用 frozen gold 调 prompt 或 source trust。

## 独立 ZIP 交付

交付 `D04-delivery.zip`，顶层 `D04-delivery/`；包含规则、schema/附属环境映射定义、空或获准脱敏的冻结清单、检测源码、synthetic fixtures、访问/变更审批模板、验证报告和 `README.md`。README 写清相对路径依赖、Python 版本、离线命令、hash 算法/输入、版本/审批状态、实际分母、独立性不足项和授权受控迁移办法。

默认代码 ZIP 不含真人 WAV、真实 sidecar、同意登记/证据、身份映射、私人转写或 gold 内容、私密日志、密钥、`.git`、缓存及个人绝对路径。冻结清单/哈希本身也须核对交接范围，不能据“匿名”自动公开。真实音频和受限 gold 通过另行受控渠道迁移；不把源文件随普通代码 ZIP 转发。

按白名单检查 ZIP 成员，解压后运行独立离线检测，记录 ZIP SHA-256。最后按“Assumption / Changed / Verified / Remaining risk”报告文件、实测命令、样本分母、污染/冲突和未完成审批；不默认推送 Git，不改冻结 gold，不将探索性结果包装为独立测试通过。


---

## D05


# D05｜算法与系统量化评测：跨电脑独立接手 Prompt

以下全文可复制给另一台电脑上的 Codex。请实施 D05 的最小离线评测与报告；真实调用仅在另行获批后开展，不顺带重新开发后端或修改测试 gold。

## 目标与先读文件

你接手 Fitcore 的 D05，LHY 提供数据与统计，JZD 为第二人工复核人，Codex 核验统计方法，算法端解释错误。目标是产出分母、版本、费用和分层错误都可追溯的评测脚本与独立 ZIP；面向赛事的结论仍须用户批准。

先定位解压后的工程根目录，按顺序阅读：

1. `README.md`
2. `handoff/CURRENT_STATUS.md`
3. `handoff/KNOWN_API_GAPS.md`
4. `reference/task-package/tasks/D05.md`
5. `reference/task-package/docs/03_AUDIO_DATA_CONSENT_AND_ANNOTATION.md`
6. `reference/task-package/templates/EVAL_RESULTS.csv`、`ANNOTATIONS.csv`、`SPLITS.csv`
7. `data/D01/README.md`、`data/D01/SAMPLING_MATRIX.md`
8. 已存在的 D02 gold 版本/复核证据、D03 来源及近重复清单、D04 冻结清单/审批和实际测试日志；缺少就写缺少。

先核对目录、实际可用输入、被冻结版本、日志来源和允许的调用范围。若有 Git，仅只读确认仓库与当前分支，沿用当前分支；没有 `.git` 时从可验证交付清单读取版本来源，不能编造 SHA，不自动建仓库、提交或推送。先列最小文件清单、指标定义和预计验证方式，再实施。

## 必须保留的现状

- 当前 App 为 **0.3.1 (8)**；LHY01 iPhone 采集代码已本地验证，**真机未验收**；保留当前 App 布局与 Mock。
- 交接基线为**真人音频 0 段、已核验说话者 0、真实同意登记 0**；D01 10 段/约 40 段/3–5 人及 D03 100–150 条只是目标。历史 7 段未交付，不能据旧描述补出测试成绩。
- D01 标准库工具和 25 项测试已实现；有精确 schema、`local/team/cloud` 许可分离、iOS nested metadata 导入、人工来源复核、去重、到期撤回及安全路径。只复用，不重写；工具测试不是模型效果或真人验收。
- 后端已部署；D05 不重建后端，不改 source trust 绕过 Pending，不为了提高分数弱化 COMMIT 规则。HTTP token 只是接口访问凭据，不等于 ASR/语义模型 Key。密钥不进聊天、Git、日志、报告或 ZIP。

## 最小实施范围

1. 仅在 `data/D05/` 增加离线输入 schema、统计脚本、明确标为 synthetic 的 fixtures、指标字典和报告模板，优先 Python 标准库；复用现有日志/接口格式，不新增产品架构。先用 fixtures 验证统计，再读取获准的实际日志。
2. 保留 `EVAL_RESULTS.csv` 的表头与列序；模板不足的指标分母、执行环境、模型精确版本、计时样本数、费用凭证和误差粒度放在有版本的附属明细/报告中，显式关联。不要把新字段塞入旧列或改变 D01/冻结数据 schema。
3. 每次 run 留 `dataset_version`、数据/标签/划分 hash、被测 `source_commit`、App 版本、后端版本（可核实时）、运行时间与环境、模型供应方/模型精确版本/配置标识、真实/模拟来源、实际样本数、失败/排除数及原因。区分**记账动作 COMMIT 的错写/漏写**与版本元数据 `source_commit` 缺漏/写错：二者都要检验，未知 commit 不伪造，版本证据不全的 run 不作为可发布正式结论。
4. 分别报告文本模拟、旧数据回放、真实音频验收、独立 held-out；独立 held-out 还必须有 D04 已批准冻结和防污染证据，不能把 Mock/replay 或未冻结真实数据标成 held-out。CSV 的 `mode_mock_replay_real` 与 split/报告来源要显式映射，不能混算不同来源的总“准确率”。
5. 在统计前固定粒度和分母。多意图样本可能产生多个 gold 事实和多个决策，必须分开记录 sample 数、应记事实数、实际 COMMIT 数和决策数，并写清重试/同源去重方法。例如：
   - 正确自动记账率：正确自动 COMMIT 的应记 gold 事实数 / 应记 gold 事实总数。
   - 错误 COMMIT 率：错误/无依据的 COMMIT 数 / 实际 COMMIT 总数；同时给原始计数。动作/重量/次数/目标错误、把计划或历史当当前事实、重复写入或越权纠错都不能被“已出结果”掩盖。
   - 遗漏率：未被正确记入的应记 gold 事实数 / 应记 gold 事实总数；DEFER/Pending 是否造成暂时遗漏、漏写与错写是否重叠须明示，不能把非互斥类别相加宣称 100%。
   - DEFER/Pending 率：实际暂缓决策数 / 有效决策总数；另按 gold 应 COMMIT/应暂缓交叉列明。符合歧义策略的暂缓不自动算错误 COMMIT。
   每个百分比都输出分子、分母和单位；分母为 0 输出 `N/A`/不适用及原因，不能写 0%、100% 或“全部通过”。所有比例以实际输入算出，不用目标样本量作分母。
6. 将错误分层：ASR 的转写/数字错误，语义层的意图/模态/数值/指代/纠错理解错误，Fact Engine 的信任校验/决策/状态更新错误。单条可以多层命中，主因与伴随错误分开；证据不足写无法归因，不凭最终失败猜 ASR。文本 fixtures 没有实际音频/ASR 过程时，ASR 及真实音频指标为不适用。
7. 每个失败案例关联匿名 recording/sample ID、受限证据指针、输入来源、预期/实际、gold 版本、层级、设备/说话者/噪声/动作/数字歧义维度；缺维度写未知，不编造。原音频、私密原文和密钥不进入普通报告。预测和运行结果另存，不回写人工 reference 或冻结 gold；问题经 D02/D04 变更流程处理，禁止为分数改测试。
8. 延迟只统计实际测量，定义起止边界、计时来源、成功/失败/超时纳入策略、单位和有效 n，采用明确可复现的分位数算法。没有计时数据时 P50/P95 留空或 N/A；synthetic 时延只用于校验算法，不填成真实模型性能。小样本也必须给 n 并标探索性，不用人工估计补数。费用只报告实际可核对凭证或用量，币种/计费范围/来源清楚；缺证据为未核验，不填“0 元”或编造收费模型成绩。
9. 当前真人输入仍为 0 时，报告明确写真实样本数 0、真人效果/独立 held-out 未评估；可以完成离线脚本验证和模拟报告，但不能声称真人准确率或模型效果。JZD 实际人工复核才能署名；Codex 核验脚本不能替代 JZD 听音。报告用于赛事/宣传前，保留用户审批状态，不擅自发布。

## 验证与真实调用边界

先跑小型离线 fixtures：正确 COMMIT、错误数字/动作、漏写、合理与不合理 DEFER、计划/历史、错误纠错对象、多事实、重复运行去重、0 样本、全失败、缺/错 source_commit、缺计时/费用凭证。用可手算的期望计数核对统计，验证 0 分母不产生假百分率、多个层级不误加为互斥总数、分位数与样本数一致。

记录实际命令、退出码、fixture 数量与结果；仅测试通过后再分析获准日志。没有运行的检查要明确写未运行及原因，不拿 D01 25 测试替代 D05 统计验证。

默认不调用 API、模型或云处理。用户明确批准具体用途、服务、模型、数据范围、调用次数/费用上限后，才能执行对应真实评测；音频云处理还要核对每条当前有效的 cloud 许可、保存期限和撤回状态，团队/本地许可不能替代。调用前只核对凭据是否由安全渠道配置，禁止要求把 Key 粘到聊天；达到预算或缺授权则停止对应真实调用，继续可做的离线工作。

## 独立 ZIP 交付

交付 `D05-delivery.zip`，顶层 `D05-delivery/`；包含离线统计源码、schema/指标字典、synthetic fixtures、可复算结果、验证记录、报告及 `README.md`。README 写 Python 版本、相对路径、离线执行命令、来源/版本/hash、各统计分母、实际调用与费用证据状态、未评估项和审批状态；新电脑解压后不依赖旧机器绝对路径或真实凭据即可验证统计。

按白名单打包，默认排除真人 WAV、真实 sidecar、同意登记/证据、身份映射、私人转写/gold、未脱敏原始日志、密钥、`.git`、缓存和个人绝对路径。真实音频和受限数据另行按许可受控迁移；报告脱敏也不等于授权公开。验证 ZIP 成员、解压后的离线命令并记录 ZIP SHA-256。

最后按“Assumption / Changed / Verified / Remaining risk”报告文件、被测版本、实际样本/来源、真实执行命令、费用/时延证据和缺口。不默认推送 Git、不发布赛事结论、不改冻结 gold、不把离线 fixture 成绩当真实模型成绩。
