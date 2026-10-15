# LHY-03 · BackendHTTPClient：统一云端 API 客户端

- **领域：** iOS
- **负责人（本次交接后）：** LHY
- **原负责人：** LHY
- **协助/审查：** Codex 提供并冻结 API 合同
- **优先级：** P0
- **建议阶段：** 比赛前主链
- **当前证据状态：** 待验收／实际进度待核查
- **代码或清单仓库：** `fitcore-ios`
- **依赖：** E03；LHY-01

## 目标
实现 iOS 对现有稳定 FastAPI 的完整异步工作流，可使用同一接口契约供 Android 复用。

## 必须交付
- 独立 HTTP Client，使用环境注入 Base URL 与演示认证
- 创建 Session、WAV 上传、Job 轮询、Facts/Pending/Events、Finish/Review
- API Mock 合同测试、超时/409/401/重试场景
- 安全错误日志，输出请求关联 ID 而不记录 Token/私人 WAV

## 验收标准
- 使用 OpenAPI 实际字段：上传 file、utterance_id、sequence；必要时 audio_source 依合同
- 202 表示任务被接受或 draining，不是最终 AI 完成；Job done 前不展示正式事实
- 同一上传重试复用 utterance_id/sequence/相同字节，避免重复扣费或新增事实
- Finish 202/draining、409 awaiting_audio、Review 409 等分支被正确处理；不能“空成功”
- 401/403 明确提示，测试文本端点不对公网客户端开放

## 注意事项
公网地址 https://54-254-212-127.sslip.io 是临时 Demo 域名；变更公网 IP 后可能失效。HTTP Token 不得编译进公开客户端。

## 提交回执（由LHY填写）
- Git branch / commit / PR：待填
- Xcode 或 Python 检查结果：待填
- Mock/真机/真实模型类型：待填
- 证据位置（不含密钥或私人音频）：待填
- 阻断与下次交接时间：待填
- 复核人：待填
