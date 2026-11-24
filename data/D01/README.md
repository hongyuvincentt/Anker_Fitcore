# D01 本地真人 WAV 采集准备工具

当前状态（2026-10-16只读核查）：**本机私密库已入库2段、1名声明说话者，ordinary和numeric_ambiguity各1段；两段均needs_review，已核验可用数0。** 格式及manifest哈希通过；现有授权仅local允许，team/cloud均false。这个代码交付包含真人样本0段、实际授权记录0行，不含任何人工金标。首批10段尚需实际补采8段；扩展约40段、3–5人仍为目标。历史7段不在本交付中，也不推定获得再次使用/分享的授权。

目前可使用iPhone录音；没有soundcore录音豆与充电盒，相应设备覆盖记为未开始。本人录音也需要真实、用途明确的授权登记。LHY实际回听后才能执行verify-human；这是本地来源复核，不是服务端VERIFIED_USER或声纹。JZD第二复核必须等待team用途授权，目前不可发送真实音频或受限标注。本工具不生成转写、ASR结果或金标，完全离线，不调用模型或自动上传；本轮在已确认的私有远端建立数据分支交付，来源提交与最新状态见 docs/data-line/INTEGRATION_2026-10-16.md。

## 文件边界和安装

仅需 Python 3.9+ 标准库及系统 `Asia/Shanghai` 时区数据，建议使用本机 Python 3.12。源码、测试、两个仅含表头的 CSV 可以交付；私人存储必须放在项目、交付 ZIP 和任何公共/同步目录以外。下面的路径都是占位符，请用自己的私密位置替换，勿将带个人绝对路径的命令日志加入交付。

```sh
python3 -B data/D01/scripts/d01.py --help
python3 -B data/D01/scripts/d01.py init --root /PRIVATE_LOCATION/d01-collection
```

`init` 只创建新目录；即使现有目录为空，也拒绝覆盖。私密根目录权限为 0700，工具新建的 CSV、音频、审计文件为 0600。已有根目录有组/其他用户权限时会拒绝操作。应用锁 `.d01.lock` 用于防止两个 CLI 同时修改；异常中断后需先确认没有其它进程，再人工处理该明确锁文件。工具不会批量清理文件。

私密目录运行后结构为：

```text
d01-collection/
  CONSENT_REGISTER.csv     # 由操作者根据真实授权手工填写
  WAV_MANIFEST.csv         # 仅由导入/复核工具更新
  audit.jsonl             # 初始化、导入失败/成功、真人复核、撤销事件
  audio/<recording_id>.wav # 不可覆盖的原始字节副本
  sidecars/<recording_id>.metadata.json # 新导入时原样留存的可选原始sidecar
```

两个表头与原交接包的新模板逐列一致，支持 UTF-8 BOM。`private_storage_pointer` 固定为 `audio/<recording_id>.wav`，相对于私密根目录，不记录个人绝对路径。CSV 仍属私人登记资料，不能因为化名就直接公开整个运行目录。

## 先登记真实授权

工具不会生成或默认授予同意。由 LHY 在私密 `CONSENT_REGISTER.csv` 填写真实记录，先向参与者解释并分别确认：录音、团队内部使用、AWS/第三方模型处理、共享范围、保存期限和撤销途径。授权证据保存在访问受限的位置；登记表不填姓名、电话、住址或私人证据路径。`consent_id`、`speaker_id_pseudonym` 使用匿名代号，同一个说话者保持同一个化名。

- `consent_timestamp` 使用带时区 ISO8601，例如格式 `YYYY-MM-DDTHH:MM:SS+08:00`。
- `recording_allowed`、`internal_team_use_allowed`、`aws_model_processing_allowed` 各自只能为字面 `true`/`false`，不接受 `yes` 或空值。仅同意本地采集时，后两项应保持真实的 `false`，不会因此阻断本地导入。
- `share_scope` 如实写允许的团队与服务边界；布尔许可不是任意公开授权。即使 `cloud` 队列可用，也须人工核对具体服务/区域/保留政策是否在实际授权范围内。
- `retention_until` 必填：`YYYY-MM-DD` 表示上海时区该日结束前有效；也可以填写带时区的精确时间戳。
- `withdrawal_method` 填匿名联络流程代号，不填私人联系方式；`verification_reviewer` 填实际核对授权的匿名审核者代号。
- `consent_status` 只能是 `pending`、`granted`、`denied`、`withdrawn`。只有实际明确授权且证据已核对时才能手工填 `granted`；存在 `withdrawn_at` 时无条件排除，不能靠改回 `granted` 重新启用。
- `notes_no_pii` 不包含私人信息。授权证据与身份映射另行私密保管。

`local_recording_consent=true` 的 iOS sidecar 只是录音端状态，**不能替代登记表，也不代表团队/云许可**。授权晚于录音时间、未来录音时间、到期、撤销、化名不匹配都会拒绝导入。

## 先采 10 段，再复核

