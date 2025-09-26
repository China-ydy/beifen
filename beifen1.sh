#!/bin/bash
# ========================================
# 🛡️ 全自动 Docker 全容器备份脚本
# 功能：备份所有正在运行的容器及其数据、配置、生成 compose 文件
# 输出：/tmp/docker-backup-all-日期.tar.gz
# 特点：无需配置、自动发现、支持任意容器
# ========================================

# 📁 基础变量
BACKUP_ROOT="/tmp"
DATE=$(date +%Y%m%d-%H%M)
BACKUP_DIR="$BACKUP_ROOT/docker-backup-all-$DATE"
COMPOSE_FILE="$BACKUP_DIR/docker-compose.yml"

# 🧹 清理旧数据
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# 📦 创建 data 目录用于存放各容器数据
DATA_DIR="$BACKUP_DIR/data"
mkdir -p "$DATA_DIR"

echo "🔍 正在扫描所有正在运行的容器..."

# 获取所有运行中的容器 ID 和名称
CONTAINERS=$(docker ps --format '{{.ID}} {{.Names}}')

if [ -z "$CONTAINERS" ]; then
    echo "❌ 错误：没有发现任何正在运行的容器"
    exit 1
fi

echo "✅ 发现 $(echo "$CONTAINERS" | wc -l) 个容器"

# 📄 初始化 docker-compose.yml
cat > "$COMPOSE_FILE" << EOF
# 🐳 由 backup-all.sh 自动生成
# ⚠️ 注意：部分复杂配置（如网络、自定义驱动）需手动调整
version: '3.8'
services:
EOF

# 🔁 遍历每个容器
echo "$CONTAINERS" | while read CONTAINER_ID CONTAINER_NAME; do
    echo "📦 处理容器: $CONTAINER_NAME ($CONTAINER_ID)"

    # 获取容器详细信息
    INSPECT="$BACKUP_DIR/inspect-$CONTAINER_NAME.json"
    docker inspect "$CONTAINER_ID" > "$INSPECT"

    # 提取关键信息
    IMAGE=$(jq -r '.[0].Config.Image' "$INSPECT")
    RESTART=$(jq -r '.[0].HostConfig.RestartPolicy.Name' "$INSPECT")
    NETWORK_MODE=$(jq -r '.[0].HostConfig.NetworkMode' "$INSPECT")

    # 提取环境变量（转为 YAML 格式）
    ENV_LIST=$(jq -r '.[0].Config.Env | map("- " + .) | .[]' "$INSPECT" 2>/dev/null || echo "")

    # 提取端口映射（-p）
    PORTS=""
    PORT_MAP=$(jq -r '.[0].HostConfig.PortBindings | to_entries[] | 
        .key as $k | .value[] | "\(.HostIp):\(.HostPort) -> \($k)"' "$INSPECT" 2>/dev/null || true)
    if [ -n "$PORT_MAP" ]; then
        while IFS=' ' read -r HOST_PORT CONTAINER_PORT; do
            PORTS="$PORTS      - $HOST_PORT:$CONTAINER_PORT\n"
        done <<< "$(echo "$PORT_MAP" | sed 's/ -> / /')"
    fi

    # 提取挂载卷（只备份 bind 类型，即宿主机路径）
    VOLUMES=""
    DATA_DIRS=()
    jq -r '.[0].Mounts[] | select(.Type == "bind") | .Source + ":" + .Destination + ":" + .Mode' "$INSPECT" 2>/dev/null | while read MOUNT; do
        SOURCE=$(echo "$MOUNT" | cut -d: -f1)
        DEST=$(echo "$MOUNT" | cut -d: -f2)
        MODE=$(echo "$MOUNT" | cut -d: -f3)

        if [ -d "$SOURCE" ]; then
            # 为每个挂载创建子目录
            VOL_NAME=$(basename "$SOURCE")
            CONTAINER_DATA_DIR="$DATA_DIR/${CONTAINER_NAME}_${VOL_NAME}"
            mkdir -p "$CONTAINER_DATA_DIR"
            tar czf "$CONTAINER_DATA_DIR/data.tar.gz" -C "$(dirname "$SOURCE")" "$(basename "$SOURCE")"
            VOLUMES="$VOLUMES      - ./data/${CONTAINER_NAME}_${VOL_NAME}/data.tar.gz:/restore.tar.gz\n"
            VOLUMES="$VOLUMES      - /opt/docker-volumes/${CONTAINER_NAME}/${VOL_NAME}:/backup-restore\n"
            DATA_DIRS+=("$SOURCE -> /opt/docker-volumes/${CONTAINER_NAME}/${VOL_NAME}")
        fi
    done

    # 生成 compose 片段
    cat >> "$COMPOSE_FILE" << EOF

  $CONTAINER_NAME:
    image: $IMAGE
EOF

    [ -n "$ENV_LIST" ] && cat >> "$COMPOSE_FILE" << EOF
    environment:
$ENV_LIST
EOF

    [ -n "$PORTS" ] && cat >> "$COMPOSE_FILE" << EOF
    ports:
$(echo -e "$PORTS" | sed '/^$/d')
EOF

    [ -n "$VOLUMES" ] && cat >> "$COMPOSE_FILE" << EOF
    volumes:
$(echo -e "$VOLUMES" | sed '/^$/d')
EOF

    cat >> "$COMPOSE_FILE" << EOF
    restart: $RESTART
    # network_mode: $NETWORK_MODE  # 如需自定义网络请取消注释并调整
EOF

    # 保存 inspect 文件
    mv "$INSPECT" "$BACKUP_DIR/inspect-$CONTAINER_NAME.json"

    echo "✅ 已备份容器: $CONTAINER_NAME"
done

# 📄 生成恢复说明
cat > "$BACKUP_DIR/README.md" << 'EOF'
# 🛠️ 备份恢复说明

## 1. 解压
```bash
tar xzf docker-backup-all-*.tar.gz
cd docker-backup-all-*