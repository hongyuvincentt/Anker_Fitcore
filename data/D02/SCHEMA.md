# D02 字段与状态字典（v1）

原 `reference/task-package/templates/ANNOTATIONS.csv` 的 21 列和列序保持不变。文档 `temporal_modality → tense_or_modality`、`annotator_id → annotator_id_pseudonym`、`reviewer_id → reviewer_id_pseudonym`、`ambiguity → ambiguity_type`；speaker/session/consent 均通过 recording_id 只读关联 D01，不复制身份映射。

## ANNOTATIONS.csv

CSV 使用 UTF-8（可带 BOM）、准确表头/列宽。所有单元格为字符串，无首尾空白/NUL；不静默改大小写、去空格、猜数字或修表头。`UNKNOWN` 是明确未知，空值仅允许在下面指明的两列。所有行必须有变更理由和真实音频证据；主键 `(recording_id, segment_index)`。

| 列 | 约束及含义 |
|---|---|
| recording_id | D01 中当前合格来源 ID；一版 CSV 只包含一段 recording |
| segment_index | 稳定正整数，1 起；拒绝 01/负数/重复；一个动作或意图一行 |
| reference_text | 实际原音频逐字回听稿；不可听清时 UNKNOWN，保持待审；不得复制 ASR/文件名/脚本 |
| asr_hypothesis_separate | 必须空；独立 ASR JSON 关联原音频 |
| intent | record_set / correct_set / plan / subjective_state / non_training / context / UNKNOWN |
| exercise | 实际听清的动作名/别名；缺失 UNKNOWN，不用常识补齐 |
| weight_kg | 大于 0 的十进制公斤数，或 UNKNOWN；不接受 NaN/Infinity/指数/负数；不得猜换算 |
| reps | 正整数字符串或 UNKNOWN；拒绝 1.5/01 |
| set_index | 原音频明确组号，正整数字符串或 UNKNOWN |
| tense_or_modality | completed 当前已完成；historical 历史；planned 未来计划；hypothetical 假设；subjective 主观；non_training 非训练；context 上下文；UNKNOWN |
| is_correction | true / false / UNKNOWN；不能以计划、历史或代词默认修改当前组 |
| target_set_reference | 明确纠错目标 `<recording_id>:<segment_index>`，须指向现有 completed/historical 的 record_set；否则 UNKNOWN |
| subjective_state | 原音频主观感受文字；未提供或不清晰 UNKNOWN |
| ambiguity_type | none / numeric_unclear / target_unclear / context_missing / audio_unclear / source_uncertain 等明确说明；词表允许扩展，禁止空 |
| gold_decision | COMMIT / CORRECT / DEFER / IGNORE / UNKNOWN，表示人工语义标签，不触发真实系统记账 |
| annotator_id_pseudonym | 实际初标者化名；draft/revise 必须等于该事件 actor；不填实名/电话 |
| reviewer_id_pseudonym | draft/needs_review 时空；review/dispute/resolve 填实际独立听音者化名 |
| review_status | draft 初稿 / needs_review 待审 / disputed 待裁决 / reviewed 已记录独立复核；上游 needs_audio_review 显式映射为 needs_review |
| gold_version | 单个 recording 的标签版本；draft/revise 使用未用过的新版本，review/dispute/resolve 保留内容版本；不表示冻结 |
| evidence_reference | `audio:<recording_id>#t=<start_sec>,<end_sec>`；指向原音频，不放私密绝对路径；与附属证据时间一致 |
| change_reason | 当前行初标/改动/复核/争议/裁决的真实理由；不允许空或为提高模型得分偷偷改标 |

