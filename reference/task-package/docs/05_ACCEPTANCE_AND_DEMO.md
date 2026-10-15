# 05 · 验收分层与里程碑

## Milestone A：最小可交付产品（优先）
1. LHY-01：iPhone 真机产出有效 WAV。
2. LHY-03：Mock API 任务链条全通，正确处理 202/409/重复提交。
3. LHY-04：能分别展示 Processing、Facts、Pending、Finish、Review。
4. LHY-02：SDK真实硬件路径若可用，完成录音豆真机采集；不可用则明确阻塞并保留手机录音备份。
5. LHY-08：同一 Commit 的 Xcode 构建证据、真机录屏与可重复演示步骤。

## Milestone B：授权语料最小闭环
1. D01：取得同意的新增真人样本和匿名 manifest（可先小样本，按实际数量报告）。
2. D02：原音频、人工参考、ASR 模型输出严格分开；有抽查/审核记录。
3. D03–D05：作为数据质量与泛化能力长期工作，比赛前如时间紧，不允许拿不完整测试集冒充可信准确率。

## Milestone C：联调条件（不自动执行）
- Codex 提供冻结 OpenAPI 版本，用户批准单次真实云端模型测试；LHY 用授权 WAV。
- 真机音频 → 统一HTTPS API → 异步Job → Facts 或 Pending → Finish/Review；保持正式事实的服务端权威来源。
- 当前线上正常信任开关为 false；如果遇到 SOURCE_UNCERTAIN 是预期安全行为。需要另行授权的单人演示，不可自行改 AWS 配置。

## Milestone D：Demo 故障备用
- Mock 或录屏需要显著标注，确保现场离线展示不造假。
- 网络、设备、模型超时均需明确降级路径与错误说明。
- 任何“已经完成”的声明都必须有 Git SHA / 构建结果 / 真机或Mock日志支撑。

详见 `checklists/RELEASE_ACCEPTANCE.csv`，每一行由 LHY 填入证据链接，再由你审核。
