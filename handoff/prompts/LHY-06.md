# LHY-06 独立执行 Prompt：声纹授权与撤销交互

请接手Fitcore的LHY-06，先交付可以验收的本地授权/撤销交互和安全状态映射。当前没有声纹后端合同，不能声称真实注册、验证或远程撤销已完成。完成后交付另一台Mac能独立打开的完整ZIP；只做本任务，不与其他任务同时改同一工程。

## 先读与工作边界

在解压根目录依次阅读 `README.md`、`handoff/CURRENT_STATUS.md`、`handoff/KNOWN_API_GAPS.md`、`reference/task-package/tasks/LHY-06.md`、`reference/api/WAV_HTTP_API_2026-10-15.md`，再读 `reference/task-package/docs/02_IOS_API_AND_MODULES.md`、`docs/LHY-01-LOCAL-HANDOFF.md` 与现有授权相关实现。旧 `docs/lhy-13tasks-status-2026-10-15.md` 只作历史基线。

先说明理解、最小本地范围、当前目录与版本；有Git时只读确认仓库/分支并沿用，没有则说明。不要初始化Git、恢复旧提交覆盖源码、拉取/推送/创建PR、操作AWS、公网或付费调用。保留四页布局、Mock和原手机录音。默认未启用真实声纹功能；不能从任务标题推断用户已同意采集生物特征。

## 已有与目标

- 基线0.3.1 (8)，LHY-01已有本地手机WAV与UUID配对metadata、16kHz/mono/PCM16≤7,000,000字节、停止完成等待；不要重写，也不要把现有录音自动转作声纹样本。物理iPhone未验收，真人样本0，无录音豆/盒子。
- 后端已部署，但稳定WAV接口没有声纹注册/匹配/撤销API。正常 `speaker_verification=not_performed`、source trust默认false。HTTP Token不同于模型Key，不提供声纹能力。
- 目标是明确的注册授权、未录入/不可用、等待结果、撤销与样本清理原型；MATCH/UNKNOWN/NON_MATCH仅作为待后端确认的结果语义，不作为伪造服务合同。

## 最小实施

1. 复用设置/我的现有局部入口；真实功能默认不可用或Feature Flag关闭，文案说明“声纹能力尚未接入”。演示状态标Mock，与真实训练来源判定隔离。
2. 独立记录用途、授权版本、同意/拒绝/撤销、时间、匿名标识和本机处理状态；声纹授权与本机录音、团队复核、云端处理分别记录。没有明确声纹采集授权时不录样本、不生成模板、不上传。
3. 如展示结果映射，用测试fixture明确覆盖未录入/UNKNOWN/NON_MATCH/MATCH，但fixture不得写入生产可信身份、解除Pending或更改正式Facts。真实路径只接受后续服务端经过验证的结果，UI不能自行构造MATCH、VERIFIED_USER或voice_verified。
4. 撤销立即阻止本机相应用途继续使用；记录本地样本清理和远程撤销“未提交/待后端支持”等状态。无后端接口时不能显示“云端已撤销”或“所有副本已删除”。不新增自创 `/enroll`、`/verify`、`/revoke` HTTP路由或用客户端相似度阈值冒充声纹服务。
5. 明确未知来源不能自动视为可信。SOURCE_UNCERTAIN仍Pending，人工confirm可能409 SOURCE_NOT_VERIFIED；不能开服务端可信测试开关或发送speaker_status/source_type等非法字段绕过。
6. 整理后端待提供合同清单：注册与撤销鉴权、样本授权/保留/删除、任务与匹配结果字段、版本/置信与错误语义、UNKNOWN处理、撤销传播证据。只写缺口，不创建服务实现。
7. 删除遵循单个明确路径规则，不做递归/通配/循环清理；需要清理多个真实文件先让用户明确批准范围。默认测试只用临时合成记录，不读取私人声音或身份材料。

## 验证与真实阻断

本地测试未同意/拒绝/撤销/到期路径、不可用态、Mock标识、UNKNOWN/NON_MATCH不升级可信、Mock MATCH不流入Facts/上传身份、撤销后不能继续使用、重启恢复及远程撤销未完成提示。跑受影响离线测试、`python3 -B scripts/verify.py` 和可用的 `Fitcore-Mock` 模拟器构建；记录实际结果及未检查原因。

F02/来源鉴权合同、真实声纹模型、授权样本、物理iPhone和远程撤销服务是实际阻断。后续真实联调和任何付费调用需用户明确批准；不阻挡优先LHY-03→04→08主链。不能把受控本人测试或HTTP认证写成说话人验证。

## 独立 ZIP 交付条件

ZIP含完整当前App/Xcode工程/资源、局部原型、合成fixture/测试、功能默认值、运行说明、后端问题清单、LHY-06本地已验收与真实阻断。排除 `.git`、缓存、SDK、签名、`Local.xcconfig`、Token/模型Key、私人WAV/声纹模板/授权登记/数据库；提供文件清单与SHA-256。不编造Commit/PR、样本、声纹准确率或真机验收。未来整合只应用相关差异，不以旧ZIP覆盖当前新代码。
