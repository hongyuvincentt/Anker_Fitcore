# LHY-08 独立执行 Prompt：iOS 集成与完整交付

请接手Fitcore的LHY-08，在当前工作副本整合已完成的手机WAV、HTTP客户端、训练UI与Review，交付可跨Mac重现的完整ZIP和真实验收记录。按LHY-03→LHY-04→LHY-08推进，不同时把多个独立任务开在同一工程。没有硬件/授权时先完成可验收的本地集成，不虚报物理iPhone或soundcore完成。

## 先读与工作边界

在解压根目录依次阅读 `README.md`、`handoff/CURRENT_STATUS.md`、`handoff/KNOWN_API_GAPS.md`、`reference/task-package/tasks/LHY-08.md`、`reference/api/WAV_HTTP_API_2026-10-15.md`，再读 `reference/task-package/docs/02_IOS_API_AND_MODULES.md`、`docs/LHY-01-LOCAL-HANDOFF.md` 以及实际存在的LHY-02/03/04新交付记录。旧 `docs/lhy-13tasks-status-2026-10-15.md` 仅是历史基线，不能代替当前成果。

先报告理解、现有依赖完成度、最小集成范围、当前目录与版本；有Git元数据时只读确认仓库/分支并沿用，没有则如实记录。不要初始化Git、恢复旧提交覆盖源码、拉取/推送/创建PR、操作AWS、公网或付费调用。默认全部本地fixture；真实联调、模型费用、私人音频上传和SDK迁移均须后续用户明确批准。保留四页布局、现有Mock及设置内录音。

## 已有与目标

- 基线0.3.1 (8)，LHY-01与D01软件已本地实现和验证。手机采集在「我的→设置→手机WAV采集」，输出 `UUID.wav`/`UUID.metadata.json`，16kHz/mono/PCM16、≤7,000,000字节，停止等待完成。不要重写或用旧版本覆盖。
- 物理iPhone没有验收，真人样本0，无soundcore录音豆与充电盒，SDK不在ZIP。当前包里的旧网络客户端与本地复盘不能充当新云端链路。
- 集成目标是同一源码快照内完成：标准文件→创建session→multipart上传→Job→Facts/Pending/Events→Finish/Review，支持恢复与明确降级。LHY-06/07缺服务不应阻挡主链。

## 最小实施

1. 先核对当前源码中LHY-03/04的实际状态、DTO与测试；如收到其他任务ZIP，先比对文件和源码指纹，只合入相关差异，保留本副本更新的LHY-01/D01及四页。不要整包覆盖，不把未收到的模块写成已整合。
2. 复用LHY-01有效原文件、稳定utterance_id/哈希；同session sequence从0连续。重试复用ID、序号、字节和来源。multipart只用合同字段，不走旧文本/audio-chunks接口；手机文件不能冒充soundcore。
3. 绑定录音完成与上传生命周期，完成回调前不校验/上传；取消、后台/中断、会话切换后的旧回调不污染新会话。若后续接硬件，设备stop/尾包收齐与云端draining分别等待，不能用硬件完成信号直接进入Review。
4. 上传202仅接受，Job done仍看COMMIT/DEFER/REJECT，正式记录仅Facts/Review。默认source trust=false，SOURCE_UNCERTAIN→Pending、confirm409 SOURCE_NOT_VERIFIED均需保留真实状态，声纹not_performed；不伪造可信身份、修改服务端开关或数据库。
5. Finish使用稳定finish_id、真实last_sequence，在停止输入及全部应有片段202后提交；202 draining继续查，409 awaiting_audio补缺段或显示阻断，Review409不呈现成功。预算耗尽与无事实/Pending场景不能“空成功”。
6. 对断网、401/403、超时、取消、来源待确认、失去设备提供现有界面可理解的恢复/降级。Mock明确标识，录屏标录屏；不能自动切Mock后宣称真实成功。只在真实Review可用时更新正式云复盘，保留明确的本地Mock路径。
7. SDK需另行授权迁移，历史为静态 `SoundcoreWorkAppleSDK`/`module_spplinkKit` 两套XCFramework；约20ms裸Opus须真实解码/重采样，禁止加头冒充WAV。低层startRecord不等于D3200新录制/stop能力已确认；硬件未验收时保持禁用/未接入并列阻断，不为凑LHY-08完成状态发明实现。
8. 后端已部署，无需新建AWS资源。HTTP Token不同于模型Key，只用私密本机配置，不能硬编码、输出、打包或截图；/health可用不证明模型/新端到端成功。缺声纹/建议后端显示不可用，不自建权威Fact Engine或服务。

## 验证与真实阻断

先在无远程凭据条件下重放本地fixture全链，覆盖正常Facts、SOURCE_UNCERTAIN/Pending、确认409、重复上传、缺段/Finish202与409/Review409、断网与超时/预算耗尽、取消/会话切换和Mock恢复。跑现有 `swift test`、`python3 -B scripts/verify.py`、`python3 -B -m unittest discover -s data/D01/tests -v` 及新合同/状态测试。

可用Mac上执行并记录实际结果：

```sh
swift test --scratch-path /private/tmp/fitcore-lhy08-unit-tests
xcodebuild -quiet -project ios/Fitcore.xcodeproj -scheme Fitcore-Mock \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/fitcore-lhy08-build CODE_SIGNING_ALLOWED=NO build
```

模拟器构建不等于物理iPhone验收，generic iOS无签名构建也不等于安装运行。若用户提供物理iPhone并授权本机安装/本人录音，再按清单实际完成签名安装、权限拒绝恢复、录制/停止/回听/导出、取消/重录、中断/后台、重启恢复及四页/Mock演示；记录型号、iOS、Xcode、源码指纹与脱敏视频。真实云联调须另有范围/费用/云处理授权和有效HTTP Token，硬件需录音豆及盒子；未执行项保持未验收，不能用合成WAV或模拟器替代。

## 独立 ZIP 交付条件

提供完整当前源码、Xcode工程/资源、必要脚本与本地测试/fixture、D01空模板、已整合任务清单、跨Mac打开/签名/运行步骤、源码指纹、文件清单、SHA-256及本地/模拟器/物理iPhone/云/录音豆分项验收矩阵。ZIP解到新目录无需旧机器绝对路径、私密文件或父目录资源即可跑Mock和离线检查。排除 `.git`、构建缓存、SDK（除非另获分发授权）、个人签名、`Local.xcconfig`、Token/模型Key、私人WAV/授权记录/数据库。不伪造Commit/PR；无Git时用源码指纹追溯。明确本轮已实现、已验证、未验收与真实阻断，用户后续批准远程操作前保持本地交付。
