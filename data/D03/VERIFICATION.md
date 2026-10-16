# D03 验证记录 · 2026-10-16

- 初始RED：脚本不存在，setUpClass因缺少实现失败；实现后首批9项测试通过。
- 额外RED：重复的畸形case_id导致TypeError；修复错误去重导致的有效性判断后通过。
- 额外RED：同recording不同case/source组可绕保护，以及真人身份分组不完整；加入recording、speaker/session/environment及私密D04分组绑定后通过。
- 最终：`python3 -B -m unittest discover -s data/D03/tests -p 'test_*.py'`，13项，0失败，退出0。
- 首批开发文件检查：24条，全部model_generated/draft/dev；真人转写0、人工金标0、独立held-out0；未提供保护集，因此结果development_only_not_frozen。
- 测试只用明确合成的文本/元数据；内部human_context的模拟数据不代表真人复核。不读取实际录音、不联网、不调用收费模型。
- 独立复查已核对同源保护与身份分组回归；词面近重复仅是候选检测，来源族与保护范围真实性仍需人工审核。
