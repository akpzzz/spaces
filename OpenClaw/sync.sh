#!/bin/sh

# ----------------------------
# 备份目录配置
# ----------------------------

# 定义要备份的目录和文件（绝对路径）
# 注意：此脚本使用简单 shell 语法，避免复杂嵌套结构
# 使用多个变量来组织配置

# 1. 配置文件 - 必须备份（支持通配符）
CONFIG_FILES="
/root/.openclaw/openclaw.json
/root/.openclaw/openclaw.json*
/root/.openclaw/config.json
/root/.openclaw/settings.json
/root/.openclaw/env.json
/root/.openclaw/openclaw.yaml
/root/.openclaw/config.yaml
"

# 2. 目录（末尾加 / 表示目录）
DIRECTORIES="
/root/.openclaw/workspace/
/root/.openclaw/memory/
"

# 3. 需要搜索的配置文件模式（额外模式，与上面合并）
SEARCH_PATTERNS="
/root/.openclaw/openclaw.json*
/root/.openclaw/*.config.json
/root/.openclaw/*settings*.json
/root/.openclaw/*.yaml
/root/.openclaw/*.yml
"

# 4. 排除列表（支持通配符）
EXCLUDES="
# 文件排除
/root/.openclaw/update-check.json
/root/.openclaw/exec-approvals.json
*.log
*.tmp
*/.log
*/.tmp

# 目录排除
/root/.openclaw/workspace/.openclaw/
/root/.openclaw/__pycache__/
/root/.openclaw/workspace/script/__pycache__/
/root/.openclaw/.git/
/root/.openclaw/.cache/
/root/.openclaw/node_modules/
/root/.openclaw/workspace/reports/
/root/.openclaw/workspace/memory/
/root/.openclaw/.venv/
/root/.openclaw/venv/
"

# 合并所有需要备份的路径（保持目录的 / 后缀）
OPENCLAW_PATHS=""

# 先添加目录（保持原样，包含末尾的 /）
for p in $DIRECTORIES; do
    case " $OPENCLAW_PATHS " in
        *" $p "*) ;;
        *) OPENCLAW_PATHS="$OPENCLAW_PATHS $p" ;;
    esac
done

# 再添加配置文件（不带末尾 /）
for p in $CONFIG_FILES; do
    case " $OPENCLAW_PATHS " in
        *" $p "*) ;;
        *) OPENCLAW_PATHS="$OPENCLAW_PATHS $p" ;;
    esac
done

# 最后添加搜索模式
for p in $SEARCH_PATTERNS; do
    case " $OPENCLAW_PATHS " in
        *" $p "*) ;;
        *) OPENCLAW_PATHS="$OPENCLAW_PATHS $p" ;;
    esac
done

# 构建 rclone 排除参数
EXCLUDE_ARGS=""
for e in $EXCLUDES; do
    # 跳过注释行和空行
    case "$e" in
        \#*|"") continue ;;
    esac
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude $e"
done

# ----------------------------
# 备份函数
# ----------------------------
backup() {
    echo "=== 开始备份 ==="
    echo "排除规则: $EXCLUDE_ARGS"
    echo ""

    # 展开通配符，获取实际存在的文件
    for pattern in $OPENCLAW_PATHS; do
        # 检查是否包含通配符
        case "$pattern" in
            *\**)
                # 包含通配符，使用 ls 展开（注意：可能展开多个）
                for expanded in $(ls -d $pattern 2>/dev/null); do
                    backup_single_path "$expanded"
                done
                ;;
            */)
                # 以 / 结尾的路径，作为目录处理
                backup_single_path "$pattern"
                ;;
            *)
                backup_single_path "$pattern"
                ;;
        esac
    done

    echo "=== 备份完成 ==="
}

backup_single_path() {
    path="$1"
    
    # 判断是否为目录（路径以 / 结尾或实际为目录）
    if [ "${path%/}" != "$path" ] || [ -d "$path" ]; then
        # 确保路径以 / 结尾（用于远程路径）
        dir_path="${path%/}/"
        
        echo "📁 备份目录: $dir_path"
        
        # 先确保远程目录存在
        rclone mkdir "$REMOTE_FOLDER/$dir_path" 2>/dev/null || true
        
        # 然后同步内容，应用排除规则
        rclone sync --checksum --progress --create-empty-src-dirs \
            $EXCLUDE_ARGS \
            "$dir_path" "$REMOTE_FOLDER/$dir_path"
        echo "✅ 完成: $dir_path"
    elif [ -f "$path" ]; then
        # 文件备份，保留父目录结构
        echo "📄 备份文件: $path"
        parent_dir=$(dirname "$path")
        
        # 确保远程父目录存在
        rclone mkdir "$REMOTE_FOLDER$parent_dir/" 2>/dev/null || true
        
        rclone copy --checksum --progress \
            "$path" "$REMOTE_FOLDER$parent_dir/"
        echo "✅ 完成: $path"
    else
        # 尝试通配符扩展（如果模式本身不包含通配符但匹配不到）
        if [ "$(echo $path)" != "$path" ]; then
            # 有通配符扩展结果
            for expanded in $(echo $path); do
                [ -e "$expanded" ] && echo "✅ 备份: $expanded"
            done
        else
            echo "⚠️ 路径不存在: $path"
        fi
    fi
}

# ----------------------------
# 还原函数
# ----------------------------
restore() {
    echo "=== 开始还原备份 ==="
    echo "排除规则: $EXCLUDE_ARGS"
    echo ""

    # 还原目录和文件
    for pattern in $OPENCLAW_PATHS; do
        # 只还原明确存在的远程路径，不通配
        case "$pattern" in
            *\**)
                # 跳过通配符模式，因为它们不是具体路径
                echo "ℹ️ 跳过模式（还原时需具体路径）: $pattern"
                ;;
            */)
                # 目录还原（保持末尾 /）
                echo "📁 还原目录: $pattern"
                mkdir -p "$pattern"
                rclone sync --checksum --progress --create-empty-src-dirs \
                    $EXCLUDE_ARGS \
                    "$REMOTE_FOLDER/$pattern" "$pattern"
                echo "✅ 完成: $pattern"
                ;;
            *)
                # 文件还原
                if [ -f "$pattern" ] || [ ! -e "$pattern" ]; then
                    echo "📄 还原文件: $pattern"
                    target_dir=$(dirname "$pattern")
                    mkdir -p "$target_dir"
                    
                    parent_dir=$(dirname "$pattern")
                    filename=$(basename "$pattern")
                    rclone copy --checksum --progress \
                        "$REMOTE_FOLDER$parent_dir/$filename" "$target_dir/"
                    echo "✅ 完成: $pattern"
                fi
                ;;
        esac
    done

    echo "=== 还原完成 ==="
}

# ----------------------------
# 主入口
# ----------------------------
case "$1" in
    backup)
        backup
        ;;
    restore)
        restore
        ;;
    *)
        echo "Usage: $0 {backup|restore}"
        echo ""
        echo "配置说明："
        echo "  CONFIG_FILES    - 配置文件（支持通配符）"
        echo "  DIRECTORIES     - 目录（末尾必须加 /）"
        echo "  SEARCH_PATTERNS - 额外搜索模式"
        echo "  EXCLUDES        - 排除规则（支持通配符，包括 *.log 和 *.tmp）"
        echo ""
        echo "重要：目录路径必须以 / 结尾，否则会被当作文件处理"
        exit 1
        ;;
esac
