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
#
# Directory structure / 目录结构:
# .claude/session-history/
# ├── index.md              # Session index / 会话索引
# ├── history/              # Conversation files / 对话文件
# ├── tooluse/              # Tool call details / 工具调用详情
# ├── compact/              # Context summaries / 上下文摘要
# └── .meta/                # Metadata files / 元数据文件

INPUT=$(cat)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)}"
[ -z "$PROJECT_DIR" ] || [ "$PROJECT_DIR" = "null" ] && exit 0

PROJECT_HASH=$(echo "$PROJECT_DIR" | sed 's/[/ ]/-/g')
CLAUDE_SESSIONS_DIR="$HOME/.claude/projects/$PROJECT_HASH"
BACKUP_DIR="$PROJECT_DIR/.claude/session-history"

[ ! -d "$CLAUDE_SESSIONS_DIR" ] && exit 0

# Create directory structure / 创建目录结构
mkdir -p "$BACKUP_DIR/history" "$BACKUP_DIR/tooluse" "$BACKUP_DIR/compact" "$BACKUP_DIR/.meta"

# Background mode flag (passed by main process when spawning background worker)
# 后台模式标志（由主进程启动后台进程时传入）
BACKGROUND_MODE="${1:-}"

# Temp directory for atomic updates / 临时目录用于原子更新
TMP_DIR="$BACKUP_DIR/.meta/.tmp_$$"
mkdir -p "$TMP_DIR"
trap "rm -rf '$TMP_DIR'" EXIT

# Clean up stale temp directories (older than 1 hour) / 清理残留的临时目录（超过1小时的）
find "$BACKUP_DIR/.meta" -maxdepth 1 -name ".tmp_*" -type d -mmin +60 -exec rm -rf {} \; 2>/dev/null

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
    if ! grep -qE '^/?\.claude/?$|^/?\.claude/session-history/?$' "$GITIGNORE" 2>/dev/null; then
        echo "" >> "$GITIGNORE"
        echo "# Claude session history (auto-added)" >> "$GITIGNORE"
        echo ".claude/session-history/" >> "$GITIGNORE"
    fi
elif [ -d "$PROJECT_DIR/.git" ] && [ ! -f "$GITIGNORE" ]; then
    echo "# Claude session history (auto-added)" > "$GITIGNORE"
    echo ".claude/session-history/" >> "$GITIGNORE"
fi

# Throttling: 10s cooldown + simple lock to prevent concurrent runs
# 节流：10秒冷却 + 简单锁防并发
LOCK_FILE="$BACKUP_DIR/.meta/.lock"
LOCK_PID_FILE="$BACKUP_DIR/.meta/.lock_pid"
BG_PID_FILE="$BACKUP_DIR/.meta/.bg_pid"

