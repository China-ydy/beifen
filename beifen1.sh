#!/bin/bash
# =====================================================
# 智能 Docker 数据抢救脚本（增强版）
# 功能：自动扫描容器 → 备份数据 → 提供下载/传输选项
# 作者：你的名字（可自定义）
# 使用方式：bash smart-docker-backup.sh
# =====================================================
# 颜色定义（美化输出）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
echo -e "${GREEN}🔍 正在启动智能 Docker 数据抢救脚本...${NC}"
# 创建备份目录
BACKUP_DIR="/tmp/docker-backup-$(date +%Y%m%d-%H%M)"
echo -e "${GREEN}📁 创建临时备份目录：${BACKUP_DIR}${NC}"
mkdir -p "$BACKUP_DIR"

# 新增：创建 configs 目录用于保存配置
CONFIG_DIR="$BACKUP_DIR/configs"
mkdir -p "$CONFIG_DIR"

# 获取所有容器 ID 和名称
echo -e "${GREEN}📊 正在扫描所有容器...${NC}"
CONTAINERS=$(docker ps -aq --no-trunc)
if [ -z "$CONTAINERS" ]; then
    echo -e "${RED}❌ 没有找到任何容器！${NC}"
    exit 1
fi

# 统计信息
TOTAL_CONTAINERS=0
BACKED_UP_CONTAINERS=0

# === 新增：收集 compose 服务信息 ===
COMPOSE_SERVICES=""
# =================================

for cid in $CONTAINERS; do
    ((TOTAL_CONTAINERS))
    NAME=$(docker inspect "$cid" | grep -oP '(?<="Name": ")[^"]*')
    IMAGE=$(docker inspect "$cid" | grep -oP '(?<="Image": ")[^"]*')
    echo -e "\n=== 📦 容器 $TOTAL_CONTAINERS: ID=$cid | Name=$NAME | Image=$IMAGE ==="
    
    # === 新增：保存容器 inspect 配置 ===
    docker inspect "$cid" > "$CONFIG_DIR/inspect-$NAME.json"
    echo -e "${GREEN}📄 已保存配置：inspect-$NAME.json${NC}"
    # ====================================

    # 判断类型并备份
    if [[ "$IMAGE" =~ wordpress|wp ]]; then
        echo -e "${YELLOW}💡 识别为 WordPress 容器${NC}"
        # 备份数据
        docker cp "$cid:/var/www/html" "$BACKUP_DIR/wp-$cid-html" 2>/dev/null && \
            echo -e "${GREEN}✅ 已备份 /var/www/html${NC}" || \
            echo -e "${YELLOW}⚠️ 未找到 /var/www/html${NC}"
        docker cp "$cid:/wp-content" "$BACKUP_DIR/wp-$cid-content" 2>/dev/null && \
            echo -e "${GREEN}✅ 已备份 /wp-content${NC}" || \
            echo -e "${YELLOW}⚠️ 未找到 /wp-content${NC}"
        
        # === 新增：提取 wp-config.php ===
        docker exec "$cid" cat /var/www/html/wp-config.php > "$CONFIG_DIR/wp-config.php" 2>/dev/null && \
            echo -e "${GREEN}📄 已提取 wp-config.php${NC}"
        # ================================

        ((BACKED_UP_CONTAINERS++))
    elif [[ "$IMAGE" =~ mysql|mariadb ]]; then
        echo -e "${YELLOW}💡 识别为 MySQL 容器${NC}"
        docker cp "$cid:/var/lib/mysql" "$BACKUP_DIR/mysql-$cid-data" 2>/dev/null && \
            echo -e "${GREEN}✅ 已备份 /var/lib/mysql${NC}" || \
            echo -e "${YELLOW}⚠️ 未找到 /var/lib/mysql${NC}"
        ((BACKED_UP_CONTAINERS++))
    else
        echo -e "${YELLOW}💡 识别为通用应用容器${NC}"
        # 尝试常见路径
        for path in /data /config /logs /app /src; do
            if docker exec "$cid" ls "$path" >/dev/null 2>&1; then
                docker cp "$cid:$path" "$BACKUP_DIR/app-$cid$path" 2>/dev/null && \
                    echo -e "${GREEN}✅ 已备份 $path${NC}"
            fi
        done
        ((BACKED_UP_CONTAINERS++))
    fi

    # === 新增：生成 compose 服务片段 ===
    INSPECT_FILE="$CONFIG_DIR/inspect-$NAME.json"
    ENV_LIST=$(jq -r '.[0].Config.Env | map("- " + .) | .[]' "$INSPECT_FILE" 2>/dev/null || echo "")
    PORTS=""
    PORT_MAP=$(jq -r '.[0].HostConfig.PortBindings | to_entries[] | .key as $k | .value[] | "\(.HostPort):$k"' "$INSPECT_FILE" 2>/dev/null || true)
    while IFS= read -r line; do
        [ -n "$line" ] && PORTS="$PORTS      - $line\n"
    done <<< "$PORT_MAP"

    VOLUMES=""
    MOUNTS=$(jq -r '.[0].Mounts[] | select(.Type=="bind") | "- \(.Source):\(.Destination):\(.Mode)"' "$INSPECT_FILE" 2>/dev/null || true)
    while IFS= read -r mount; do
        src=$(echo "$mount" | cut -d: -f1)
        dst=$(echo "$mount" | cut -d: -f2)
        VOLUMES="$VOLUMES      - $src:$dst\n"
    done <<< "$MOUNTS"

    COMPOSE_SERVICES="$COMPOSE_SERVICES
  $NAME:
    image: $IMAGE
