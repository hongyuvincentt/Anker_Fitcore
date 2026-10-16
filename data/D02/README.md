# D02：离线人工标注与版本记录

本任务只提供工具和空模板。已知当前私密 D01 有 2 段 `needs_review` 录音；D02 未访问该私密库，实际初标 **0**、JZD 实际复核 **0**、争议记录 **0**、冻结 **0**。当前只有本机用途授权，不能开始第二人音频复核。测试中的录音、授权和文字全部临时合成，不能计入真人成果。

Python 3.9+，仅标准库；离线运行，不调用模型或网络，不修改 D01。先读 [字段字典](SCHEMA.md) 和 [核验记录](VERIFICATION.md)。完整仓库从相邻 `data/D01/scripts/d01.py` 复用加载/格式/哈希/授权校验；独立 ZIP 必须带公共依赖 `D02-delivery/dependencies/D01/scripts/d01.py`，不得带真实 CSV 行或音频。

## 输入与私密目录

D01 私密目录已有原始 `audio/`、19 列 `WAV_MANIFEST.csv`、13 列 `CONSENT_REGISTER.csv`。D02 只接受已人工确认来源的 `human_verified` 录音，并在每次队列、保存、校验时重新核验当前授权、期限、撤回、时间和 WAV 哈希。不再合格的 recording 按匿名 ID/用途/原因列为 excluded，仅排除该记录及依赖它的上下文/纠错内容；其他合格录音可继续排队和初标。原修订/ASR 审计文件保留，不以当前授权反推历史授权。实际回听和 D01 `verify-human` 须由真人先完成；D02 不提供这一提升操作。

以下命令的 `/canonical/private/...` 是占位符，请换成自己有权使用的规范绝对路径。路径不得位于仓库/ZIP目录；不得含 `..` 或任何符号链接，包括父目录。macOS `/var`、`/tmp` 可能为系统符号链接，先用 `realpath` 获取实际 `/private/...` 路径。D01 和 D02 根目录均须仅本人可访问（权限 `700`）。

```sh
python3 data/D02/scripts/d02.py init --root /canonical/private/annotations --source-root /canonical/private/collection --local-annotator LHY
python3 data/D02/scripts/d02.py queue --root /canonical/private/annotations --source-root /canonical/private/collection
python3 data/D02/scripts/d02.py validate --root /canonical/private/annotations --source-root /canonical/private/collection
```

独立包把 `data/D02/scripts/d02.py` 换成 `scripts/d02.py`。`init` 只创建空目录；已有目录拒绝覆盖。零条合格来源也可初始化。默认以当前上海时间检查；`--as-of` 仅供可复现历史审计，历史通过不能表示现在可使用。退出码：成功 `0`，数据/权限/冲突错误 `2`；结果和错误均为 JSON，不输出文本、音频内容或私密绝对路径。

```text
private-D02/
  CONFIG.json                    本机标注者化名，初始化后只读
  inputs/                        操作者私下编辑的 CSV/JSON 稿件
  reference/ANNOTATIONS.csv       原 21 列当前合格内容缓存，CLI 每次重新投影
  revisions/<revision_id>.json    每次完整快照、证据、署名与争议/裁决理由
  HISTORY.jsonl                  revision_id 与 SHA-256 索引
  asr/<artifact_id>.json          可选 ASR 假设，独立于 reference
```

原音频只在 D01；人工文本只在 D02 私密 reference/revisions；ASR 只在独立 asr。身份映射、姓名、联系方式、授权原件不得写入标注。化名不自动等于可公开。

## 从真实回听稿保存一版

1. 从 `templates/ANNOTATIONS.csv`、`templates/REVISION.json` 各复制一份到私密 `inputs/`。先回听实际原音频，再手填 CSV 和元数据；不得根据文件名、朗读脚本、ASR 或算法预期补全文字/数字。
2. 一次输入一个 recording 的**完整**片段集合。一个动作/意图一行，同一句多动作可用重叠时间区间；`segment_index` 为唯一稳定正整数。不能用新版本悄悄删除已有片段。缺失信息填 `UNKNOWN`，不清楚的数字/对象用 `DEFER` 与 `needs_review`。
3. 元数据记录实际标注者、真实回听时间、当前原音频 SHA-256、每个片段时间及上下文/纠错引用；`source_listened` 只能在实际回听后手工置 `true`。`evidence_reference` 使用 `audio:<recording_id>#t=<起秒>,<止秒>`，须与元数据时间一致。
4. 首次用 `event=draft`、`parent_revision_id=null`，唯一 `revision_id`，自定唯一标签版本 `gold_version`。`reviewer_id_pseudonym` 空，状态 `draft` 或 `needs_review`。保存：

```sh
python3 data/D02/scripts/d02.py revise --root /canonical/private/annotations --source-root /canonical/private/collection --input /canonical/private/annotations/inputs/ANNOTATIONS.csv --metadata /canonical/private/annotations/inputs/REVISION.json --expected-revision NONE
```

