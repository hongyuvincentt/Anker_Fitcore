# 其余 11 项任务的接手 Prompt

先将整个交接 ZIP 解压，在 Codex 中打开**解压根目录**。首次使用发送 `FIRST_RUN_PROMPT.md`；之后每次选下表一个 Prompt，复制全文发送。Prompt本身不会搬运工程，必须与整个源码目录一起交接。

不要同时让多个任务修改同一份 Xcode 工程。先完成最小可验证步骤，再更新实际状态；各项最终独立ZIP属于后续实施交付，不能将本文件当作已完成回执。

| 任务 | 可复制 Prompt | 顺序与条件 |
| --- | --- | --- |
| LHY-02 soundcore SDK | [LHY-02](prompts/LHY-02.md) | 可先准备；SDK另行授权迁移，真实硬件未到 |
| LHY-03 HTTP 客户端 | [LHY-03](prompts/LHY-03.md) | 下一个优先开发项；先离线合同测试 |
| LHY-04 训练 UI 联调 | [LHY-04](prompts/LHY-04.md) | 接LHY-03，保留当前布局 |
| LHY-05 采集管理 | [LHY-05](prompts/LHY-05.md) | 复用LHY-01和D01，不阻塞首批手工采集 |
| LHY-06 声纹界面 | [LHY-06](prompts/LHY-06.md) | 等真实来源/声纹合同，不能假验收 |
| LHY-07 AI问答建议 | [LHY-07](prompts/LHY-07.md) | 等真实接口；现有Mock可保留 |
| LHY-08 App集成 | [LHY-08](prompts/LHY-08.md) | 贯穿构建回归，主链03/04后整体验收 |
| D02 人工标注 | [D02](prompts/D02.md) | 实际授权录音到位后，JZD第二复核 |
| D03 语义语料库 | [D03](prompts/D03.md) | 先确定D04隔离规则，再扩充/调参 |
| D04 独立测试集 | [D04](prompts/D04.md) | 提前定规则，实际数据到位后冻结 |
| D05 量化评测 | [D05](prompts/D05.md) | 等D02/D04真实金标；无样本不造分数 |

[完整可复制合集](REMAINING_TASK_PROMPTS.md)包含上述11份全文，便于不用逐个打开文件时查看。
