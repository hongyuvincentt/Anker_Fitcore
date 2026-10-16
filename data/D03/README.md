# D03 分批语义开发语料（离线）

100～150条是目标。本轮先给24条由Codex代拟、未经人工复核的开发文本，来源全部显式为`model_generated`，不是人工编写、真人转写、人工金标或系统实测。来源记录见`PROVENANCE.md`。当前真人转写0条、已批准独立held-out 0条；不把D01两段未回听的录音推定成任何文字。

先读D04规则，再扩充。这里所有示例已暴露给开发，不得事后包装为独立held-out。规则检查不会生成或修改录音、D01授权、D02金标、split或服务器事实；不调用模型或网络。

```sh
python3 -B data/D03/scripts/d03.py check --input data/D03/examples/development_cases.jsonl
python3 -B -m unittest discover -s data/D03/tests -p 'test_*.py'
```

源字段和版本定义见`SCHEMA.md`。每条JSONL明确case_id、source_type/source_ref、source_group_id、near_duplicate_group_id、purpose、dataset_version、revision、review_status、类别和多意图列表。精确/规范化/近重复只报告匿名ID，保留原件，供人工决定，不自动删除或合并。

## 保护集与冻结边界

`--protected /PRIVATE_LOCATION/protected_cases.jsonl`只读取独立保管的保护文本，格式同本任务记录但purpose为heldout。案例ID、原recording_id、来源族、近重复组或词面候选重叠时阻断扩充。真人保护记录还须保留speaker_id_pseudonym/session_id/environment_id；检查同说话者/会话/环境重叠，分组证据缺失也阻断，不能靠换案例ID/来源组藏掉同源录音。保护文本不复制到本目录、日志或Prompt，输出不含其文字。

未提供保护集报告not_supplied；空保护集报告empty_not_frozen。即使已检查用户提供的保护文本，也不证明语义独立、真实来源、保护集完整或已经批准冻结；D04仍需实际证据和独立审批。`purpose=test`仅为开发回归用途，不能等同于D04 held-out。

## 真人转写入口

将获准的真实文本保留在仓库外私密JSONL；引用真实D02已复核revision与segment，不能根据文件名/ASR/预期脚本填写。使用：

```sh
python3 -B data/D03/scripts/d03.py check \
  --input /PRIVATE_LOCATION/cases.jsonl \
  --source-root /PRIVATE_LOCATION/d01-collection \
  --annotation-root /PRIVATE_LOCATION/d02-annotations \
  --groups /PRIVATE_LOCATION/GROUPS.csv
```

工具只读复用D01/D02的当前用途、有效期/撤回、来源、哈希和不可变revision校验，必须与已reviewed的原话逐字相同；不会代签review。GROUPS.csv使用D04空模板结构，提供真实环境和来源族，不能从语义类别推断；无保护输入时可暂不提供，但有真人保护集时环境缺失会阻断。当前没有team许可，因此JZD第二人审核未成立，真人转写纳入步骤阻断。非真人案例目前只能以draft纳入开发集合，不能自动升级为人工金标。

人工编写用human_authored；由模型代拟或改写的用model_generated，不能为了数量改来源。派生案例保留真实source_ref/同源组，不清除血缘逃过保护检查。近重复词面检查不等于完整语义相似度；需要人工审核来源族、跨语言改写和数值变体。

独立任务ZIP保留`data/D03/`及所需公开`data/D04/scripts/d04.py`、`data/D02/scripts/d02.py`、`data/D01/scripts/d01.py`相对结构；包含空规范/字典、公开模型草稿和合成测试，不含实际真人文本或私密保护集。
