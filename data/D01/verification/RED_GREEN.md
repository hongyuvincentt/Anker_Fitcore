# D01 本地工具验证摘要

范围：仅 D01 离线采集 CLI；无真人录音、真实授权记录、云调用、Git 提交或推送。全部 WAV 与虚构授权仅存在于 `TemporaryDirectory` 中，标明 synthetic/test。交付目录不是 Git 工作区（`git status` 返回 not a git repository），未创建分支。

执行命令：

```sh
python3 -B -m unittest discover -s data/D01/tests -p 'test_*.py'
```

1. 首次红：测试先写入，CLI 尚未存在。初次运行暴露测试输出 JSON 解码错误；修正测试断言后重跑，17 项测试得到 `FAILED (failures=27)`（含 subTest），没有 error。失败是缺少 CLI 实现及 JSON 输出契约，不是意外依赖缺失。
2. 首次绿：实现 CLI 后，`Ran 17 tests`、`OK`，覆盖新目录空模板/权限、不覆盖、缺失/拒绝/撤销/到期授权、化名关联、用途分离、WAV格式/空/静音/截断/7MB、哈希/ID冲突、路径穿越/链接、iOS嵌套sidecar、来源待复核和零报告。
3. 第二次红：追加边界测试后，`Ran 23 tests`、`FAILED (failures=3)`。明确发现未来录音时间仍可导入、损坏音频阻断撤销、撤销时间可早于授权时间。
4. 第二次绿：拒绝未来录音和早于授权的撤销；撤销改为只读取授权登记，不依赖音频完整性。`Ran 23 tests`、`OK`，约 2.1 秒。
5. 第三次红/绿：按实际 iOS 命令仅通过 sidecar 传递录音元数据，并使用合法 JSON 数值 `sample_rate=16000.0`，原实现因字符串比较拒绝；`Ran 24 tests`、1 failure。修正为数值等价检查后 `Ran 24 tests`、`OK`。
6. 第四次红/绿：增加不可信 sidecar 极大整数，原实现出现数值转换溢出，`Ran 25 tests`、2 failures（subTest）。改为先做安全范围/等值比较，后验证有限性；最终 `Ran 25 tests`、`OK`，约 2.1 秒。

软件测试通过不等于 D01 数据验收：当前真实样本 0、说话者 0、soundcore 覆盖未开始，D02 仍需 JZD 人工复核。未在此子任务运行 iOS/Xcode 测试，因为 D01 仅新增标准库脚本且未修改 iOS。
