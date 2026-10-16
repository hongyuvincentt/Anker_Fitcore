# D04 · 分组隔离与人工冻结记录核验

Python 3.9+ 标准库、完全离线、只读。工具检查输入，不切分原音频、不写金标、不生成冻结批准。当前仓库只有空模板和临时 synthetic 测试，没有实际 held-out、实际人工金标、实际冻结或审批。已知来源基线为私密库 2 段、1 名说话者、两段 `needs_review`、当前已复核可用 0；本任务未读取该私密库。首批独立测试仍需真实补采和人工复核。

`SPLITS.csv` 保留任务包原始 12 列，字节也保持一致。D01 的 `scene_id=ordinary/numeric_ambiguity/...` 是**语义类别**；真实录制环境另存 `GROUPS.csv.environment_id`。不能把普通表达和数字歧义当成两间录音环境。

## 本机使用

将空模板复制到已授权的私密工作目录，按实际证据填写。原音频、原始/历史金标及人工记录保留原位、保留原字节；派生件使用独立文件并沿用祖先来源组。禁止将这些私密文件复制进本仓库。

空计划检查（退出码 0，`status=empty`、`freeze.status=not_frozen`）：

```sh
python3 -B data/D04/scripts/d04.py check \
  --splits data/D04/templates/SPLITS.csv \
  --groups data/D04/templates/GROUPS.csv \
  --exposure data/D04/templates/EXPOSURE.csv
```

实际清单每次使用前重新执行 D01 的 `eligible --purpose local`，将 JSON 输出保存在私密位置。D01 会重新检查当前授权、来源人工复核、文件哈希及格式。D04 要求该报告，核对用途、时间、排除记录以及 recording/speaker/session/scene/audio-hash/已人工核验来源。`team`/`cloud` 报告不能替代本地授权；`local` 报告也不授予团队、独立外部审核人或云端使用权。

```sh
python3 -B data/D01/scripts/d01.py eligible \
  --root /PRIVATE_LOCATION/d01-collection --purpose local

python3 -B data/D04/scripts/d04.py check \
  --splits /PRIVATE_LOCATION/d04/SPLITS.csv \
  --groups /PRIVATE_LOCATION/d04/GROUPS.csv \
  --exposure /PRIVATE_LOCATION/d04/EXPOSURE.csv \
  --artifact-root /PRIVATE_LOCATION/d04 \
  --eligibility /PRIVATE_LOCATION/d04/current-local-eligibility.json
```

默认报告时间不得晚于检查时间，且最多早 300 秒；最好在同一操作中生成并立即使用。`--as-of` 是重现历史核验用的时区 ISO8601 时间，必须与报告 `as_of` 精确对应，且不能晚于实际当前时间。历史成功只表示该时刻的证据，不能代替今天的授权检查。报告是 D01 的本地证据快照，不能认证人的身份，也无法证明快照之后没有撤回；需要继续使用时重新产生报告。不要手写 `eligible` 数组来声称实际录音已通过 D01。

## 字段字典

所有 CSV 都需要精确表头和每行完整列数，UTF-8（可有 BOM）。ID 使用 1～80 个 ASCII 字母、数字、`_`、`-`，首字符为字母或数字。未知值不是有效 ID。模板只有表头，没有案例或私人内容。

| 文件 | 精确列序/规则 |
|---|---|
| `SPLITS.csv` | `recording_id,speaker_id_pseudonym,session_id,scene_id,dataset_version,split_train_dev_heldout,frozen_at,sha256_audio,sha256_gold,split_review_owner,is_excluded,exclusion_reason` |
| `GROUPS.csv` | `recording_id,environment_id,source_group_id,near_duplicate_group_id,source_kind,audio_path,gold_path,gold_review_status,gold_version,text_path` |
| `EXPOSURE.csv` | `recording_id,use,used_at,evidence_ref` |
| `ACCESS_LOG.csv` | `access_id,recording_id,accessed_at,actor_id,use,approval_ref,dataset_version` |

`SPLITS.csv`：每个 recording 唯一、dataset_version 一致；split 为 `train/dev/heldout`；排除状态为 `true/false`，排除时必须记录原因。SHA-256 为 64 位小写十六进制，必须来自实际文件。尚未批准时 `frozen_at/split_review_owner` 留空；填写它们不会获得冻结状态。

`GROUPS.csv`：每个 recording 恰好一个映射，不能缺组或多组。

