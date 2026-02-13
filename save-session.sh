#!/bin/bash
# Claude Code Session Auto-Save Hook
# Auto-saves Claude session history to project directory as readable markdown files
# 自动保存 Claude 会话历史到项目目录，生成可读的 markdown 文件
#
# Features / 功能:
# - Full conversation export with merged consecutive messages / 全量导出，合并连续消息
# - Large file async background processing / 大文件后台异步处理
# - Atomic file updates (temp file + mv) / 原子更新（临时文件 + mv）
# - System timezone auto-detection / 自动检测系统时区
# - System tags filtering / 过滤系统标签

INPUT=$(cat)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)}"
[ -z "$PROJECT_DIR" ] || [ "$PROJECT_DIR" = "null" ] && exit 0

PROJECT_HASH=$(echo "$PROJECT_DIR" | sed 's/[/ ]/-/g')
CLAUDE_SESSIONS_DIR="$HOME/.claude/projects/$PROJECT_HASH"
BACKUP_DIR="$PROJECT_DIR/.claude/session-history"

[ ! -d "$CLAUDE_SESSIONS_DIR" ] && exit 0

mkdir -p "$BACKUP_DIR"

# Background mode flag (passed by main process when spawning background worker)
# 后台模式标志（由主进程启动后台进程时传入）
BACKGROUND_MODE="${1:-}"

# Temp directory for atomic updates / 临时目录用于原子更新
TMP_DIR="$BACKUP_DIR/.tmp_$$"
mkdir -p "$TMP_DIR"
trap "rm -rf '$TMP_DIR'" EXIT

# Clean up stale temp directories (older than 1 hour) / 清理残留的临时目录（超过1小时的）
find "$BACKUP_DIR" -maxdepth 1 -name ".tmp_*" -type d -mmin +60 -exec rm -rf {} \; 2>/dev/null

# Get system timezone offset in hours / 获取系统时区偏移（小时）
get_tz_offset() {
    local offset_sec=$(date +%z | sed 's/\([+-]\)\([0-9][0-9]\)\([0-9][0-9]\)/\1\2*3600+\1\3*60/' | bc 2>/dev/null)
    [ -z "$offset_sec" ] && offset_sec=28800  # Default +8 / 默认 +8
    echo $((offset_sec / 3600))
}
TZ_OFFSET=$(get_tz_offset)

# Ensure session-history directory is git-ignored / 确保 session-history 目录被 git 忽略
GITIGNORE="$PROJECT_DIR/.gitignore"
if [ -d "$PROJECT_DIR/.git" ] && [ -f "$GITIGNORE" ]; then
    # Check if .claude/ or .claude/session-history/ is already ignored
    # 检查是否已忽略 .claude/ 或 .claude/session-history/
    if ! grep -qE '^/?\.claude/?$|^/?\.claude/session-history/?$' "$GITIGNORE" 2>/dev/null; then
        echo "" >> "$GITIGNORE"
        echo "# Claude session history (auto-added)" >> "$GITIGNORE"
        echo ".claude/session-history/" >> "$GITIGNORE"
    fi
elif [ -d "$PROJECT_DIR/.git" ] && [ ! -f "$GITIGNORE" ]; then
    # No .gitignore exists, create one / 没有 .gitignore，创建一个
    echo "# Claude session history (auto-added)" > "$GITIGNORE"
    echo ".claude/session-history/" >> "$GITIGNORE"
fi

# Throttling: 10s cooldown + simple lock to prevent concurrent runs
# 节流：10秒冷却 + 简单锁防并发
LOCK_FILE="$BACKUP_DIR/.lock"
LOCK_PID_FILE="$BACKUP_DIR/.lock_pid"
BG_PID_FILE="$BACKUP_DIR/.bg_pid"

