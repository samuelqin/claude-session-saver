#!/bin/bash
# Claude Session Saver - One-click Installer
# Claude 会话保存器 - 一键安装脚本
#
# Usage / 用法: curl -fsSL <url>/install.sh | bash
# Or / 或者: bash install.sh

set -e

# Colors for output / 输出颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Claude Session Saver - Installer                       ║${NC}"
echo -e "${BLUE}║     Claude 会话保存器 - 安装程序                           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check dependencies / 检查依赖
echo -e "${YELLOW}[1/4]${NC} Checking dependencies / 检查依赖..."

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}✗ $1 not found / 未找到 $1${NC}"
        echo -e "  Please install $1 first / 请先安装 $1"
        exit 1
    fi
    echo -e "${GREEN}✓${NC} $1"
}

check_command "jq"
check_command "perl"
check_command "python3"

# Create directories / 创建目录
echo ""
echo -e "${YELLOW}[2/4]${NC} Creating directories / 创建目录..."

HOOKS_DIR="$HOME/.claude/hooks"
mkdir -p "$HOOKS_DIR"
echo -e "${GREEN}✓${NC} $HOOKS_DIR"

# Install hook script / 安装钩子脚本
echo ""
echo -e "${YELLOW}[3/4]${NC} Installing hook script / 安装钩子脚本..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$HOOKS_DIR/save-session.sh"

# Check if running from local or remote / 检查是本地还是远程安装
if [ -f "$SCRIPT_DIR/save-session.sh" ]; then
    # Local install / 本地安装
    cp "$SCRIPT_DIR/save-session.sh" "$HOOK_SCRIPT"
else
    # Remote install - download from GitHub / 远程安装 - 从 GitHub 下载
    REPO_URL="https://raw.githubusercontent.com/YOUR_USERNAME/claude-session-saver/main"
    curl -fsSL "$REPO_URL/save-session.sh" -o "$HOOK_SCRIPT"
fi

chmod +x "$HOOK_SCRIPT"
echo -e "${GREEN}✓${NC} Installed to / 已安装到: $HOOK_SCRIPT"

# Configure Claude settings / 配置 Claude 设置
echo ""
echo -e "${YELLOW}[4/4]${NC} Configuring Claude hooks / 配置 Claude 钩子..."

SETTINGS_FILE="$HOME/.claude/settings.json"

# Create or update settings.json / 创建或更新 settings.json
if [ -f "$SETTINGS_FILE" ]; then
    # Backup existing settings / 备份现有设置
    cp "$SETTINGS_FILE" "$SETTINGS_FILE.backup"
    echo -e "${GREEN}✓${NC} Backed up existing settings / 已备份现有设置"

    # Check if hooks already configured / 检查是否已配置钩子
    if jq -e '.hooks.PostToolUse' "$SETTINGS_FILE" &>/dev/null; then
        echo -e "${YELLOW}!${NC} Hooks already configured, skipping / 钩子已配置，跳过"
    else
        # Add hooks to existing settings / 添加钩子到现有设置
        jq --arg script "$HOOK_SCRIPT" '.hooks = {
            "PostToolUse": [{"hooks": [{"type": "command", "command": $script}]}],
            "Stop": [{"hooks": [{"type": "command", "command": ("sleep 1 && " + $script)}]}]
        }' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
        echo -e "${GREEN}✓${NC} Added hooks to settings / 已添加钩子到设置"
    fi
else
    # Create new settings file / 创建新设置文件
    cat > "$SETTINGS_FILE" << EOF
{
  "hooks": {
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOOK_SCRIPT"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "sleep 1 && $HOOK_SCRIPT"
          }
        ]
      }
    ]
  }
}
EOF
    echo -e "${GREEN}✓${NC} Created settings file / 已创建设置文件"
fi

# Done / 完成
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Installation Complete! / 安装完成！                    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Session history will be saved to / 会话历史将保存到:"
echo -e "  ${BLUE}<project>/.claude/session-history/${NC}"
echo ""
echo -e "Files generated / 生成的文件:"
echo -e "  • ${BLUE}[History]*.md${NC}  - Conversation history / 对话历史"
echo -e "  • ${BLUE}[ToolUse]*.md${NC}  - Tool call details / 工具调用详情"
echo -e "  • ${BLUE}[Compact]*.md${NC}  - Context summaries / 上下文摘要"
echo -e "  • ${BLUE}[Index]Sessions.md${NC} - Session index / 会话索引"
echo ""
echo -e "${YELLOW}Note / 注意:${NC}"
echo -e "  Restart Claude Code for changes to take effect"
echo -e "  重启 Claude Code 使更改生效"
echo ""