- `environment_id`：真实录制位置及条件的匿名组，同一环境不可通过换 ID 冒充独立环境；不得使用 D01 语义 scene 代替。空白/UNKNOWN/pending/unassigned/none/n/a 都阻断。
- `source_group_id`：同一原始来源及其裁切、去噪、转写、改写、派生样本共享祖先组；不是“给每个派生件随便一个新 ID”。
- `near_duplicate_group_id`：经检查确认近重复的一族共享组；没有已知近重复的来源使用自己的稳定组。来源组和近重复组均必填；组关系真实性、未申报语义重复须独立人工复核。
- `source_kind`：`human_recording/derived_audio/synthetic`。前两项必须提供当前 D01 本地 eligibility；synthetic 不计入真人/人数覆盖，也不能进入独立真人 held-out。
- `audio_path/gold_path`：`--artifact-root` 内的相对 POSIX 文件路径，禁止绝对路径、`..`、空路径和任何 symlink。不得为便利复制或重建当前缺失的原始文件。工具只读并核对实际字节哈希。金标须是该 recording 的完整版本化原始审核制品，包含全部 D02 segments；不能用截取一个片段来替代多意图标签，也不能把包含 train/dev 真值的整份共享标注表当成独立 held-out 金标。
- `gold_review_status`：`unreviewed/needs_review/reviewed/disputed`；`gold_version` 必填。单次 `check` 不会更改人工状态；冻结要求 `reviewed` 和下述实际双人审核记录。
- `text_path`：可选的私密 UTF-8 纯文本来源，用于检查跨边界文字近重复。只读取，不在 JSON 中输出原文。不提供时仅执行显式近重复组与文件哈希检查；JSON 的 `text_checked` 明示分母，不能声称已检查全部语义重复。

`EXPOSURE.csv` 保存冻结前已发生的完整使用历史：`use` 为 `development/regression/example/train/dev/prompt/tuning/annotation/independent_review/heldout_evaluation`；`used_at` 为带时区 ISO8601，不能在检查时刻之后；`evidence_ref` 指向私密、可追溯的实际使用记录。未知 recording、空证据、重复事件或未知 use 均阻断。即使旧 development 行被排除，仍保留该行和其使用历史；排除不能洗掉污染。

`ACCESS_LOG.csv` 是冻结后的独立私密访问账本：`access_id` 唯一，`actor_id` 为化名，时间位于冻结后至检查时刻，版本必须匹配，`approval_ref` 引用实际授权/访问记录，use 与上表一致。每次查看或运行 held-out 都手工记录 actor、时间、用途和证据，不让开发人员查看真值调参。工具不写访问记录，不认证身份，也不能发现被故意删掉或未登记的访问；独立审核人须核对实际权限/访问记录的完整性。账本保留追加历史和外部归档；输出当前账本 SHA-256 供核对。

## 隔离规则与结果

train 和 dev 同属开发域，可以共享开发分组。有效 held-out 与所有开发行（包括已排除的旧开发行）之间不得共享 speaker、session、真实 environment、source_group、near_duplicate_group、audio SHA 或 gold SHA。相同语义 scene 本身不会触发环境泄漏。`text_path` 两侧均存在时，工具另外执行 NFKC、大小写和字母数字规范化后的 exact match，以及长度至少 8 字符、SequenceMatcher 比例至少 0.85 的近重复候选检查。

这些字面规则会保守地拒绝只改数字等近似表述，不能覆盖所有同义改写、跨语言复述或未登记的音频派生；必须同时保留人工来源/近重复组并复核。缺组或未知环境不具备冻结条件。曾用于开发、示例、回归、prompt 或调参的行，无论当前 split 改成什么、是否已排除，仍属开发域；有效 held-out 不得与这些历史行共享 speaker、session、真实 environment、来源/近重复组、文件哈希或近似文本。冻结审批不能清除这类污染。

结果是无私人文本的 JSON：

- `status`：`empty/clean/blocked`；`errors` 为 `{code,recording_ids}` 列表；有阻断项退出 1，结构/隔离通过退出 0。空计划退出 0 表示软件输入有效，不能称验收完成。
- `coverage`：未排除 recording 分母、真人 recording、真人 speaker、session/environment、by_split/by_scene/by_source，以及已读 text 数。synthetic 不计真人数/人数。排除记录另计，污染检查仍保留历史。
- `acceptance`：空为 `not_accepted`；不足两个真人说话者或缺开发/held-out一侧为 `exploratory_pilot_only`（严格评测被阻断）；有其他问题为 `blocked`；检查通过仅为 `pending_independent_review`。达到最小计数也不证明泛化。
- `freeze.status`：`check` 永远为 `not_frozen`。真人单说话者只可试点；不能改 ID、加入 synthetic 说话者或把旧开发样本改 split 来声称跨说话者泛化。

给 D03/D05 的 Python 入口：

```python
check_plan(splits_path, groups_path, exposure_path,
           artifact_root=None, eligibility_path=None, as_of=None)
text_duplicate_kind(left, right)  # normalized_exact / near_duplicate / None
verify_freeze(freeze_path, expected_sha256, splits_path, groups_path, exposure_path,
              artifact_root=None, eligibility_path=None, access_log_path=None, as_of=None)
```

