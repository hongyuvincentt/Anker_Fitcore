请接手当前解压目录的 Fitcore 项目，先核对环境和已有成果，不要立即重写功能。

依次阅读：
1. README.md
2. handoff/CURRENT_STATUS.md
3. handoff/NEW_MAC_SETUP.md
4. handoff/KNOWN_API_GAPS.md
5. docs/LHY-01-LOCAL-HANDOFF.md 和 docs/LHY-01-VERIFICATION.json
6. data/D01/README.md、handoff/PROMPTS.md

当前 App 是0.3.1(8)。LHY-01手机WAV采集和D01离线工具已有代码与软件验证，物理iPhone录音仍未验收，真人样本0。JZD负责第二人工复核。不要按原任务Excel的历史“待核查”把已有代码重做，不恢复旧Git提交覆盖当前文件。

先确认当前目录、Git是否存在/当前分支、Mac/Xcode/Swift/Python版本，按NEW_MAC_SETUP运行适用的离线回归和模拟器构建。把“上一台Mac的证据”“新电脑刚运行的结果”“未做的物理iPhone/真实API验收”分别说明。若是Windows，先阅读/编辑资料；D01原生Windows运行未验证，实际运行需具备Asia/Shanghai时区数据及POSIX权限的WSL/Linux环境，iOS编译留给Mac。不要移除权限保护来伪装兼容。

随后指导我用Xcode打开ios/Fitcore.xcodeproj，选Fitcore-Mock、自己的Team与连接的iPhone，Command+R安装。在“我的→设置→手机WAV采集”录制、播放并手动导出UUID.wav和UUID.metadata.json，核查实际文件格式和D01导入。录音权限、签名登录、真人说话和授权由我亲自完成；没有实际证据不标已验收。D01先实际登记用途许可，只采本人小批次；本机、团队、云处理许可分开，真实音频不随源码包上传。

完成可用的基线检查后，下一开发任务按handoff/prompts/LHY-03.md实现完整WAV HTTP客户端，再推进LHY-04/LHY-08。离线实现和fixture测试可先做；实际云端上传等我提供私密配置并确认本轮测试范围。不得绕过来源Pending门禁或伪造声纹认证。

保持现有页面布局、人物肌肉展示和Mock回归。使用已部署AWS统一后端，不重新开发/部署旧后端。HTTP测试Token由我本机安全配置，不要求在聊天发送完整值；它不是模型Key。默认本地推进，不调用付费模型、不上传录音、不推送Git、不修改AWS。后续每项任务完成后给独立ZIP、实际检查证据、未验收项和阻断；其余11项Prompt在handoff/prompts/，每次只执行选定任务。
