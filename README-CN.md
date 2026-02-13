# Claude Session Saver

**中文 | [English](README.md)**

自动保存 Claude Code 会话历史到项目目录，生成可读的 markdown 文件。

## 为什么做这个工具？

Claude Code 的会话历史存储在 `~/.claude/projects/` 目录下，格式是 JSONL。这有几个痛点：

- **难以阅读** - 原始 JSONL 格式，嵌套 JSON，对人类不友好
- **位置分散** - 历史记录在 home 目录，和项目分离
- **容易丢失** - 关掉终端或切换项目，想找回那个对话就像大海捞针
- **无法预览** - 不能在 IDE 或文件管理器里快速浏览
- **系统噪音** - 混杂着内部系统标签、工具元数据和调试信息
- **上下文丢失** - 会话压缩后，摘要埋在数据深处难以查看
- **无法搜索** - 不能方便地 grep 或搜索历史对话
- **难以分享** - 想把有用的对话分享给同事很麻烦

这个工具把会话转换成干净的 markdown 文件，直接保存在项目目录，方便查阅、搜索和分享。

## 功能特性

- **完整对话导出** - 合并连续消息的完整历史记录
- **工具调用详情** - 独立文件记录工具使用和输入参数
- **上下文压缩** - 保留会话压缩时的摘要内容
- **会话索引** - 快速浏览所有会话
- **异步处理** - 大文件（>2MB）后台处理，不阻塞
- **原子更新** - 文件始终完整可读
- **自动时区** - 时间戳使用本地时区

## 安装

### 快速安装

```bash
git clone https://github.com/samuelqin/claude-session-saver.git
cd claude-session-saver
./install.sh
```

### 手动安装

1. 复制 `save-session.sh` 到 `~/.claude/hooks/`

2. 添加执行权限：
   ```bash
   chmod +x ~/.claude/hooks/save-session.sh
   ```

3. 在 `~/.claude/settings.json` 中添加钩子配置：
   ```json
   {
     "hooks": {
       "PostToolUse": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "~/.claude/hooks/save-session.sh"
             }
           ]
         }
       ],
       "Stop": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "sleep 1 && ~/.claude/hooks/save-session.sh"
             }
           ]
         }
       ]
     }
   }
   ```

4. 重启 Claude Code

## 输出

会话历史保存到 `<项目目录>/.claude/session-history/`：

```
.claude/session-history/
├── [Index]Sessions.md              # 会话索引
├── [History]标题_01-15_1430_abc1.md    # 对话记录
├── [ToolUse]标题_01-15_1430_abc1.md    # 工具详情
└── [Compact]标题_01-15_1430_abc1.md    # 上下文摘要
```

### 文件类型

| 文件 | 说明 |
|------|------|
| `[History]*.md` | 主对话，包含用户和助手消息 |
| `[ToolUse]*.md` | 工具调用详情和输入参数 |
| `[Compact]*.md` | 上下文压缩摘要 |
| `[Index]Sessions.md` | 所有会话索引 |

## 依赖

- macOS（使用 `stat -f`、`date -j`）
- `jq` - JSON 处理器
- `perl` - 正则处理
- `python3` - URL 编码

```bash
brew install jq
```

## 配置

脚本自动检测：
- 系统时区
- Claude 的项目目录
- Git 仓库（自动添加到 .gitignore）

### 节流机制

- 全局：10 秒冷却
- 大文件（>2MB）：5 分钟冷却，异步处理

## 卸载

```bash
rm ~/.claude/hooks/save-session.sh
# 编辑 ~/.claude/settings.json 删除 "hooks" 部分
```

## 许可证

MIT