可通过 `importlib.util.spec_from_file_location` 加载脚本，无安装步骤；后两个函数按其实际签名使用关键字参数。D03 在新增开发案例前应先检查 D04 的实际保护输入；没有已审核 held-out 时如实记录 0，不得把不明来源当作安全来源。保留预留说话者/环境见 [SAMPLING_PLAN.md](SAMPLING_PLAN.md)。

## 外部批准与冻结记录

本工具没有 freeze、approve、自动签字或自动改金标命令。独立审核人先核对原始音频、完整 D02 人工金标、当前权限、所有来源组/使用历史、覆盖分母和访问控制，再由用户本人或独立于收集/调参者的审核人作出实际决定。不同团队成员查阅内容前另查 D01 team 权限；当前 local-only 不满足该权限。实际审批之前保持 `not_frozen`。

核验一个已经由外部批准并归档的 `d04-freeze-v1` JSON，需要以下精确顶层字段（没有预填 approved 模板）：

| 字段 | 实际证据要求 |
|---|---|
| `schema_version` | `d04-freeze-v1` |
| `dataset_version/gold_version/frozen_at` | 实际版本与带时区冻结时间；所有 held-out 行版本/时间一致 |
| `preparer_id/tuner_ids` | 实际制作方及调参方化名，后者为列表 |
| `approval` | 恰好 `decision,reviewer_id,role,approved_at,evidence_ref`；必须实际 approved，role 为 user 或 independent_reviewer；后者不能是 preparer/tuner；批准时间不早于冻结且不晚于检查；可核查的外部人类批准记录 |
| `files` | 恰好 splits/groups/exposure；每项恰好 `{path,sha256}`，实际根目录内相对路径及实际完整文件哈希，禁止换文件/漏项/新增任意项 |
| `artifacts` | 所有 split 行的精确 recording 集合，每项恰好 `audio_path,audio_sha256,gold_path,gold_sha256,text_path,text_sha256`；必须与实际映射、文件和哈希对应；未提供 text 时两项都是空字符串 |
| `gold_reviews` | 所有有效 held-out recording 的精确集合；每项恰好 `reviewer_ids,reviewed_at,gold_version,sha256_gold`，至少两个不同的实际人工审核人，审核不晚于冻结，版本/哈希匹配原始金标 |

冻结 JSON 的 SHA-256 必须由外部批准记录另行保存、可信取得。不要先修改 JSON 再用修改后的自行计算值冒充已批准哈希。工具能够发现相对于可信哈希的文件篡改，但不能认证操作者身份或为伪造的外部批准背书。原始 SPLITS/GROUPS/冻结前 EXPOSURE 与所有实际制品在冻结后不变；持续追加访问写入单独 ACCESS_LOG，不改冻结快照。

```sh
python3 -B data/D04/scripts/d04.py verify-freeze \
  --freeze /PRIVATE_LOCATION/d04/freeze.json \
  --freeze-sha256 APPROVED_HASH_FROM_EXTERNAL_APPROVAL_LOG \
  --splits /PRIVATE_LOCATION/d04/SPLITS.csv \
  --groups /PRIVATE_LOCATION/d04/GROUPS.csv \
  --exposure /PRIVATE_LOCATION/d04/EXPOSURE.csv \
  --artifact-root /PRIVATE_LOCATION/d04 \
  --eligibility /PRIVATE_LOCATION/d04/current-local-eligibility.json \
  --access-log /PRIVATE_LOCATION/d04/ACCESS_LOG.csv
```

只有全部检查通过才返回 `verified_approval_record` 和 `documented_freeze_verified`，即“所提供的外部批准记录和当前证据一致”；不表示工具替人审批或独立泛化已得到统计证明。缺批准、缺/改文件、路径改变、旧 eligibility、撤回后不再 eligible、缺当前访问账本、重复/无效人工审核记录、任何已记载的 held-out 开发使用，都会返回 `not_frozen`。

解封、重标、修改标签标准或重新纳入样本：先停止使用旧版本；保存变更请求、理由、原始字节、旧版哈希与访问记录；用户本人或独立审核人实际批准后生成新 dataset/gold 版本、重新核验并归档新冻结记录和可信哈希。受污染样本不能通过重新批准恢复“从未见过”的独立性，应从独立 held-out 移出并真实补采。

## 软件验证

```sh
python3 -B -m unittest discover -s data/D04/tests -p 'test_*.py'
```

38 个测试全部使用临时目录中的 invented synthetic bytes；测试中的人名/审批对象也均为虚构化名，不计真实数据、真实人工审核或真实审批。红绿记录见 [verification/RED_GREEN.md](verification/RED_GREEN.md)。