# Background mode skips throttle check / 后台模式跳过节流检查
if [ "$BACKGROUND_MODE" != "--background" ]; then
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
    grep -q '"type":"user"' "$jsonl_file" || continue
    grep -q '"type":"assistant"' "$jsonl_file" || continue

    # Large file handling: spawn background process for files > 2MB
    # 大文件处理：超过 2MB 的文件启动后台进程处理
    file_size=$(stat -f %z "$jsonl_file" 2>/dev/null || echo 0)
    if [ "$file_size" -gt 2097152 ] && [ "$BACKGROUND_MODE" != "--background" ]; then
        large_file_lock="$BACKUP_DIR/.meta/.large_$(basename "$jsonl_file" .jsonl)"

        if [ -f "$BG_PID_FILE" ]; then
            bg_pid=$(cat "$BG_PID_FILE" 2>/dev/null)
            if [ -n "$bg_pid" ] && kill -0 "$bg_pid" 2>/dev/null; then
                continue
            fi
        fi

        if [ -f "$large_file_lock" ]; then
            last_large=$(cat "$large_file_lock" 2>/dev/null || echo 0)
            if [ $(($(date +%s) - last_large)) -lt 300 ]; then
                continue
            fi
        fi
        date +%s > "$large_file_lock"

        nohup bash -c "
            export CLAUDE_PROJECT_DIR='$PROJECT_DIR'
            export BACKUP_DIR='$BACKUP_DIR'
            export CLAUDE_SESSIONS_DIR='$CLAUDE_SESSIONS_DIR'
            '$0' --background
        " &>/dev/null &
        echo $! > "$BG_PID_FILE"
        continue
    fi

    session_id=$(basename "$jsonl_file" .jsonl)
    short_id="${session_id:0:4}"

    # Get session title / 获取会话标题
    session_title=""
    old_file=""
    old_tools_file=""

    # Find existing md file for this session (via .session_map)
    # 查找属于当前 session 的 md 文件（通过 .session_map 映射）
    session_map="$BACKUP_DIR/.meta/.session_map"
    existing_file=$(grep "^${session_id}=" "$session_map" 2>/dev/null | cut -d'=' -f2-)

    if [ -n "$existing_file" ] && [ -f "$existing_file" ]; then
        session_title=$(head -1 "$existing_file" | sed 's/^# //')
        old_file="$existing_file"
        # Derive old tooluse file path from history file
        old_basename=$(basename "$existing_file")
        old_tools_file="$BACKUP_DIR/tooluse/$old_basename"
    fi

    if [ -z "$session_title" ]; then
        session_title=$(jq -r 'select(.type == "user") | .message.content | if type == "array" then .[] | select(type == "object" and .type == "text") | .text else . end' "$jsonl_file" 2>/dev/null | grep -v '^<' | grep -v '^$' | head -1 | cut -c1-50 | tr '\n' ' ')
    fi

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

    file_time=$(echo "$formatted_start" | sed 's/^[0-9]*-//' | sed 's/ /_/' | sed 's/://')
    [ -z "$file_time" ] || [ "$file_time" = "Unknown" ] && file_time="unknown"

    # New file paths (in subdirectories, without [Type] prefix)
    # 新文件路径（在子目录中，不带 [Type] 前缀）
    base_name="${safe_title}_${file_time}_${short_id}.md"
    md_file="$BACKUP_DIR/history/$base_name"
    tools_file="$BACKUP_DIR/tooluse/$base_name"
    compact_file="$BACKUP_DIR/compact/$base_name"

    # Temp file paths / 临时文件路径
    tmp_md_file="$TMP_DIR/$base_name"
    tmp_tools_file="$TMP_DIR/tooluse_$base_name"
    tmp_compact_file="$TMP_DIR/compact_$base_name"

    # Skip if source file is not newer than output / 检查源文件是否比输出文件新
    if [ -f "$md_file" ]; then
        src_mtime=$(stat -f %m "$jsonl_file" 2>/dev/null)
        dst_mtime=$(stat -f %m "$md_file" 2>/dev/null)
        [ "$src_mtime" -le "$dst_mtime" ] && continue
    fi

    # Generate conversation header / 生成会话记录头部
    cat > "$tmp_md_file" << EOF
# ${session_title}
> Started: ${formatted_start}
> [View Tool Details](../tooluse/${base_name})

---

EOF

    # Save session_id to file mapping / 保存 session_id 到文件的映射
    grep -v "^${session_id}=" "$session_map" > "${session_map}.tmp" 2>/dev/null || true
    echo "${session_id}=${md_file}" >> "${session_map}.tmp"
    mv "${session_map}.tmp" "$session_map"

    # Generate tool details header / 生成工具详情头部
    cat > "$tmp_tools_file" << EOF
# Tool Details - ${session_title}
> [Back to Conversation](../history/${base_name})

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

    # Check for compact summary / 检测是否有 compact summary
    has_compact=$(jq -r 'select(.type == "user") | .message.content | if type == "array" then .[] | select(.type == "text") | .text else . end' "$jsonl_file" 2>/dev/null | grep -c "This session is being continued from a previous conversation" 2>/dev/null | tail -1)
    [ -z "$has_compact" ] && has_compact=0

    if [ "$has_compact" -gt 0 ]; then
        cat > "$tmp_compact_file" << EOF
