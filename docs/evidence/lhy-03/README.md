# LHY-03 证据目录（离线 HTTP 客户端与合同测试）

本目录持久化 LHY-03 首轮交付的证据。所有检查均在 2026-10-16（Asia/Shanghai）重新执行并记录，
未补造任何历史日志；开发过程中的中间轮次日志（如首轮 2 项失败的失败详情）不可找回，见下文说明。

## 文件清单

| 文件 | 内容 | 执行时间 | 退出码 |
|---|---|---|---|
| `swift-test.log` | `swift test --scratch-path /tmp/fitcore-lhy03-build` 全量输出：WAVHTTPKit 44/44 + WAVCaptureKit 30/30 | 2026-10-16 02:59 | 0 |
| `verify.log` | `python3 -B scripts/verify.py`（plutil/Xcode 成员一致性/Core strict-concurrency 编译/动态记录回归） | 2026-10-16 02:59 | 0 |
| `xcodebuild.log` | `xcodebuild -project ios/Fitcore.xcodeproj -scheme Fitcore-Mock -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /tmp/fitcore-lhy03-dd build`（0 warning） | 2026-10-16 03:00 | 0 |
| `source-manifest.sha256` | 124 个源文件逐文件 SHA-256 清单（不含 .git/.build/构建缓存/证据文件自身） | 2026-10-16 03:01 | - |
| `verification.json` | 结构化验证记录（路由覆盖、错误映射、合同来源、缺口、未执行项） | 2026-10-16 | - |

清单树指纹（manifest 文件自身的 SHA-256）：
`5e84306db4f71fca4e84bd5c155ce3fefdff4eb0c01ce909d72a2a36ce95b010`

## 不可找回的原始记录（如实说明）

- 开发过程中第一轮测试的 10 项失败、第二轮 2 项失败的完整控制台输出未保存到持久介质，
  仅有修复提交在最终代码中体现（503 重试路径、pendingID 整数格式化、确定性 boundary、
  测试侧 multipart 解析器与合成 WAV 修复）。如需失败现场，只能重新构造，本目录不补造。
- Git 历史：本工程在 LHY-03 开发前无任何版本控制记录，`git init` 于 2026-10-16 执行，
  首次提交即为包含 LHY-03 成果的快照。LHY-03 开发前的中间状态不可追溯，不伪造历史提交。

## scratch-path 说明

构建与测试 scratch 位于 `/tmp`：项目目录在 iCloud 同步范围内，`.xctest` 会被 FinderInfo
xattr 污染导致 codesign 失败，该问题与代码无关。

## 合同来源与已知缺口

- 合同来源：`reference/api/` 四份 2026-10-15 文档（WAV_HTTP_API V1.1、含 15 个脱敏真实样例的
  STABLE_BASELINE 报告、EVENT_FINISH_REPORT、IOS_AUDIO_CONTRACT）。
- `Fitcore_Step2_LHY_API_Handoff_2026-10-15.zip` 在交付包中缺失（与 handoff/KNOWN_API_GAPS.md 一致）。
- 未冻结字段缺口（未臆造，详见 verification.json）：
  - GAP-PENDING-SHAPE：`/pending` item 完整 schema 未冻结，仅确认 pending_id/status。
  - GAP-PENDING-RESOLVE-BODY：resolve 请求体仅确认 resolution_id/action/context_version。
