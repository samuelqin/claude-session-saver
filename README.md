# Claude Session Saver

**[中文](README-CN.md) | English**

Auto-save Claude Code session history to your project directory as readable markdown files.

## Why This Tool?

Claude Code stores session history in `~/.claude/projects/` as JSONL files. This has several pain points:

- **Hard to read** - Raw JSONL format with nested JSON, not human-friendly
- **Scattered location** - History stored in home directory, separated from your project
- **Easy to lose** - Close the terminal or switch projects, and finding that conversation becomes a treasure hunt
- **No quick preview** - Can't browse conversations in your IDE or file manager
- **System noise** - Mixed with internal system tags, tool metadata, and debug info
- **Lost context** - When sessions are compacted, the summary is buried deep in the data
- **No search** - Can't grep or search across your conversation history easily
- **Not shareable** - Hard to share a useful conversation with teammates

This tool solves these by converting sessions to clean markdown files, saved directly in your project for easy access, search, and sharing.

## Features

- **Full conversation export** - Complete history with merged consecutive messages
- **Tool call details** - Separate file for tool usage with input parameters
- **Context compaction** - Preserved summaries when sessions are compressed
- **Session index** - Quick navigation across all sessions
- **Async processing** - Large files (>2MB) processed in background
- **Atomic updates** - Files always complete and readable
- **Auto timezone** - Timestamps in your local timezone

## Installation

### Quick Install

```bash
git clone https://github.com/samuelqin/claude-session-saver.git
cd claude-session-saver
./install.sh
```

### Manual Install

1. Copy `save-session.sh` to `~/.claude/hooks/`

2. Make it executable:
   ```bash
   chmod +x ~/.claude/hooks/save-session.sh
   ```

3. Add hooks to `~/.claude/settings.json`:
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

4. Restart Claude Code

## Output

Session history is saved to `<project>/.claude/session-history/`:

```
.claude/session-history/
├── [Index]Sessions.md              # Session index
├── [History]Title_01-15_1430_abc1.md    # Conversation
├── [ToolUse]Title_01-15_1430_abc1.md    # Tool details
└── [Compact]Title_01-15_1430_abc1.md    # Context summary
```

### File Types

| File | Description |
|------|-------------|
| `[History]*.md` | Main conversation with user/assistant messages |
| `[ToolUse]*.md` | Tool call details with input parameters |
| `[Compact]*.md` | Context compaction summaries |
| `[Index]Sessions.md` | Index of all sessions |

## Requirements

- macOS (uses `stat -f`, `date -j`)
- `jq` - JSON processor
- `perl` - For regex processing
- `python3` - For URL encoding

```bash
brew install jq
```

## Configuration

The script auto-detects:
- System timezone
- Project directory from Claude
- Git repository (auto-adds to .gitignore)

### Throttling

- Global: 10 second cooldown
- Large files (>2MB): 5 minute cooldown, async processing

## Uninstall

```bash
rm ~/.claude/hooks/save-session.sh
# Edit ~/.claude/settings.json and remove the "hooks" section
```

## License

MIT