1. 参考 [采样覆盖矩阵](SAMPLING_MATRIX.md)，先在安静环境录本人 10 段，涵盖普通记账、数字歧义、纠错上下文、计划和轻噪声。每段留自然停顿，实际内容可由说话者自行表达；不把文件名当成转写。
2. 真机完成每段录音，通过 iOS 分享将原始 `.wav` 和同名 `.metadata.json` sidecar 都保存到私密收件位置。不要用录屏、系统 TTS、模拟器麦克风结果代替真人采集；不要用聊天软件有损转码。
3. 录制格式必须是 RIFF/WAVE、16kHz、单声道、整数 PCM16、文件不超过 7,000,000 字节。工具不做格式转换；不合格源文件保持原样，重新录制，或另存注明来源/参数的派生文件后人工决定是否纳入。
4. 每段显式关联真实的 `consent_id`/化名 `speaker_id_pseudonym`，运行导入。一次先导入 1–2 段查看输出，再完成本批次。
5. 听音并核验确实是物理真机上真人说话后，才运行 `verify-human`。这只是来源复核，不等于 D02 金标复核；`label_status` 保持 `unlabelled`，`data_split` 保持 `unassigned`。
6. 运行 `validate`、`report`，向 JZD 提供已获团队许可、未撤销/未到期的受限样本，开展 D02 标注复核。没有团队许可时，不能因为成功导入就共享。
7. 首批结果人工验收后再扩展到 3–5 名志愿者、约 40 段。每个人都单独登记实际授权；补齐设备/噪声差异。soundcore 设备未实际取得前保持缺口。

## iOS 分享包导入命令

以下 `REC_UUID`、`C_ID`、`S_ALIAS`、`SESSION_ID` 均为占位符；请替换为实际匿名编号。CLI 字段与 sidecar 同名字段若不一致会拒绝，不会静默覆盖。`recording_id`、录音时间、设备、来源由 sidecar 提供；授权/说话者/会话/场景由操作者显式关联。

```sh
python3 -B data/D01/scripts/d01.py import \
  --root /PRIVATE_LOCATION/d01-collection \
  --wav /PRIVATE_INBOX/REC_UUID.wav \
  --metadata /PRIVATE_INBOX/REC_UUID.metadata.json \
  --consent-id C_ID --speaker-id S_ALIAS \
  --session-id SESSION_ID --scene-id ordinary
```

支持iOS `schema_version=1`：顶层recording_id、recorded_at、device_type、recording_source、is_simulated、local_recording_consent；inspection可含sample_rate、channels、bits_per_sample、frame_count、duration_seconds、size_bytes、sha256，均与实际WAV核对。utterance_id若提供必须与recording_id相同，file_name若提供必须为该ID.wav，completed_at不能早于录制时间或晚于本次判断时刻。这些字段不决定身份/授权/真人来源；rms_dbfs和peak_dbfs也不是人声/身份判断。

新导入时有sidecar则原样保存在私密sidecars目录（文件0600），imported审计事件保存其SHA256；再次读取时核对原字节、ID、来源与音频元数据，拒绝被改写或缺失的已登记sidecar。不自动生成sidecar。旧记录或纯CLI导入没有sidecar时，报告not_retained_legacy_or_cli；格式/manifest有效不等于原始sidecar证据齐全。本轮两段已找回原始导出sidecar并核对补入，见recover-sidecar；仍等待本人实际回听来源复核。不能将重建JSON称为原始文件。异常中断遗留sidecar/音频由validate报告，逐项私下对账，不自动删除或覆盖。

无 sidecar 时可手工提供匿名元数据：

```sh
python3 -B data/D01/scripts/d01.py import \
  --root /PRIVATE_LOCATION/d01-collection \
  --wav /PRIVATE_INBOX/REC_UUID.wav \
  --recording-id REC_UUID --consent-id C_ID --speaker-id S_ALIAS \
  --session-id SESSION_ID --scene-id numeric_ambiguity \
  --recorded-at 2026-10-16T10:00:00+08:00 \
  --device-type iphone --recording-source iphone_microphone
```

时间示例仅展示格式，必须换成真实录制时间。匿名编号只允许字母、数字、下划线和连字符，长度 1–80，首字符为字母或数字。不接受路径/姓名作为编号。

每段先保存为 `quality_status=needs_review`。来源未知时保存 `unknown`，不能直接升级为真人；`is_simulated=true` 强制为 `simulator`。`simulator`、`tts`、`synthetic` 均不能通过来源复核。允许人工确认的来源是 `iphone_microphone`、`soundcore_microphone`、`human_recording`；后者仅用于实际人工录音，不能给合成测试音改名使用。未知来源需先私下调查，工具没有自动改写来源功能。

```sh
python3 -B data/D01/scripts/d01.py verify-human \
  --root /PRIVATE_LOCATION/d01-collection \
  --recording-id REC_UUID --reviewer JZD

python3 -B data/D01/scripts/d01.py validate --root /PRIVATE_LOCATION/d01-collection
python3 -B data/D01/scripts/d01.py report --root /PRIVATE_LOCATION/d01-collection
python3 -B data/D01/scripts/d01.py eligible --root /PRIVATE_LOCATION/d01-collection --purpose local
python3 -B data/D01/scripts/d01.py eligible --root /PRIVATE_LOCATION/d01-collection --purpose team
python3 -B data/D01/scripts/d01.py eligible --root /PRIVATE_LOCATION/d01-collection --purpose cloud
```

