#!/bin/bash
set -e

# S3 调试脚本 - 用于检查远程 S3 存储结构

echo "=== S3 调试工具 ==="
echo ""

# 参数
NAMESPACE="${1:-batsystem}"
S3_ENDPOINT="${2:-https://fc39d1c3d0f1ce69690d5728da74c555.r2.cloudflarestorage.com}"
S3_ACCESS_KEY="${3:-71a5e05cff7e6680f9613443c22f3cd7}"
S3_SECRET_KEY="${4:-113fa3c2a794ed689db9e8f2750b100841f44edc326fd9c22b80695bff003ccb}"
S3_BUCKET="${5:-backup}"
BACKUP_PREFIX="${6:-batsystem}"

echo "配置信息:"
echo "  命名空间: $NAMESPACE"
echo "  S3端点: $S3_ENDPOINT"
echo "  存储桶: $S3_BUCKET"
echo "  备份前缀: $BACKUP_PREFIX"
echo ""

# 创建调试 Pod
TEMP_POD="s3-debug-$(date +%s)"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${TEMP_POD}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: debug
    image: alpine:latest
    command: ['/bin/sh', '-c']
    args:
    - |
      echo "安装工具..."
      apk add --no-cache wget grep sed gawk coreutils bash ca-certificates > /dev/null 2>&1
      
      # 检测架构
      ARCH=$(uname -m)
      case $ARCH in
        x86_64) MC_ARCH="amd64" ;;
        aarch64|arm64) MC_ARCH="arm64" ;;
        *) echo "ERROR: Unsupported architecture: $ARCH"; exit 1 ;;
      esac
      
      echo "检测到架构: $ARCH"
      echo "下载 mc 客户端 (linux-${MC_ARCH})..."
      wget -q https://dl.min.io/client/mc/release/linux-${MC_ARCH}/mc -O /usr/local/bin/mc
      chmod +x /usr/local/bin/mc
      
      if [ ! -x /usr/local/bin/mc ]; then
        echo "ERROR: mc download failed"
        exit 1
      fi
      
      /usr/local/bin/mc --version
      echo "工具安装完成"
      sleep 600
    env:
    - name: S3_ENDPOINT
      value: "${S3_ENDPOINT}"
    - name: S3_ACCESS_KEY
      value: "${S3_ACCESS_KEY}"
    - name: S3_SECRET_KEY
      value: "${S3_SECRET_KEY}"
    - name: S3_BUCKET
      value: "${S3_BUCKET}"
    - name: BACKUP_PREFIX
      value: "${BACKUP_PREFIX}"
EOF

echo "等待 Pod 就绪..."
kubectl wait --for=condition=ready pod/${TEMP_POD} -n ${NAMESPACE} --timeout=120s

echo ""
echo "=== 开始调试 ==="
echo ""

# 配置 mc
echo "1. 配置 mc 连接..."
kubectl exec -n ${NAMESPACE} ${TEMP_POD} -- sh -c '
    mc alias set remote "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" --api S3v4
'

# 列出存储桶
echo ""
echo "2. 列出所有存储桶..."
kubectl exec -n ${NAMESPACE} ${TEMP_POD} -- mc ls remote/

# 列出存储桶内容
echo ""
echo "3. 列出存储桶根目录 (remote/${S3_BUCKET}/)..."
kubectl exec -n ${NAMESPACE} ${TEMP_POD} -- mc ls remote/${S3_BUCKET}/

# 尝试不同的路径
echo ""
echo "4. 尝试不同的备份路径..."

echo ""
echo "4a. 检查 remote/${S3_BUCKET}/${BACKUP_PREFIX}/ (正确的路径格式)"
kubectl exec -n ${NAMESPACE} ${TEMP_POD} -- mc ls remote/${S3_BUCKET}/${BACKUP_PREFIX}/ || echo "  路径不存在"

echo ""
echo "4b. 搜索日期格式的目录..."
kubectl exec -n ${NAMESPACE} ${TEMP_POD} -- sh -c "mc ls remote/${S3_BUCKET}/${BACKUP_PREFIX}/ | grep -E \"[0-9]{8}\"" || echo "  未找到日期目录"

echo ""
echo "4c. 递归列出所有文件..."
kubectl exec -n ${NAMESPACE} ${TEMP_POD} -- mc ls --recursive remote/${S3_BUCKET}/ | head -50

echo ""
echo "5. 搜索包含日期格式的目录 (YYYYMMDD)..."
kubectl exec -n ${NAMESPACE} ${TEMP_POD} -- sh -c '
    mc ls --recursive remote/$S3_BUCKET/ | grep -E "[0-9]{8}" | head -20
' || echo "  未找到"

echo ""
echo "=== 调试完成 ==="
echo ""
echo "建议操作:"
echo "1. 检查上述输出，找到备份文件的实际路径"
echo "2. 根据实际路径调整 --backup-prefix 参数"
echo "3. 如果路径结构不同，可能需要修改脚本"
echo ""
echo "保持 Pod 运行，你可以手动进入调试:"
echo "  kubectl exec -it -n ${NAMESPACE} ${TEMP_POD} -- sh"
echo ""
echo "完成后清理:"
echo "  kubectl delete pod ${TEMP_POD} -n ${NAMESPACE}"
