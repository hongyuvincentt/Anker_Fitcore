# 03 · 真人 WAV、授权、标注和 held-out 数据规程（D01–D05）

## 数据责任
**LHY 独立执行并交付 D01、D02、D03、D04、D05。** 你对采集范围、对外共享、发布材料及金标争议做最终审批；Codex/TRAE 仅审核算法/评测方法，不能悄悄更改人工标准。

## D01 · WAV 采集
- 目标范围：经授权的3–5名志愿者、约40段扩展真人语音；仅为目标，不是既成成果。
- 授权应明示：录制、团队内部评测、是否允许上传第三方模型服务或 AWS、授权撤销方式、数据保存期限。不同用途单独记录。
- 记录 `consent_id`/化名 `speaker_id`/`recording_id`/设备/场景/采样元数据/哈希。不收集不必要的姓名、电话、地址。
- 保留不可变原始 WAV；处理派生文件须另存并标注来源及处理参数。禁止拿 TTS 代替真人语音，也不能依据文件名直接认定朗读内容。
- 私人音频放在最小权限的团队指定存储，别放公开 GitHub、Launch 网页或这个 ZIP。

## D02 · 人工标签
- 一条样本至少包含 `recording_id`、`reference_text`、`intent`、`exercise`、`weight_kg`、`reps`、`temporal_modality`、`ambiguity`、`annotator_id`、`review_status`。
- 不确定要写 `UNKNOWN`/`needs_review`，不可凭算法生成的假定补齐缺失数字。纠错句要区分历史、当前完成、未来计划与明确纠错对象。
- 人工 reference 不等于 ASR 输出；记录版本并建立变更请求。争议由独立审核人抽查。

## D03 · 语义语料
- 目标100–150条；区分真人转写、人工设计案例、模型模拟输出。含训练相关性、主观感受、动作别名、纠错、多意图、指代与来源不确定。
- 数据每条须有分类/标签字典和用途（train/dev/test）；检测重复与近重复，不把 held-out 复制到训练语料。

## D04 · Held-out
- 按 speaker_id、session_id、scene_id 分组切分；最严格基准要求同一 speaker 不跨 train/held-out。
- 先冻结 split/标签 SHA-256，再让 TRAE/Codex 调算法；评测组不能偷偷调整标准或把题目用来改模型。
- LHY 负责制作与日常维护，**冻结审批由你或 Codex 独立完成**；评测样本有限就说“探索性”，不声称泛化已证明。

## D05 · 测评
- 必须记录被测 commit、数据集版本、环境、模型版本、真实/模拟标识和分母。
- 报告：正确自动记账率、错误 COMMIT率、遗漏率、DEFER/Pending率、ASR 数字错误、语义理解错误、Fact Engine错误、延迟（P50/P95有样本数时）、模型费用。
- 每个错误案例能追溯到匿名 recording_id；绝不公开原音频、隐私转写或密钥。

## 样本生命周期
新采集 → 授权核对 → SHA-256/格式检查 → 匿名 manifest → 双人抽查标注 → 分组切分/held-out冻结 → 评测 → 审批报告 → 按保存周期删除/收到撤销后处理。

## 模板
`templates/CONSENT_REGISTER.csv`、`templates/WAV_MANIFEST.csv`、`templates/ANNOTATIONS.csv`、`templates/SPLITS.csv`、`templates/EVAL_RESULTS.csv`。
所有模板为空结构，无真实个人信息、无私人音频。
