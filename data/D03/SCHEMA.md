# d03-corpus-v1 字段字典

JSONL一行一个案例，schema_version整数1。revision是正整数；dataset_version为稳定匿名ID，单次检查不混用版本。case_id、source_group_id、near_duplicate_group_id均为1～80位字母数字/下划线/连字符ID，首位字母数字。

| 字段 | 要求 |
|---|---|
| text | 原始非空文本，不归一化覆盖原件；不能只含标点 |
| source_type | human_transcript / human_authored / model_generated，来源不可混称 |
| source_ref | 可追溯的来源/生成/编写批次；不填密钥或身份 |
| purpose | train / dev / test；保护文件才允许heldout，且检查不表示冻结审批 |
| review_status | 非真人开发案例目前只允许draft；真人转写要求reviewed D02证据 |
| categories | 非空、多选、无重复：completed_fact/historical/plan/numeric_ambiguity/correction/context/multi_intent/subjective/non_training/source_uncertain/exercise_alias |
| intents | 非空、多选、无重复：record_set/correct_set/plan/subjective_state/non_training/context/UNKNOWN；只是开发标签，未经人工金标验证 |

真人转写另需recording_id、d02_revision_id、segment_index正整数、source_sha256。source_ref固定`D02:REVISION_ID:SEGMENT_INDEX`；source_group_id在无D04分组时沿用recording_id，有私密GROUPS.csv时沿用其真实来源族，不能重新编号规避保护。工具核对当前D02最新已复核revision中的reference_text和实际WAV哈希。提供当前私密D01与D02根目录才能从CLI纳入；内部human_context参数只用于受信本地调用/合成单元测试，不是认证接口。

可选speaker_id_pseudonym/session_id/environment_id用于保护记录；真人保护集须齐备。当前真人的speaker/session由D01重新读取，environment和来源族来自可选D04 GROUPS.csv；缺少环境时不能宣称通过真人保护检查。给定保护集只是本地操作者提供的保护范围，不证明其完整或已获冻结批准。

相同source_group_id表示同一来源/派生族，近重复组记录人工认定的语义变体。词面normalization沿用D04（NFKC、casefold、去非字母数字），保留原text不改写。相似候选阈值由D04工具文档定义，不用于推断训练事实或人声来源。

报告仅返回数量、匿名ID、冲突分类，不输出原文。source_counts中的model_generated不计真人数量；保护集未提供/为空的状态不允许表述为“已证明无泄漏”。case级schema通过不等于reviewed、heldout、COMMIT正确或系统准确率。
