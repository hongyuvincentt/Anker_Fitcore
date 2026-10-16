# LHY-04 证据目录（训练 UI · 离线 Mock 集成）

本目录持久化 LHY-04 首轮交付的证据。所有检查均在 2026-10-16（Asia/Shanghai）执行并记录；
全部请求由本机 `MockCloudBackend`（actor，进程内 `HTTPTransport`）应答，零真实网络访问、
无真实令牌、无真人录音（音频均为固定数值模式合成的 `syntheticDemoWAV`）。

## 文件清单

| 文件 | 内容 | 执行时间 | 退出码 |
|---|---|---|---|
| `swift-test.log` | `swift test --scratch-path /tmp/fitcore-lhy04-build` 全量输出：WAVHTTPKitTests 55/55（含新增 CloudTrainingModelTests 11）+ WAVCaptureKitTests 30/30，共 85 | 2026-10-16 04:55 | 0 |
| `verify.log` | `python3 -B scripts/verify.py`（脚手架检查，含 Core strict-concurrency 编译） | 2026-10-16 04:55 | 0 |
| `xcodebuild.log` | `xcodebuild -project ios/Fitcore.xcodeproj -scheme Fitcore-Mock -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /tmp/fitcore-lhy04-dd build`（BUILD SUCCEEDED，仅 appintentsmetadataprocessor 无害警告） | 2026-10-16 04:33 | 0 |
| `source-manifest.sha256` | 137 个源文件逐文件 SHA-256 清单（不含 .git/.build/构建缓存/voice/证据文件自身） | 2026-10-16 04:57 | - |
| `verification.json` | 结构化验证记录（呈现规则、Mock 诚实规则、检查项、缺陷修复、未执行项） | 2026-10-16 | - |
| `screenshots/` | 17 张真实模拟器像素截图（iPhone 18 Pro, iOS 27.0） | 2026-10-16 04:36–04:47 | - |

## 截图采集方式（如实说明）

模拟器 GUI 无法通过辅助功能自动化（osascript 无辅助功能权限），因此采用
**App 内巡览 + 外部同步截图**：

1. App 以 `--lhy04-screenshot-tour` 参数启动（`RootView` 仅在该参数下切换到巡览视图，
   正常启动完全不受影响）；巡览驱动**真实的** `CloudTrainingContent` 按七个状态组
   （对应任务卡要求）依次进入各状态。
2. 每个状态就绪后写入标记文件 `Documents/lhy04-tour/current-state.txt`，
   外部脚本轮询标记并用 `xcrun simctl io <UDID> screenshot` 抓取真机像素。
3. 17 张截图全部唯一（MD5 无重复），关键截图已用 Vision OCR 抽查验证内容
   （如 12 号图含「出错：未授权（401/403）」，05 号图含「已提交 COMMIT」）。

中间过程如实记录：第一轮截图方案使用 `ImageRenderer` 离屏渲染，产出为空白（视图内容未
进入渲染），该方案废弃；第二轮因瞬时状态（处理中/draining）窗口过短导致 04/05、07/08
两两重复，已通过放慢该场景轮询间隔修复并重拍。最终为第三轮结果。

## 截图与任务卡状态组对应

| 任务卡要求 | 截图 |
|---|---|
| 处理中 → 正式 Facts | 04（处理中，无正式记录）、05（Facts 到达） |
| 处理中 → Pending | 09（DEFER · SOURCE_UNCERTAIN 如实显示） |
| 上传失败与使用原标识重试 | 10（失败 + 原标识重试入口）、11（重试成功） |
| 401/403 | 12 |
| 超时 | 13（轮询超时 + 同标识重新查询） |
| 响应解析失败 | 06（保留上次数据 + 失败横幅，不显示"没有待确认内容"） |
| Finish 202/draining | 07 |
| Finish 409/awaiting_audio | 14（缺失序号 + 相同 finish_id 重试）、15（补传后恢复完成） |
| Review 未就绪与成功 | 16（409 未就绪）、17（重试后成功） |
| 离开、返回页面后状态一致 | 由 `testRefreshAndResubmitNeverDuplicateCardsOrIdentities` 逻辑覆盖（模型为 App 级持有，离开页面不重建）；App 内重复刷新无重复卡片亦由该测试断言 |

## 未执行项（不伪装为已完成）

- 真机（iPhone）Mock 主链验证：**未测**。模拟器构建不能代替真机验收。
- 真实 AWS 端到端、真实 Token、真人录音上传：本轮未授权，未执行。
- Pending resolve 交互：受 GAP-PENDING-RESOLVE-BODY 阻塞，界面显示"暂不可用"并注明联调条件。
