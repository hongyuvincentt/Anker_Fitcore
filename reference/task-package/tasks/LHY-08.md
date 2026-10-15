# LHY-08 · 完整 iOS App 集成与真机交付

- **领域：** iOS
- **负责人（本次交接后）：** LHY
- **原负责人：** LHY
- **协助/审查：** 你主验收；Codex 审查合并和 API 证据
- **优先级：** P0
- **建议阶段：** 比赛前主链
- **当前证据状态：** 待验收／实际进度待核查
- **代码或清单仓库：** `fitcore-ios`
- **依赖：** LHY-01、02、03、04；E02

## 目标
在同一可追溯 Git Commit 上，将音频输入、网络客户端、训练 UI 和 Review 形成可复现 Demo。

## 必须交付
- Xcode 项目可构建 Commit/PR
- iPhone 真机构建日志与操作视频
- Mock WAV 演示及真实硬件状态说明
- 集成错误清单、恢复策略、联调交接记录

## 验收标准
- 相同 Commit 下可以构建、启动、演示，提交测试日志和视频
- 至少 Mock 音频全链路可重放，真实 soundcore 链路仅在实际硬件通过后宣布完成
- 音频上传、Job、Facts/Pending、Finish/Review 在 UI 上完整显示
- 无网/失去设备/超时有演示降级路径，能清楚区别真实与录屏

## 注意事项
LHY 的 Mac 源码通过私有 PR/只读 fetch 汇总至 Windows；不得把 .pem、真实 Token、授权 WAV 推进 Git。

## 提交回执（由LHY填写）
- Git branch / commit / PR：待填
- Xcode 或 Python 检查结果：待填
- Mock/真机/真实模型类型：待填
- 证据位置（不含密钥或私人音频）：待填
- 阻断与下次交接时间：待填
- 复核人：待填
