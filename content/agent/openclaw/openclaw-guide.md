# OpenClaw 核心使用指南

> 本文档记录当前可用的 OpenClaw 技能及基础用法
> 更新时间: 2026/3/5 20:49:38

---

## 一、已安装技能概览 (18 个可用 / 59 个总计)

### ✅ 可用技能

| 状态 | 技能 | 描述 |
|------|------|------|
| ✅ | 📦 feishu-doc | ready   │ 📦 feishu-doc     │ Feishu document read/write ope... |
| ✅ | 📦 feishu-drive | ready   │ 📦 feishu-drive   │ Feishu cloud storage file mana... |
| ✅ | 📦 feishu-perm | ready   │ 📦 feishu-perm    │ Feishu permission management f... |
| ✅ | 📦 feishu-wiki | ready   │ 📦 feishu-wiki    │ Feishu knowledge base navigati... |
| ✅ | 📦 feishu-task | ready   │ 📦 feishu-task    │ Feishu Task, tasklist, subtask... |
| ✅ | 📦 clawhub | ready   │ 📦 clawhub        │ Use the ClawHub CLI to search,... |
| ✅ | 📦 gh-issues | ready   │ 📦 gh-issues      │ Fetch GitHub issues, spawn sub... |
| ✅ | 🐙 github | ready   │ 🐙 github         │ GitHub operations via `gh` CLI... |
| ✅ | 📦 healthcheck | ready   │ 📦 healthcheck    │ Host security hardening and ri... |
| ✅ | 📦 obsidian | ready   │ 📦 obsidian       │ Work with Obsidian vaults (pla... |
| ✅ | 📦 skill-creator | ready   │ 📦 skill-creator  │ Create or update AgentSkills. ... |
| ✅ | 📦 summarize | ready   │ 📦 summarize      │ Summarize URLs or files with t... |
| ✅ | 🧵 tmux | ready   │ 🧵 tmux           │ Remote-control tmux sessions f... |
| ✅ | 🎞️ video-frames | ready   │ 🎞️ video-frames  │ Extract frames or short clips ... |
| ✅ | 📦 weather | ready   │ 📦 weather        │ Get current weather and foreca... |
| ✅ | 📦 capability- | ready   │ 📦 capability-    │ A self-evolution engine for AI... |
| ✅ | 📦 self- | ready   │ 📦 self-          │ Captures learnings, errors, an... |
| ✅ | 📦 tavily | ready   │ 📦 tavily         │ AI-optimized web search via Ta... |

### ❌ 未安装/缺失依赖

| 状态 | 技能 | 描述 |
|------|------|------|
| ❌ | 🔐 1password | missing │ 🔐 1password      │ Set up and use 1Pass... |
| ❌ | 📝 apple-notes | missing │ 📝 apple-notes    │ Manage Apple Notes v... |
| ❌ | ⏰ apple- | missing │ ⏰ apple-         │ Manage Apple Reminder... |
| ❌ | 🐻 bear-notes | missing │ 🐻 bear-notes     │ Create, search, and ... |
| ❌ | 📰 blogwatcher | missing │ 📰 blogwatcher    │ Monitor blogs and RS... |
| ❌ | 🫐 blucli | missing │ 🫐 blucli         │ BluOS CLI (blu) for ... |
| ❌ | 🫧 bluebubbles | missing │ 🫧 bluebubbles    │ Use when you need to... |
| ❌ | 📸 camsnap | missing │ 📸 camsnap        │ Capture frames or cl... |
| ❌ | 🧩 coding-agent | missing │ 🧩 coding-agent   │ Delegate coding task... |
| ❌ | 🎮 discord | missing │ 🎮 discord        │ Discord ops via the ... |
| ... | ... | 还有 31 个未安装技能 |

---

## 二、基础命令

```bash
# 查看技能列表
openclaw skills list

# 查看技能详情
openclaw skills info <skill-name>

# 安装新技能 (可能有限流)
clawhub install <skill-name>

# 或直接 git clone
mkdir -p ~/.openclaw/skills
cd ~/.openclaw/skills
git clone --depth 1 <repo-url> <skill-name>

# 检查技能状态
openclaw skills check
```

---

## 三、核心技能速查

### GitHub (🐙)
```bash
# 需先登录
gh auth login

# PR 操作
gh pr list --repo owner/repo
gh pr view 55 --repo owner/repo
gh pr checks 55 --repo owner/repo

# Issues
gh issue list --repo owner/repo
gh issue create --title "Bug: xxx"

# CI/Actions  
gh run list --repo owner/repo
gh run view <run-id> --log-failed
```

### 飞书系列 (📦)
- **feishu-doc**: 文档读写、评论管理
- **feishu-drive**: 云空间文件管理
- **feishu-wiki**: 知识库导航
- **feishu-task**: 任务、子任务管理

### capability-evolver (🧬)
```bash
cd ~/.openclaw/skills/capability-evolver
node index.js          # 标准运行
node index.js --review # 审核模式
node index.js --loop   # 持续循环
```

---

## 四、快速参考

```bash
# 查看状态
openclaw status
openclaw gateway status

# 启动/停止 Gateway
openclaw gateway start
openclaw gateway stop

# 模型切换
/models
/model <provider/model>

# 会话管理
/sessions
/status
```

---

## 五、重要路径

| 用途   | 路径                                                                                  |
| ---- | ----------------------------------------------------------------------------------- |
| 工作区  | `~/.openclaw/workspace/`                                                            |
| 技能目录 | `~/.openclaw/skills/`                                                               |
| 内存文件 | `~/.openclaw/workspace/memory/`                                                     |
| 配置文件 | `~/.openclaw/openclaw.json`                                                         |
| 本指南  | `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/juwiki/lb/agent/openclaw/` |

---

*本文档由 OpenClaw Agent 自动生成*