后续改稿使用 `event=revise`、新的 `revision_id` 和从未用过的 `gold_version`；`parent_revision_id`、`--expected-revision` 均填队列给出的当前 revision。必须写实际变更原因和原音频证据；保存后仍为初稿，旧快照不会覆盖。不得为提高模型分数改标准。并发使用过时父版本会拒绝。

## 实际第二人复核与争议

LHY 是本机初标者；JZD 使用其真实的、独立的化名签名。先取得当前团队内部使用授权，再受控分享。`local` 不推导 `team` 或 `cloud`；`queue --purpose team` 可检查可共享队列。第二人即使只参与初稿也需要团队许可。Codex 的工具/方法检查不等于人工听音，也不填写第二人签名。

JZD 实际独立回听后，将元数据 `event` 改为 `review`、actor 改为 JZD 化名、写真实回听时间和理由、填新 revision 与当前父 revision；CSV 保持内容和 `gold_version`，只将 reviewer 填为实际 JZD 化名，状态置 `reviewed`，可更新 `change_reason`。同一人不能用同一化名自签；工具不能认证化名背后的人，实际身份独立性由负责人核查。

发现不一致用 `event=dispute`、`review_status=disputed` 和逐片段 `change_reason`，元数据 `reason` 说明争议与建议。`queue` 列出待裁决片段编号；历史快照保存完整意见。争议不能靠新初稿或普通 review 清除。用户实际裁决后，以 `event=resolve`、其独立 actor/adjudicator 化名、实际回听及裁决理由生成新 revision；该人须不同于初标者及上次争议提出者。resolve 接受当前内容；若最终要修内容，先记录裁决，再按新 `gold_version` 提交改稿并重新独立复核。未实际裁决时保持争议。

这些事件使用同一 `revise` 命令，`--expected-revision` 必须指向当前版本。审查只允许签名/状态/变更理由改变；reference、语义标签及 `segments` 中的时间/上下文/纠错关系和源音频哈希必须与父版完全相同，改变这些证据须初标者提交新标签版本。每份已保存快照均只读、哈希校验；既有文件缺失、被改、存在孤立快照或当前 CSV 内容/片段组与历史冲突均阻断。`reference/ANNOTATIONS.csv` 是可重建缓存：CLI 在结构/哈希检查后按当前用途重投影，移除失效完整 recording 组，不改历史；只读 API 不写缓存。中断遗留锁或历史不完整须负责人私下核对，工具不自动修复历史。

`reviewed` 仅表示记录了实际双人回听流程，不表示 D04 已冻结。没有冻结命令或自动批准，所有结果 `frozen_segments=0`。团队授权撤回/到期后，受影响的当前双人内容从可用集合、队列和 CLI 投影排除，原双人历史保留审计；不能以本机许可继续使用该复核版本。`validate` 返回当前可用计数、`retained_history_recordings`、`excluded_recordings` 及匿名原因；valid=true 不表示 excluded 内容仍可使用。

## 可选 ASR 诊断

只导入已有且获准使用的离线结果；工具不执行 ASR。私密填写 `templates/ASR.json`（原音频哈希、匿名 ID、模型版本、假设文字），然后：

```sh
python3 data/D02/scripts/d02.py attach-asr --root /canonical/private/annotations --source-root /canonical/private/collection --input /canonical/private/annotations/inputs/ASR.json
```

ASR 保存为单独只读工件，按 ID 与原 WAV 哈希关联，绝不写入人工参考 CSV；原列 `asr_hypothesis_separate` 必须为空。授权失效后工件原字节保留审计，计入 `excluded_asr_artifacts`，不计入当前 `asr_artifacts`，不阻断其他录音。导入不证明历史模型调用曾获许可。任何云处理仍须参与者对应许可及用户对服务/范围/预算的明确批准。

## 可调用入口与检查

`scripts/d02.py` 导出 `source_store(source_root, when)`、`require_source(recording_id, consents, recordings, purpose, when)`、`validate_revision(record, previous, all_rows, config, consents, recordings, when, check_current=True)`、`load_workspace(root, consents, recordings, when)`、`run(args)`、`main(argv=None)`。`load_workspace` 保持四元组 `(config, latest_by_recording, revision_ids, current_rows)` 且只读：latest/current_rows **只含当前用途合格内容**，revision_ids 包含全部保留历史，不用于认定当前可用数；其前置调用应先检查私密根路径（CLI 已做）。该 API 不刷新磁盘缓存，直接读取 CSV 的使用方须先运行 CLI 校验。内部 `load_history` 只验证保留快照结构/哈希，使用 `check_current=False` 不代表历史曾有权限，更不代表现在可用。`d01.eligible(consents, rows, purpose, when)` 保持原接口。所有工具写入通过 CLI 的锁和完整校验，集成方应优先调用 `main`/`run`，不得用内部历史校验替代当前用途准入。

```sh
python3 -B -m unittest discover -s data/D02/tests -v
python3 -B -m unittest discover -s data/D01/tests -v
```

测试临时生成合成音频和伪造测试授权，标明 `TEST-*`；测试结束清理临时目录。仓库只保留空模板、源码与测试，不含实际授权、音频、私人文本或已冻结金标。负责人仍须完成真人采集、人工来源确认、独立听音、争议裁决和冻结审批。