# Background mode skips throttle check / 后台模式跳过节流检查
if [ "$BACKGROUND_MODE" != "--background" ]; then
    # Check if another process is running / 检查是否有其他进程在运行
    if [ -f "$LOCK_PID_FILE" ]; then
        old_pid=$(cat "$LOCK_PID_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            exit 0
        fi
    fi
    echo $$ > "$LOCK_PID_FILE"

    if [ -f "$LOCK_FILE" ]; then
        last_run=$(cat "$LOCK_FILE" 2>/dev/null || echo 0)
        if [ $(($(date +%s) - last_run)) -lt 10 ]; then
            rm -f "$LOCK_PID_FILE"
            exit 0
        fi
    fi

    date +%s > "$LOCK_FILE"
fi

# Convert UTC timestamp to local timezone / UTC 转本地时区
utc_to_local() {
    local ts="$1"
    [ -z "$ts" ] || [ "$ts" = "null" ] && return
    local h=$((10#${ts:11:2} + TZ_OFFSET))
    local d="${ts:0:10}"
    if [ $h -ge 24 ]; then
        h=$((h-24))
        d=$(date -j -v+1d -f "%Y-%m-%d" "$d" "+%Y-%m-%d" 2>/dev/null || echo "$d")
    elif [ $h -lt 0 ]; then
        h=$((h+24))
        d=$(date -j -v-1d -f "%Y-%m-%d" "$d" "+%Y-%m-%d" 2>/dev/null || echo "$d")
    fi
    printf "%s %02d:%s" "$d" "$h" "${ts:14:2}"
}

for jsonl_file in "$CLAUDE_SESSIONS_DIR"/*.jsonl; do
    [ -f "$jsonl_file" ] || continue

    # Skip empty sessions (need at least one user message and one assistant reply)
    # 跳过空会话（至少需要有一条用户消息和一条助手回复）
    # Use grep for fast detection, avoid loading entire file with jq -s
    # 用 grep 快速检测，避免 jq -s 加载整个文件
    grep -q '"type":"user"' "$jsonl_file" || continue
    grep -q '"type":"assistant"' "$jsonl_file" || continue

    # Large file handling: spawn background process for files > 2MB
    # 大文件处理：超过 2MB 的文件启动后台进程处理
    file_size=$(stat -f %z "$jsonl_file" 2>/dev/null || echo 0)
    if [ "$file_size" -gt 2097152 ] && [ "$BACKGROUND_MODE" != "--background" ]; then
        large_file_lock="$BACKUP_DIR/.large_$(basename "$jsonl_file" .jsonl)"

        # Check if background process is already running / 检查是否已有后台进程在处理
        if [ -f "$BG_PID_FILE" ]; then
            bg_pid=$(cat "$BG_PID_FILE" 2>/dev/null)
            if [ -n "$bg_pid" ] && kill -0 "$bg_pid" 2>/dev/null; then
                # Background process still running, skip / 后台进程还在运行，跳过
                continue
            fi
        fi

        # 5-minute throttle for large files / 大文件5分钟节流
        if [ -f "$large_file_lock" ]; then
            last_large=$(cat "$large_file_lock" 2>/dev/null || echo 0)
            if [ $(($(date +%s) - last_large)) -lt 300 ]; then
                continue
            fi
        fi
        date +%s > "$large_file_lock"

        # Spawn background process (use nohup to detach from terminal)
        # 启动后台进程处理大文件（用 nohup 确保脱离终端）
        nohup bash -c "
            export CLAUDE_PROJECT_DIR='$PROJECT_DIR'
            export BACKUP_DIR='$BACKUP_DIR'
            export CLAUDE_SESSIONS_DIR='$CLAUDE_SESSIONS_DIR'
            '$0' --background
        " &>/dev/null &
        echo $! > "$BG_PID_FILE"

        # Main process skips this file, continue with smaller files
        # 主进程跳过此文件，继续处理其他小文件
        continue
    fi

    session_id=$(basename "$jsonl_file" .jsonl)
    short_id="${session_id:0:4}"

    # Get session title / 获取会话标题
    # 1. Prefer title from existing md file (preserve user edits)
    #    优先从已有 md 文件读取标题（保留用户修改）
    # 2. Otherwise use first user message / 否则用第一条用户消息
    session_title=""
    old_file=""
    old_tools_file=""

    # Find existing md file for this session (via .session_map)
    # 查找属于当前 session 的 md 文件（通过 .session_map 映射）
    session_map="$BACKUP_DIR/.session_map"
    existing_file=$(grep "^${session_id}=" "$session_map" 2>/dev/null | cut -d'=' -f2-)

    if [ -n "$existing_file" ] && [ -f "$existing_file" ]; then
        # Read title from existing file (first line without #)
        # 从已有文件读取标题（第一行去掉 # ）
        session_title=$(head -1 "$existing_file" | sed 's/^# //')
        old_file="$existing_file"
        old_tools_file=$(echo "$existing_file" | sed 's/\[History\]/[ToolUse]/')
    fi

    if [ -z "$session_title" ]; then
        # Get first user message content (skip <xxx> system tags)
        # 获取第一条用户消息中的真实内容（跳过 <xxx> 系统标签）
        session_title=$(jq -r 'select(.type == "user") | .message.content | if type == "array" then .[] | select(type == "object" and .type == "text") | .text else . end' "$jsonl_file" 2>/dev/null | grep -v '^<' | grep -v '^$' | head -1 | cut -c1-50 | tr '\n' ' ')
    fi

    # Title fallback: check for empty, whitespace-only, null, or garbled
    # 标题容错：检查是否为空、纯空格、null 或乱码
    clean_title=$(echo "$session_title" | tr -cd '[:print:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$clean_title" ] || [ "$clean_title" = "null" ] || [ ${#clean_title} -lt 2 ]; then
        session_title="Session_${short_id}"
    else
        session_title="$clean_title"
    fi

    safe_title=$(echo "$session_title" | sed 's/[\/\\:*?"<>|]/-/g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
    [ -z "$safe_title" ] && safe_title="untitled"

    start_time=$(head -1 "$jsonl_file" | jq -r '.timestamp // empty' 2>/dev/null)
    formatted_start=$(utc_to_local "$start_time")
    [ -z "$formatted_start" ] && formatted_start="Unknown"

    # Filename time format: MM-DD_HHMM / 文件名用的时间格式：MM-DD_HHMM
    file_time=$(echo "$formatted_start" | sed 's/^[0-9]*-//' | sed 's/ /_/' | sed 's/://')
    [ -z "$file_time" ] || [ "$file_time" = "Unknown" ] && file_time="unknown"

    # Filename format: [History]title_time_id.md / 文件名格式：[History]标题_时间_id.md
    md_file="$BACKUP_DIR/[History]${safe_title}_${file_time}_${short_id}.md"
    tools_file="$BACKUP_DIR/[ToolUse]${safe_title}_${file_time}_${short_id}.md"
    compact_file="$BACKUP_DIR/[Compact]${safe_title}_${file_time}_${short_id}.md"

    # Temp file paths for atomic update / 临时文件路径（用于原子更新）
    tmp_md_file="$TMP_DIR/[History]${safe_title}_${file_time}_${short_id}.md"
    tmp_tools_file="$TMP_DIR/[ToolUse]${safe_title}_${file_time}_${short_id}.md"
    tmp_compact_file="$TMP_DIR/[Compact]${safe_title}_${file_time}_${short_id}.md"

    # Skip if source file is not newer than output / 检查源文件是否比输出文件新（跳过无变化的）
    if [ -f "$md_file" ]; then
        src_mtime=$(stat -f %m "$jsonl_file" 2>/dev/null)
        dst_mtime=$(stat -f %m "$md_file" 2>/dev/null)
        [ "$src_mtime" -le "$dst_mtime" ] && continue
    fi

    # Generate conversation header (write to temp file)
    # 生成会话记录头部（写到临时文件）
    cat > "$tmp_md_file" << EOF
# ${session_title}
> Started: ${formatted_start}
> [View Tool Details]([ToolUse]${safe_title}_${file_time}_${short_id}.md)

---

EOF

    # Save session_id to file mapping (for reading user-modified titles next time)
    # 保存 session_id 到文件的映射（用于下次读取用户修改的标题）
    grep -v "^${session_id}=" "$session_map" > "${session_map}.tmp" 2>/dev/null || true
    echo "${session_id}=${md_file}" >> "${session_map}.tmp"
    mv "${session_map}.tmp" "$session_map"

    # Generate tool details header (write to temp file)
    # 生成工具详情头部（写到临时文件）
    cat > "$tmp_tools_file" << EOF
# Tool Details - ${session_title}
> [Back to Conversation]([History]${safe_title}_${file_time}_${short_id}.md)

---

EOF

    # Extract tool call details / 提取工具调用详情
    jq -c 'select(.type == "assistant") | select(.message.content != null) | {timestamp: .timestamp, tools: [.message.content[] | select(.type == "tool_use")]} | .tools[] as $tool | {timestamp, tool: $tool}' "$jsonl_file" 2>/dev/null | while read -r tool_entry; do
        timestamp=$(echo "$tool_entry" | jq -r '.timestamp // ""')
        tool=$(echo "$tool_entry" | jq -r '.tool')
        tool_name=$(echo "$tool" | jq -r '.name // "unknown"')
        tool_id=$(echo "$tool" | jq -r '.id // "unknown"')

        formatted_time=$(utc_to_local "$timestamp")
        time_only="${formatted_time:11:5}"

        # Truncation warning / 截断提示
        tool_input_raw=$(echo "$tool" | jq -r '.input | tojson' 2>/dev/null)
        if [ ${#tool_input_raw} -gt 5000 ]; then
            tool_input="${tool_input_raw:0:5000}...\n\n> ⚠️ Content truncated (original: ${#tool_input_raw} chars)"
        else
            tool_input="$tool_input_raw"
        fi

        cat >> "$tmp_tools_file" << EOF
## ${tool_name} - ${time_only}
<a id="tool-${tool_id}"></a>

\`\`\`json
${tool_input}
\`\`\`

---

EOF
    done

    # Extract and format conversation (merge consecutive messages, separate compact summary)
    # 提取并格式化对话（合并连续消息，分离 compact summary）
    # First detect if there's a compact summary / 先检测是否有 compact summary
    has_compact=$(jq -r 'select(.type == "user") | .message.content | if type == "array" then .[] | select(.type == "text") | .text else . end' "$jsonl_file" 2>/dev/null | grep -c "This session is being continued from a previous conversation" 2>/dev/null | tail -1)
    [ -z "$has_compact" ] && has_compact=0

    if [ "$has_compact" -gt 0 ]; then
        # Generate compact file header (write to temp file)
        # 生成 compact 文件头部（写到临时文件）
        cat > "$tmp_compact_file" << EOF
# Compact Summary - ${session_title}
> [Back to Conversation]([History]${safe_title}_${file_time}_${short_id}.md)

---

EOF
        # Extract compact summary content / 提取 compact summary 内容
        jq -r 'select(.type == "user") | .message.content | if type == "array" then .[] | select(.type == "text") | .text else . end' "$jsonl_file" 2>/dev/null | grep -A 10000 "This session is being continued from a previous conversation" | head -n 500 >> "$tmp_compact_file"
    fi

    jq -rs --arg tools_file "[ToolUse]${safe_title}_${file_time}_${short_id}.md" --arg compact_file "[Compact]${safe_title}_${file_time}_${short_id}.md" --argjson tz_offset "$TZ_OFFSET" '
        # Function: clean system tags / 函数：清理系统标签
        def clean_system_tags:
            gsub("<system-reminder>[\\s\\S]*?</system-reminder>"; "") |
            gsub("<ide_opened_file>[\\s\\S]*?</ide_opened_file>"; "") |
            gsub("<user-prompt-submit-hook>[\\s\\S]*?</user-prompt-submit-hook>"; "") |
            gsub("^\\s+|\\s+$"; "");

        [.[] | select(.type == "user" or .type == "assistant") | select(.message != null) |
        {
            type: .type,
            timestamp: .timestamp,
            content: (
                if .message.content then
                    if (.message.content | type) == "array" then
                        [.message.content[] |
                            if type == "string" then . | clean_system_tags
                            elif .type == "text" then
                                # Replace compact summary with prominent link placeholder
                                # compact summary 替换为醒目的链接占位符
                                if (.text | contains("This session is being continued from a previous conversation")) then
                                    "\n---\n\n## 📦 Context Compaction\n\n> **Session context was compressed at this point.**\n> Previous conversation summary available below.\n\n➡️ **[View Full Compact Summary](\($compact_file))**\n\n---\n"
                                else .text | clean_system_tags
                                end
                            elif .type == "tool_use" then "🔧 [\(.name)](\($tools_file)#tool-\(.id))"
                            else null
                            end
                        ] | map(select(. != null and . != "")) | join("\n")
                    else
                        # Non-array content also check for compact
                        # 非数组内容也检查 compact
                        if (.message.content | contains("This session is being continued from a previous conversation")) then
                            "\n---\n\n## 📦 Context Compaction\n\n> **Session context was compressed at this point.**\n> Previous conversation summary available below.\n\n➡️ **[View Full Compact Summary](\($compact_file))**\n\n---\n"
                        else .message.content | clean_system_tags
                        end
                    end
                else null
                end
            )
        } | select(.content != null and .content != "")] |

        # Merge consecutive messages of same type / 合并连续相同类型的消息
        reduce .[] as $item (
            [];
            if length == 0 then [$item]
            elif (last.type == $item.type) then
                (.[:-1] + [{type: $item.type, timestamp: last.timestamp, content: (last.content + "\n\n" + $item.content)}])
            else . + [$item]
            end
        ) |

        .[] |
        # Convert UTC to local timezone / UTC 转本地时区
        (.timestamp | if . then
            (.[11:13] | tonumber) as $h |
            (.[14:16]) as $m |
            (($h + $tz_offset) | if . >= 24 then . - 24 elif . < 0 then . + 24 else . end) as $new_h |
            "\($new_h | if . < 10 then "0\(.)" else "\(.)" end):\($m)"
        else "" end) as $time |
        if .type == "user" then
            "## 👤 User - \($time)\n\n\(.content)\n\n---\n"
        else
            "## 🤖 Claude - \($time)\n\n\(.content)\n\n---\n"
        end
    ' "$jsonl_file" >> "$tmp_md_file" 2>/dev/null

    # Post-processing: clean system tags (multiline matching)
    # 后处理：清理系统标签（多行匹配）
    perl -i -0pe 's/<system-reminder>.*?<\/system-reminder>\s*//gs' "$tmp_md_file" 2>/dev/null
    perl -i -0pe 's/<ide_opened_file>.*?<\/ide_opened_file>\s*//gs' "$tmp_md_file" 2>/dev/null
    perl -i -0pe 's/<user-prompt-submit-hook>.*?<\/user-prompt-submit-hook>\s*//gs' "$tmp_md_file" 2>/dev/null

    # Atomic update: delete old files first, then move temp files to target
    # 原子更新：先删除旧文件，再移动临时文件到目标位置
    if [ -n "$old_file" ] && [ -f "$old_file" ] && [ "$old_file" != "$md_file" ]; then
        rm -f "$old_file" "$old_tools_file"
        old_compact_file=$(echo "$old_file" | sed 's/\[History\]/[Compact]/')
        rm -f "$old_compact_file"
    fi
    mv "$tmp_md_file" "$md_file"
    mv "$tmp_tools_file" "$tools_file"
    [ -f "$tmp_compact_file" ] && mv "$tmp_compact_file" "$compact_file"

done

# Generate index file (reverse chronological order, atomic update)
# 生成索引文件（按时间倒序，原子更新）
generate_index() {
    local INDEX_FILE="$BACKUP_DIR/[Index]Sessions.md"
    local TMP_INDEX="$TMP_DIR/[Index]Sessions.md"
    cat > "$TMP_INDEX" << EOF
# Session History Index
> Last updated: $(date '+%Y-%m-%d %H:%M:%S')

| Time | Title | History | Tools |
|------|-------|---------|-------|
EOF
    for hist_file in $(ls -t "$BACKUP_DIR"/\[History\]*.md 2>/dev/null); do
        [ -f "$hist_file" ] || continue
        filename=$(basename "$hist_file")
        title=$(head -1 "$hist_file" | sed 's/^# //')
        file_time=$(echo "$filename" | grep -oE '[0-9]{2}-[0-9]{2}_[0-9]{4}' | head -1)
        [ -z "$file_time" ] && file_time="unknown"
        tools_file=$(echo "$filename" | sed 's/\[History\]/[ToolUse]/')
        # Full URL encoding (use python for Chinese and special chars)
        # 完整 URL 编码（使用 python 处理中文和特殊字符）
        encoded_hist=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$filename'))")
        encoded_tools=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$tools_file'))")
        echo "| $file_time | $title | [History]($encoded_hist) | [Tools]($encoded_tools) |" >> "$TMP_INDEX"
    done
    mv "$TMP_INDEX" "$INDEX_FILE"
}

generate_index

echo "Last backup: $(date '+%Y-%m-%d %H:%M:%S')" > "$BACKUP_DIR/.last-backup"

# Clean up lock files / 清理锁文件
if [ "$BACKGROUND_MODE" = "--background" ]; then
    rm -f "$BG_PID_FILE"
else
    rm -f "$LOCK_PID_FILE"
fi

exit 0
