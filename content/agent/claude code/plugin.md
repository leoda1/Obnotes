# 1. understand-anything
`understand-anything` 这个插件提供了一组 `/understand*` 技能,核心是先把代码库扫描成一张**知识图谱(knowledge graph)**,然后基于这张图做各种理解、问答、可视化。它们都是斜杠命令,直接在输入框里敲 `/` 就能调用。

## 各子命令用途

| 命令                      | 作用                                               | 典型场景                                             |
| ----------------------- | ------------------------------------------------ | ------------------------------------------------ |
| `/understand`           | **核心入口**。扫描代码库,生成交互式知识图谱(架构、组件、关系)。其他命令大多依赖它先跑一次 | 第一次接触一个仓库,想看整体架构                                 |
| `/understand-chat`      | 基于知识图谱**问答**                                     | "这个项目的鉴权是怎么做的?"                                  |
| `/understand-dashboard` | 启动一个**网页仪表盘**,可视化知识图谱                            | 想用浏览器图形化浏览依赖关系                                   |
| `/understand-explain`   | 对**某个具体文件/函数/模块**深入讲解                            | "解释一下 mooncake_connector.py 的 send_kv_to_decode" |
| `/understand-diff`      | 分析 **git diff / PR**,看改了什么、影响哪些组件、有什么风险          | review 一个 PR 前                                   |
| `/understand-domain`    | 提取**业务领域知识**,生成领域流程图                             | 想了解业务逻辑而非代码结构                                    |
| `/understand-onboard`   | 生成**新人 onboarding 指南**                           | 带新同事熟悉项目                                         |
| `/understand-knowledge` | 分析 Karpathy 风格的 LLM wiki 知识库,生成知识图谱              | 针对 wiki/知识库类内容                                   |

## 建议的使用流程

1. **先建图**——在当前 vllm 仓库里跑:
```
/understand
```
它会扫描代码并生成知识图谱(通常会缓存到项目目录下)。

2. **再用图**,按需选:
- 想问问题 → `/understand-chat 你的问题`
- 想看可视化 → `/understand-dashboard`
- 想深挖某文件 → `/understand-explain vllm/distributed/kv_transfer/.../mooncake_connector.py`
- 想看 PR 变更影响 → `/understand-diff`

---