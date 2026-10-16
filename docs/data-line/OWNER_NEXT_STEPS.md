# 本人下一步：从现有2段到D02本机初标

当前核查是2段已入库、均needs_review、只有local许可。下面命令只是操作说明，本轮没有执行来源复核、填写真人文字、创建实际同意或扩大授权。路径和ID均为占位符。

1. 本人在私密位置逐条实际回听原WAV，检查首尾、内容、设备来源及对应授权。找回原导出的sidecar并私下核对；本轮已找回并按原字节补入2份原始sidecar，UUID、哈希及原录制时间均通过；不能由脚本重建后当成原始证据。不要重复导入现有两段、覆盖原文件或改其hash来通过检查。
2. 只有实际确认来源后，才由本人逐条执行：

```sh
python3 -B data/D01/scripts/d01.py verify-human \
  --root /PRIVATE_LOCATION/d01-collection \
  --recording-id ACTUAL_RECORDING_ID --reviewer LHY
```

这只记录本地来源复核，不做声纹、不把服务器音源变成VERIFIED_USER。若实际不清楚就保持needs_review。

3. 在仓库外初始化新的私密D02目录，不能使用已有目录或把它放入源码包：

```sh
python3 -B data/D02/scripts/d02.py init \
  --root /PRIVATE_LOCATION/d02-annotations \
  --source-root /PRIVATE_LOCATION/d01-collection --local-annotator LHY
python3 -B data/D02/scripts/d02.py queue \
  --root /PRIVATE_LOCATION/d02-annotations \
  --source-root /PRIVATE_LOCATION/d01-collection --purpose local
```

4. 根据实际回听填写人工文本和结构。参考`data/D02/README.md`与`SCHEMA.md`；从空模板开始，UNKNOWN保留未知，ASR单独存放。实际听音后才能把revision的source_listened设为true；首次draft、未双人审核、gold未冻结。Codex可整理本人给出的记录，不能凭文件名或预期脚本代填原话。
5. 依`data/D01/SAMPLING_MATRIX.md`补采8段，原WAV/sidecar配对保存，关联真实session与授权。已录到10段仍不等于人工验收完成。
6. 当前不把任何真实音频或受限标注发给JZD/团队/云模型。第二复核必须先获得真实team用途授权；云端处理另需cloud用途许可，不以“有HTTP Token”替代数据授权。

若只使用当前一个人的试点数据，不宣称跨说话者泛化。按D04预留独立未来说话者/会话/环境，不提前把其内容给开发。真实模型调用、数据冻结和宣传报告仍由用户另行批准。