`eligible` 仅生成用途筛选 JSON，不上传或调用模型。各队列都先验证哈希/格式/跨表关系，要求来源已人工复核、录音授权有效；`team` 另需 `internal_team_use_allowed=true`，`cloud` 另需 `aws_model_processing_allowed=true`。用途互不自动推导。输出仍可能含私人匿名元数据，请仅在私密位置查看。

默认判断时刻为当前 `Asia/Shanghai` 时间。所有命令可加 `--as-of YYYY-MM-DD` 重放审查；日期表示当天上海时区结束时，精确过期时间当天早些时候已到期就排除。也可给带时区的精确 ISO8601。正式采集/队列应使用当前时间；历史重放不代表当前可用。

## 撤销、到期和失败记录

```sh
python3 -B data/D01/scripts/d01.py withdraw \
  --root /PRIVATE_LOCATION/d01-collection \
  --consent-id C_ID --withdrawn-at 2026-10-16T11:00:00+08:00
```

替换为真实撤销时间。撤销只修改登记状态并写匿名审计事件，即使音频损坏也可以撤销；不覆写音频，不自动删除私有证据。再次撤销会拒绝覆盖首次时间。队列/覆盖报告每次按最新授权和当前时刻重新计算；撤销和到期样本立即从可用队列排除。`retention_status=active` 是导入时快照，不用于覆盖当前授权状态。到期后的删除/证据保留由 LHY 根据实际授权私下逐项处理，不能把“排除队列”当作“已删除”。

导入失败写 `import_rejected`，不写私人源路径。重复 ID、重复 SHA-256、已有目标文件均拒绝；原 WAV 不改写。CSV 临时文件写入后原子替换，CLI 锁避免同时导入互相覆盖。导入在写完音频但写清单之前异常中断时可能留下孤立文件；`validate` 会拒绝通过，后续相同 ID 不会覆盖。需私下对照原件、哈希、审计，逐项修复，不可批量删除。权限、磁盘或锁本身阻止写日志时可能无法留下失败事件，应保留私密终端记录。

非静音检验只拒绝低于约 -80dBFS 的交流信号及纯直流，不证明有可理解的人声；真人来源与内容仍须听音审核。工具不是身份/授权证据的真实性鉴定器，人工 `verify-human` 必须基于实际核查，不能仅凭 sidecar 声明运行。

## 报告含义与验收

`report` 的 `imported_recordings` 是清单总段数，`human_verified_recordings` 和 `actual_people` 仅统计当前本地授权有效且已人工确认真人的样本。`pending_review_recordings` 为全部待来源复核记录；设备/场景覆盖也只计算当前有效真人样本。`eligible_counts` 分用途显示分母。没有真实记录时报告明确显示 0、空设备覆盖和 `acceptance=not_accepted`；即使达到数量目标，工具也不会自动宣布 D01 已验收。

D01 人工验收还需核查真实授权证据、实际设备/噪声覆盖、保存位置、原文件不可变和共享边界；D02 人工转写/标签与 JZD 复核是另一步。`data_split=unassigned` 不得被当成已完成 held-out 冻结。

## 测试和可交付白名单

```sh
python3 -B -m unittest discover -s data/D01/tests -p 'test_*.py'
```

测试只在临时目录创建明确标为 synthetic 的波形和虚构测试授权，运行结束后由 `TemporaryDirectory` 清理；不向交付目录写任何 WAV/授权行。初始失败与修复结果见 [红绿记录](verification/RED_GREEN.md)。

允许进入D01 ZIP的完整列表如下，其它运行文件不在允许范围：

```text
data/D01/README.md
data/D01/SAMPLING_MATRIX.md
data/D01/scripts/d01.py
data/D01/tests/test_d01.py
data/D01/tests/test_provenance.py
data/D01/templates/CONSENT_REGISTER.csv
data/D01/templates/WAV_MANIFEST.csv
data/D01/verification/RED_GREEN.md
data/D01/verification/2026-10-16.json
```

两个模板必须只含表头。禁止打包 WAV、实际 consent/manifest 行、sidecar、审计日志、转写、授权证据、私密存储根、绝对个人路径、密钥及缓存。CSV 模板中没有示范性 `granted` 数据行。

## 找回旧样本的原始 sidecar

`recover-sidecar --root /PRIVATE/collection --recording-id ID --metadata /PRIVATE/original/ID.metadata.json` 只接受实际找回的原文件。校验现存 WAV、UUID、原录制时间和 inspection.sha256，原字节以 0600 保存，私密 audit 另记来源路径与补入时间；不改 manifest、WAV 或人工确认状态。重复补入拒绝，缺失的原文件继续保留证据缺口，不从 manifest 重建。
