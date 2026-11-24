# 本轮检查与复查 · 2026-10-16

> 历史源快照：本文件保留原独立数据仓库的计划/核验记录，并非当前状态。最新变更：私有remote已确认、173测试通过、原始sidecar补入2份、本人回听仍待确认，参见 [本轮整合交接](INTEGRATION_2026-10-16.md)。

数据目录隔离实现，不改iOS、Xcode、HTTP/共享服务接口、后端或AWS，不调用付费模型，不向JZD/云发送真实内容。保留原13列consent、19列manifest、21列ANNOTATIONS、12列SPLITS及原EVAL_RESULTS列；附属记录有明确task-local字典。

## 实际本机回归

`python3 -B scripts/verify_data.py`（Python3.12）退出0：D01 34、D02 37、D03 13、D04 38、D05 48，共170测试，全部通过。测试只生成临时合成夹具，不留存真人/合成音频。具体各项命令、红绿证据见任务README与verification/VERIFICATION。

新临时目录的CLI试跑：D01空库init → D02空目录init/queue → D03检查24条模型草稿 → D04空计划check(not_frozen) → D05空输入报告与1条明确synthetic的计算示例，7条命令退出0。空报告各比率、延迟和总费用均null/unmeasured；synthetic输出只标计算测试。独立ZIP另在新解压目录执行各任务测试并记录包外回执。

开发期间的集成试跑曾碰到D02正在补写的RED测试，不将该轮称为通过；所有修复稳定后才得到上述170项通过。CLI试跑脚本最初错误假设D05标准输出是JSON、空报告没有组；按实际CLI/报告合同调整验证后7条试跑通过，未改业务工具来迎合错误假设。

## 独立复查与关闭

| 问题 | 修复与回归 |
|---|---|
| 单个撤销/到期样本阻断整个D02历史与其他可用样本 | 历史完整性与当前用途分开；受影响记录及依赖上下文退出活跃集，其他录音可继续排队/初标，历史原件保留；复查者重现确认关闭 |
| 相同gold_version的review可悄改片段上下文 | review/dispute/resolve绑定完整segments与源哈希；改变须新作者修订与版本；复查者确认拒绝旧复现 |
| 排除/改分组后的历史开发曝光未沿speaker/session/environment阻断heldout | 不论当前split/excluded，历史曝光均沿严格身份域及同源关系传播；4项回归先失败后通过，复查者确认freeze仍not_frozen |
| reviewed gold的unknown/null时间语义被漏出分母 | reviewed状态拒绝未解决时间语义，unreviewed/disputed明确排除；3项回归，复查者确认旧复现已拒绝 |
| D03同录音换case/group及缺真人分组证据的保护缺口 | 检查原recording、speaker/session/environment和D04来源族；证据缺失阻断；13项测试通过，独立复查确认关键回归 |

## 真人和审批边界

只读核查2段、1名声明说话者、均needs_review；本机用途有效，team/cloud=false；原sidecar留存0。未播放/替人回听、未运行verify-human、未改私密库、未写真人转写、未生成实际授权或签署人工复核/冻结。

只有一个人的试点不能证明跨说话者泛化。未来独立样本先按D04预留、人工审核/批准，再冻结真实文件和标签hash。保护JSON、人工化名与文件hash只能证明给定材料一致，不证明授权或身份真实性；词面相似度不保证覆盖所有语义改写；费用证据hash不等于独立账单验证。

Git已提供本地每任务branch/commit；数据remote暂未确认，未配置remote/推送/PR，也不猜测地址。测试通过不等于真人数据、独立集和实际系统验收完成。