$(echo -e "$ENV_LIST" | sed '/^$/d' | sed 's/^/    /' | sed 's/^ *$/    # (no env)/')
$(echo -e "$PORTS" | sed '/^$/d' | sed 's/^/    /' | sed 's/^ *$/    # (no ports)/')
$(echo -e "$VOLUMES" | sed '/^$/d' | sed 's/^/    /' | sed 's/^ *$/    # (no volumes)/')
    restart: \$\{RESTART:-unless-stopped\}
"
    # ====================================
done

# === 新增：生成 docker-compose.yml ===
cat > "$CONFIG_DIR/docker-compose.yml" << EOF
# 🐳 由智能备份脚本自动生成
# ⚠️ 使用前请检查路径和环境变量
version: '3.8'
services:$COMPOSE_SERVICES
EOF
echo -e "${GREEN}📄 已生成 docker-compose.yml 模板${NC}"
# =====================================

# 打包
ARCHIVE_NAME="docker-backup-auto-$(date +%Y%m%d-%H%M).tar.gz"
echo -e "\n${GREEN}📦 正在打包备份文件...${NC}"
cd /tmp || exit
tar czf "$ARCHIVE_NAME" -C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")"
echo -e "${GREEN}✅ 备份完成！${NC}"
echo -e "${GREEN}📁 压缩包路径：/tmp/$ARCHIVE_NAME${NC}"
echo -e "${GREEN}📊 共扫描 $TOTAL_CONTAINERS 个容器，成功备份 $BACKED_UP_CONTAINERS 个${NC}"

# 获取本机 IP
IP=$(hostname -I | awk '{print $1}')
echo -e "${GREEN}🌐 本机 IP：$IP${NC}"

# 交互式选择（完全保留你原来的交互逻辑）
echo -e "\n${YELLOW}📤 请选择数据传输方式：${NC}"
echo "1) 🔗 启动临时 HTTP 下载（浏览器访问 http://$IP:8000）"
echo "2) 🚀 输入新服务器 IP，使用 scp 自动上传"
echo "3) 🔄 两者都执行"
echo -n "请输入选项 (1/2/3): "
read -r choice
case $choice in
    1)
        echo -e "\n${GREEN}🚀 启动 HTTP 服务...${NC}"
        echo "👉 在浏览器打开：http://$IP:8000"
        echo "🛑 按 Ctrl+C 停止服务"
        cd /tmp && python3 -m http.server 8000
        ;;
    2)
        echo -n "请输入新服务器 IP: "
        read -r target_ip
        echo -n "请输入用户名（默认 root）: "
        read -r user
        user=${user:-root}
        echo -e "\n${GREEN}🚀 正在使用 scp 上传到 $user@$target_ip...${NC}"
        scp "/tmp/$ARCHIVE_NAME" "$user@$target_ip:/root/"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 上传成功！${NC}"
        else
            echo -e "${RED}❌ 上传失败，请检查网络或权限${NC}"
        fi
        ;;
    3)
        echo -e "\n${GREEN}🚀 启动 HTTP 服务（后台）...${NC}"
        cd /tmp && nohup python3 -m http.server 8000 > /tmp/http-server.log 2>&1 &
        echo "👉 在浏览器打开：http://$IP:8000"
        echo -n "请输入新服务器 IP: "
        read -r target_ip
        echo -n "请输入用户名（默认 root）: "
        read -r user
        user=${user:-root}
        echo -e "\n${GREEN}🚀 正在使用 scp 上传到 $user@$target_ip...${NC}"
        scp "/tmp/$ARCHIVE_NAME" "$user@$target_ip:/root/"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 上传成功！${NC}"
        else
            echo -e "${RED}❌ 上传失败${NC}"
        fi
        echo -e "${YELLOW}💡 HTTP 服务仍在后台运行，如需停止：pkill -f 'python3 -m http.server'${NC}"
        ;;
    *)
        echo -e "${RED}❌ 无效选项！${NC}"
        echo "压缩包已保存在：/tmp/$ARCHIVE_NAME"
        ;;
esac
echo -e "\n${GREEN}🎉 脚本执行完毕！你可以将此脚本上传至 GitHub 分享给他人。${NC}"


