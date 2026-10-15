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