ID/版本使用 1–80 位 ASCII 字母、数字、`_`、`-`，首字符为字母或数字。动作名和参考文字允许中文。`COMMIT` 只允许 `record_set + completed + is_correction=false` 且动作/重量/次数/组号均已知、ambiguity_type=none。计划、历史、主观与非训练句不能 COMMIT。纠错目标 UNKNOWN 时必须 DEFER/UNKNOWN 并保留歧义；明确纠错目标不得指向自身或不存在片段。`CORRECT` 需要 `is_correction=true`、`intent=correct_set`、已知目标和 completed/historical 的事实时态；计划/假设/未知时态不能当成实际纠错。

同一句有两动作或多个意图时拆成多行，保留各自 reference 和事实；时间范围可重叠。例如先记录事实、再纠错，可为 1/2 两行，第二行通过 target_set_reference 指向第一行。跨 recording 的历史目标必须已存在于本机合格标注集合。无法唯一定位“上一组”时用 UNKNOWN，不随便绑定最近一组。

## REVISION.json 输入与保存快照

版本为整数 `schema_version=1`，不接受额外/重复 JSON 键，非有限 JSON 数字、缺键或错误类型。空模板须真人填写后才可提交。

| 键 | 含义 |
|---|---|
| recording_id / revision_id | D01 ID / 全历史唯一不可覆盖的事件 ID |
| parent_revision_id | 首版 null；后续必须等于该 recording 当前 revision，配合 CLI expected-revision 防冲突 |
| actor_id_pseudonym | 实际执行该事件的人；与元数据实际签名一致 |
| at | 实际听音/操作的带时区 ISO8601 时间；不早于录音和父版本，不晚于 as-of |
| event | draft / revise / review / dispute / resolve；转换规则见 README |
| reason | 事件整体真实理由；争议写明不一致，resolve 记录实际裁决依据 |
| source_listened | JSON 布尔，必须手工明确 true；仅作听音声明，工具不能验证人是否真的听过 |
| source_sha256 | 当前原始 D01 WAV 的 SHA-256，与录音证据绑定；不接受 ASR/派生音频的哈希 |
| segments | 每行恰好一份证据对象，见下；不得漏片段 |
| adjudicator_id_pseudonym | 非 resolve 必须空；resolve 必须等于 actor，且不同于初标者和前次争议人 |

每个 segments 对象**恰好**包含：整数 `segment_index`、有限数字 `start_sec` / `end_sec`（`0 <= start < end <= 原音频时长`）、`context`（关联片段键字符串列表，不重复、不引用自身）、`correction_target`（同 CSV target_set_reference）。所有引用必须可解析，不能以字符串描述代替明确关系。原始 WAV 不裁切、不覆盖，时间只作引用。

保存工件 `revisions/<revision_id>.json` 恰好包含 `metadata` 与原 21 列 `annotations` 行快照；HISTORY.jsonl 每行 `{revision_id, sha256}`。不同版本保存不可变快照。review/dispute/resolve 不得改变父版的 `segments` 或 `source_sha256`；语义证据变化必须走初标者新版本。dispute/resolve 是真实署名事件和裁决日志，不是自动批准。保留历史始终检查结构/源音频绑定/快照哈希；当前使用另按 recording 检查用途授权。权限失效仅从当前集合排除受影响记录及其上下文依赖，保留原审计字节，不反推历史授权。CLI 重建原21列当前合格投影缓存，API 返回当前合格行但不写缓存；缓存不可改文字/删半组，不能当成无需复核权限的独立金标。哈希不构成密码签名，也不能防止有权限者重写全部文件和索引；负责人须保管受控备份及真实署名证据。

## ASR.json 可选工件

恰好包含 `schema_version=1`、`artifact_id`、`recording_id`、`source_sha256`、非空 `hypothesis`、`origin=offline_import`、非空 `model_version`。工件 ID 唯一；记录原 WAV 哈希并再次核验本机许可，文件单独只读保存。无需 ASR 即可完成初标/复核；导入不会影响 reference，且不证明 ASR 历史来源或允许云处理。ASR 工件不属于人工金标版本或数字准确率的实测证据。
