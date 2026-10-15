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