# Compact Summary - ${session_title}
> [Back to Conversation](../history/${base_name})

---

EOF
        jq -r 'select(.type == "user") | .message.content | if type == "array" then .[] | select(.type == "text") | .text else . end' "$jsonl_file" 2>/dev/null | grep -A 10000 "This session is being continued from a previous conversation" | head -n 500 >> "$tmp_compact_file"
    fi

    # Extract and format conversation / 提取并格式化对话
    jq -rs --arg tools_file "../tooluse/${base_name}" --arg compact_file "../compact/${base_name}" --argjson tz_offset "$TZ_OFFSET" '
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
                                if (.text | contains("This session is being continued from a previous conversation")) then
                                    "\n---\n\n## 📦 Context Compaction\n\n> **Session context was compressed at this point.**\n> Previous conversation summary available below.\n\n➡️ **[View Full Compact Summary](\($compact_file))**\n\n---\n"
                                else .text | clean_system_tags
                                end
                            elif .type == "tool_use" then "🔧 [\(.name)](\($tools_file)#tool-\(.id))"
                            else null
                            end
                        ] | map(select(. != null and . != "")) | join("\n")
                    else
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

    # Post-processing: clean system tags / 后处理：清理系统标签
    perl -i -0pe 's/<system-reminder>.*?<\/system-reminder>\s*//gs' "$tmp_md_file" 2>/dev/null
    perl -i -0pe 's/<ide_opened_file>.*?<\/ide_opened_file>\s*//gs' "$tmp_md_file" 2>/dev/null
    perl -i -0pe 's/<user-prompt-submit-hook>.*?<\/user-prompt-submit-hook>\s*//gs' "$tmp_md_file" 2>/dev/null

    # Atomic update: delete old files first, then move temp files
    # 原子更新：先删除旧文件，再移动临时文件
    if [ -n "$old_file" ] && [ -f "$old_file" ] && [ "$old_file" != "$md_file" ]; then
        rm -f "$old_file"
        [ -f "$old_tools_file" ] && rm -f "$old_tools_file"
        old_compact_file="$BACKUP_DIR/compact/$(basename "$old_file")"
        [ -f "$old_compact_file" ] && rm -f "$old_compact_file"
    fi
    mv "$tmp_md_file" "$md_file"
    mv "$tmp_tools_file" "$tools_file"
    [ -f "$tmp_compact_file" ] && mv "$tmp_compact_file" "$compact_file"

done

# Generate index file (reverse chronological order, atomic update)
# 生成索引文件（按时间倒序，原子更新）
generate_index() {
    local INDEX_FILE="$BACKUP_DIR/index.md"
    local TMP_INDEX="$TMP_DIR/index.md"
    cat > "$TMP_INDEX" << EOF
# Session History Index
> Last updated: $(date '+%Y-%m-%d %H:%M:%S')

| Time | Title | History | Tools |
|------|-------|---------|-------|
EOF
    find "$BACKUP_DIR/history" -maxdepth 1 -name "*.md" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | while IFS= read -r hist_file; do
        [ -f "$hist_file" ] || continue
        filename=$(basename "$hist_file")
        title=$(head -1 "$hist_file" | sed 's/^# //')
        file_time=$(echo "$filename" | grep -oE '[0-9]{2}-[0-9]{2}_[0-9]{4}' | head -1)
        [ -z "$file_time" ] && file_time="unknown"
        # URL encoding for Chinese and special chars
        encoded_hist=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$filename'))")
        echo "| $file_time | $title | [History](history/$encoded_hist) | [Tools](tooluse/$encoded_hist) |" >> "$TMP_INDEX"
    done
    mv "$TMP_INDEX" "$INDEX_FILE"
}

generate_index

echo "Last backup: $(date '+%Y-%m-%d %H:%M:%S')" > "$BACKUP_DIR/.meta/.last-backup"

# Clean up lock files / 清理锁文件
if [ "$BACKGROUND_MODE" = "--background" ]; then
    rm -f "$BG_PID_FILE"
else
    rm -f "$LOCK_PID_FILE"
fi

exit 0
