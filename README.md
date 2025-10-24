# PostgreSQL Container with Backup & Restore

Run PostgreSQL in Kubernetes with automated backup and restore capabilities.

## 📁 项目结构

```
postgres-container/
├── backup/                    # 备份脚本目录
│   ├── backup.sh             # PostgreSQL备份脚本（全量+增量）
│   └── env.sh                # 环境配置
│
├── restore/                   # 还原脚本目录 ⭐
│   ├── README.md             # 还原脚本详细说明
│   ├── quick-restore.sh      # 原版还原脚本 (v1.0)
│   ├── quick-restore-v2.sh   # 简化版还原脚本 (v2.0)
│   ├── quick-restore-k8s.sh  # Kubernetes原生脚本 (v2.1) ⭐⭐推荐
│   ├── restore-verify.sh     # 自动验证模块
│   ├── restore-incremental.sh # 增量备份支持
│   ├── s3-helper.sh          # S3操作辅助
│   ├── restore-config-builder.sh # 配置生成器
│   ├── postgres-restore-job.yaml # Kubernetes Job配置
│   ├── restore-rbac.yaml     # RBAC权限配置
│   ├── QUICK-START.md        # 快速开始指南
│   ├── K8S-NATIVE.md         # Kubernetes原生版本说明 ⭐⭐
│   ├── RESTORE-IMPROVEMENTS.md # 改进说明
│   ├── COMPARISON.md         # 新旧版本对比
│   ├── CHANGELOG.md          # 版本变更日志
│   └── CHEATSHEET.md         # 命令速查表
│
├── docker-compose.yaml        # Docker Compose配置
└── README.md                  # 本文件
```

## 🚀 快速开始

### 备份

```bash
# 配置环境变量
export POSTGRES_USER="postgres"
export POSTGRES_PASSWORD="your_password"
export POSTGRES_HOST="postgres"
export POSTGRES_PORT="5432"
export BACKUP_DIR="/backup"
export FULL_BACKUP_INTERVAL="7"  # 全量备份间隔天数
export STORAGE_TYPE="s3"
export S3_BUCKET="backups"
export S3_ENDPOINT="http://minio:9000"
export S3_ACCESS_KEY="minioadmin"
export S3_SECRET_KEY="minioadmin"

# 执行备份
./backup/backup.sh
```

### 还原

```bash
# 进入还原目录
cd restore

# 赋予执行权限
chmod +x *.sh

# 配置 RBAC 权限（仅 K8s 原生版本需要）
kubectl apply -f restore-rbac.yaml

# 列出可用备份（Kubernetes 原生 - 推荐）⭐⭐
./quick-restore-k8s.sh -l -n postgres

# 执行还原（所有操作在集群中完成，零本地依赖）
./quick-restore-k8s.sh -d 20241218 -n postgres

# 详细使用说明
cat QUICK-START.md    # 快速上手
cat K8S-NATIVE.md     # K8s原生版本说明
```

## 📚 功能特性

### 备份功能
- ✅ 支持全量备份（pg_basebackup）
- ✅ 支持增量备份
- ✅ 备份验证（pg_verifybackup）
- ✅ 自动压缩（zstd）
- ✅ 上传到S3/MinIO
- ✅ 定期全量备份策略

### 还原功能

#### v2.1-k8s (Kubernetes 原生) ⭐⭐推荐
- ✅ **零本地依赖**（仅需kubectl）
- ✅ **零本地存储**（不占用本地磁盘）
- ✅ **零本地流量**（全集群内网传输）
- ✅ 一键还原
- ✅ 自动验证（7项检查）
- ✅ 远程S3支持
- ✅ 更快的速度（集群内网10Gbps+）
- ✅ 更好的安全性（自动清理）

#### v2.0 (模块化简化版)
- ✅ 一键还原
- ✅ 自动验证（7项检查）
- ✅ 增量备份支持
- ✅ 远程S3支持
- ✅ 模块化设计
- ✅ 详细的错误提示

## 📖 文档

### 备份相关
- `backup/backup.sh` - 查看脚本内注释

### 还原相关
- **[restore/K8S-NATIVE.md](restore/K8S-NATIVE.md)** - Kubernetes原生版本说明 ⭐⭐强烈推荐
- **[restore/QUICK-START.md](restore/QUICK-START.md)** - 5分钟快速上手 ⭐推荐
- **[restore/README.md](restore/README.md)** - 完整使用说明
- **[restore/CHEATSHEET.md](restore/CHEATSHEET.md)** - 命令速查表
- **[restore/RESTORE-IMPROVEMENTS.md](restore/RESTORE-IMPROVEMENTS.md)** - 详细改进说明
- **[restore/COMPARISON.md](restore/COMPARISON.md)** - 新旧版本对比
- **[restore/CHANGELOG.md](restore/CHANGELOG.md)** - 版本变更日志

## 🔧 环境要求

- Kubernetes 1.20+
- PostgreSQL 17+ (推荐 17+)
- kubectl
- MinIO 或兼容S3的存储（可选）

## 💡 典型使用场景

### 场景1: 每日自动备份

```bash
# 创建CronJob
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
spec:
  schedule: "0 2 * * *"  # 每天凌晨2点
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: postgres:17
            command: ["/backup/backup.sh"]
            volumeMounts:
            - name: backup-script
              mountPath: /backup
```

### 场景2: 测试环境定期还原

```bash
# 每周五下午还原到测试环境
cd restore
./quick-restore-v2.sh -d $(date -d "yesterday" +%Y%m%d) -n postgres-test -f
```

### 场景3: 生产环境紧急恢复

```bash
# 快速恢复最新备份
cd restore
./quick-restore-v2.sh -d 20241218 -n production -f

# 验证结果
./restore-verify.sh production postgres
```

## 🛠️ 故障排查

### 备份失败

```bash
# 检查PostgreSQL连接
pg_isready -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER

# 检查磁盘空间
df -h

# 查看备份日志
tail -f /backup/logs/backup-*.log
```

### 还原失败

```bash
# 查看Job状态
kubectl get jobs -n postgres

# 查看Pod日志
kubectl logs -n postgres -l app.kubernetes.io/name=postgres-restore

# 使用验证脚本
cd restore
./restore-verify.sh postgres postgres
```

## 📞 获取帮助

```bash
# 备份脚本帮助
./backup/backup.sh --help

# 还原脚本帮助
./restore/quick-restore-v2.sh -h

# 查看文档
cat restore/QUICK-START.md
```

## 🤝 贡献

欢迎提交Issue和Pull Request！

## 📄 License

MIT License
