# D02 核验记录

2026-10-16，本机离线执行。准备工具已验证；真人标注、JZD 独立听音与双方验收待进行。D02 未读取真实私密库，不据此声称已有录音/授权/真值通过验收。

## 实际命令与结果

| 命令 | 退出码 | 实际结果 |
|---|---:|---|
| `python3 -B -m unittest discover -s data/D02/tests -p test_d02.py -k test_init_is_empty_private_and_refuses_overwrite -v`（实现前） | 1 | 1 测试失败；d02.py 尚不存在，init 尚不可用，符合预期 RED |
| `python3 -B -m unittest discover -s data/D02/tests -p test_d02.py -k test_dispute_cannot_be_cleared_by_new_draft -v`（对应修复前） | 1 | 本应拒绝的 redraft 被保存，预期 RED |
| `python3 -B -m unittest discover -s data/D02/tests -p test_d02.py -k test_old_gold_version_cannot_be_reused_for_changed_content -v`（对应修复前） | 1 | 本应拒绝的旧标签版本被重用，预期 RED |
| `python3 -B -m unittest discover -s data/D02/tests -p test_d02.py -k test_later_revision_cannot_invalidate_another_recordings_correction_target -v`（对应修复前） | 1 | 后续改稿使另一 recording 纠错目标不再是事实，本应拒绝却保存，预期 RED |
| `python3 -B -m unittest discover -s data/D02/tests -p test_d02.py -k test_future_or_hypothetical_correction_cannot_be_final_correction -v`（对应修复前） | 1 | planned 纠错本应拒绝却保存；后续子用例因该副作用报父版本冲突；修复后全部通过 |
| `python3 -B -m unittest discover -s data/D02/tests -p test_d02.py -k test_withdrawn_history_does_not_block_unrelated_queue_draft_or_active_api -v`（复核修复前） | 1 | withdrawn R01 的历史当前授权检查使 unrelated R02 队列失败，预期 RED |
| `python3 -B -m unittest discover -s data/D02/tests -p test_d02.py -k test_review_and_dispute_cannot_drop_semantic_context_metadata -v`（复核修复前） | 1 | review 可在原 gold_version 删除 context，预期 RED；后续 dispute 子用例因该副作用报父版本冲突 |
| `python3 -B -m unittest discover -s data/D02/tests -v`（最终） | 0 | **37 tests，6.266s，OK** |
| `python3 -B -m unittest discover -s data/D01/tests -v`（复核修复后） | 0 | **34 tests，3.494s，OK**；包含既有25项及新增来源校验9项，不是仅引用历史结果 |
| `python3 -B -m unittest discover -s data/D03/tests -v`（复核修复后） | 0 | **13 tests，0.068s，OK** |
| 原模板与 D02 模板逐字节比较、CSV 解析计数 | 0 | 完全相同；21列、0数据行 |
| `git diff --check`（只读） | 0 | 无空白错误；D02 为新增文件，未暂存 |

测试覆盖普通完成事实、计划/历史/主观/非训练/上下文、UNKNOWN、数字不清、目标未知、多动作/多意图、明确纠错/跨录音目标、逐字来源声明、严格列宽/JSON键/版本、重复片段/事件、并发父版本冲突、变更历史与快照篡改、不可悄悄删动作、独立署名、团队许可、争议及裁决、期限/撤回/时间/WAV哈希复验、符号链接/仓库路径阻断、独立ASR与私密错误脱敏。

最终37项测试共构造 **43个临时合成 WAV**（6项需两个不同 recording 验证跨录音引用、撤回隔离、团队权限排除和保留历史完整性），所有授权、人工稿、ASR及签名均为测试伪造，仅存在临时目录；无持久化语料。此前 RED/GREEN 重跑也仅使用临时合成输入，不能累计为真人数据。

复核修复将保留历史结构/哈希检查与当前用途准入分开。撤回、过期或团队许可失效的 recording 不进入 active latest/rows/CLI 投影或队列，按 ID/用途/原因报告；其他合格录音继续初标。依赖已排除来源的上下文/纠错内容一并排除，原修订和 ASR 字节不改。公共 `load_workspace` 仍为只读四元组；CLI 在锁内刷新可重建的当前 CSV 缓存。review/dispute/resolve 必须保留父版全部 segments 语义证据和原音频哈希；改证据需新标签版本。

## 文件签名（SHA-256）

| 文件 | SHA-256 |
|---|---|
| `scripts/d02.py` | `8321692b4902cfde4584a91f76fdc2c78d49e1e67b7ec6f5a4cec50d136a7164` |
| `tests/test_d02.py` | `cb12794fa929e780aba72711a7fed8cf641a6aa50ca4d8d34a8a26c8fabc6b7c` |
| `templates/ANNOTATIONS.csv` | `31c7b4f4c40d27ce5738d76ceef90ec478f7e9e17fb75da2b11736d9a4592001` |
| 本次复用的公共 `data/D01/scripts/d01.py` | `56334e58e057285d61cad4c3dc3e0d209a591e9df8b236cba14a6bde94b0f541` |

## 结果边界

- 真实初标0、实际第二人复核0、真实争议0、冻结0。当前已知2段 D01 均 needs_review，不进入本工具可标注队列；当前 team/cloud 未授权。
- 工具不会产生转写、补数字、提升 D01 人工来源状态、调用 ASR/模型、授予权限或冻结金标。source_listened/独立化名只能记录人的声明，不能认证身份或实际听音；需负责人保留实际操作证据。
- 已保存事件只读、hash 索引与父版本冲突核验提供本机可追溯性；有权限者可重写全部文件/索引，仍须受控备份和独立审核。中断导致孤立快照/不一致会拒绝，需负责人私下核对。
- 历史 `--as-of` 通过仅表示当时审计，不允许继续使用现已过期/撤回材料。实际操作应默认当前时间。Python 3.9+ 语法/标准库；本机运行环境为 Python 3.12，未在3.9解释器上实际执行。
- 独立 ZIP 的公共 D01 依赖、成员白名单、解压运行与 ZIP 哈希由总集成步骤核验；本任务未进行 Git 提交/推送或远程操作。
