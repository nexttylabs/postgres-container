# PostgreSQL 还原脚本速查表

## 🚀 常用命令

### 基础操作

```bash
# 进入还原目录
cd restore

# 赋予执行权限（首次使用）
chmod +x *.sh

# 列出可用备份
./quick-restore-v2.sh -l

# 还原指定日期（推荐）
./quick-restore-v2.sh -d 20241218

# 强制还原（跳过确认）
./quick-restore-v2.sh -d 20241218 -f

# 跳过验证（不推荐）
./quick-restore-v2.sh -d 20241218 -f --no-verify
```

### 高级功能

```bash
# 查看增量备份链
./restore-incremental.sh info 20241218 postgres

# 还原包含增量备份
./quick-restore-v2.sh -d 20241218 --with-incremental

# 独立验证数据库
./restore-verify.sh postgres postgres

# 指定命名空间
./quick-restore-v2.sh -d 20241218 -n production
```

### 远程S3操作

```bash
# AWS S3
./quick-restore-v2.sh -l \
  --remote-s3 \
  --s3-endpoint https://s3.amazonaws.com \
  --s3-access-key AKIAIO... \
  --s3-secret-key wJalrXU...

# 阿里云OSS
./quick-restore-v2.sh -l \
  --remote-s3 \
  --s3-endpoint https://oss-cn-hangzhou.aliyuncs.com \
  --s3-access-key LTAI5t... \
  --s3-secret-key xxxxxxxx
```

## 📋 参数速查

### quick-restore-v2.sh

| 参数 | 简写 | 说明 | 示例 |
|------|------|------|------|
| `--date` | `-d` | 备份日期（YYYYMMDD） | `-d 20241218` |
| `--force` | `-f` | 跳过确认提示 | `-f` |
| `--namespace` | `-n` | K8s命名空间 | `-n postgres` |
| `--list` | `-l` | 列出可用备份 | `-l` |
| `--help` | `-h` | 显示帮助 | `-h` |
| `--no-verify` | - | 跳过自动验证 | `--no-verify` |
| `--with-incremental` | - | 包含增量备份 | `--with-incremental` |
| `--remote-s3` | - | 启用远程S3 | `--remote-s3` |
| `--s3-endpoint` | - | S3端点URL | `--s3-endpoint https://...` |
| `--s3-access-key` | - | S3访问密钥 | `--s3-access-key AKIAIO...` |
| `--s3-secret-key` | - | S3私密密钥 | `--s3-secret-key wJalrXU...` |

### restore-verify.sh

```bash
# 用法
./restore-verify.sh <namespace> <statefulset> [data_dir]

# 示例
./restore-verify.sh postgres postgres
./restore-verify.sh production postgres-prod /var/lib/postgresql/data
```

### restore-incremental.sh

```bash
# 查看备份链信息
./restore-incremental.sh info <DATE> <NAMESPACE>

# 列出增量备份
./restore-incremental.sh list <DATE> <NAMESPACE>

# 示例
./restore-incremental.sh info 20241218 postgres
```

## 🔍 故障排查

### 问题：找不到备份

```bash
# 检查MinIO
kubectl get pods -n postgres -l app.kubernetes.io/name=minio

# 手动列出
kubectl exec -n postgres <minio-pod> -- mc ls backups/postgres/files/
```

### 问题：还原失败

```bash
# 查看Job日志
kubectl logs -n postgres -l app.kubernetes.io/name=postgres-restore

# 查看Job状态
kubectl describe job postgres-restore -n postgres
```

### 问题：验证失败

```bash
# 重新验证
./restore-verify.sh postgres postgres

# 手动检查
kubectl exec -n postgres statefulset/postgres -- pg_isready
kubectl exec -n postgres statefulset/postgres -- psql -U postgres -c '\l'
```

### 问题：权限错误

```bash
# 检查脚本权限
ls -l *.sh

# 重新授权
chmod +x *.sh
```

## 📊 验证项说明

### restore-verify.sh 执行的7项检查

1. ✅ **PostgreSQL服务可用性** - `pg_isready`
2. ✅ **版本信息** - `SELECT version()`
3. ✅ **数据库列表** - `SELECT datname FROM pg_database`
4. ✅ **数据目录权限** - `stat -c "%a %U:%G"`
5. ✅ **复制状态** - `SELECT * FROM pg_stat_replication`
6. ✅ **WAL归档** - `SELECT * FROM pg_stat_archiver`
7. ✅ **基础SQL测试** - `CREATE/DROP TEMP TABLE`

## 🎯 最佳实践

### 日常操作

```bash
# 每周测试还原
./quick-restore-v2.sh -d $(date -d "yesterday" +%Y%m%d) -n test -f

# 生产还原（带确认）
./quick-restore-v2.sh -d 20241218 -n production

# 紧急恢复（快速）
./quick-restore-v2.sh -d 20241218 -n production -f
```

### 定期验证

```bash
# 验证当前数据库
./restore-verify.sh postgres postgres

# 验证测试环境
./restore-verify.sh postgres-test postgres
```

### S3操作

```bash
# 配置一次，多次使用
export S3_ENDPOINT="https://s3.amazonaws.com"
export S3_ACCESS_KEY="AKIAIO..."
export S3_SECRET_KEY="wJalrXU..."

./quick-restore-v2.sh -l --remote-s3 \
  --s3-endpoint "$S3_ENDPOINT" \
  --s3-access-key "$S3_ACCESS_KEY" \
  --s3-secret-key "$S3_SECRET_KEY"
```

## 📞 快速链接

| 文档 | 内容 |
|------|------|
| [QUICK-START.md](QUICK-START.md) | 5分钟快速上手 |
| [README.md](README.md) | 完整使用说明 |
| [RESTORE-IMPROVEMENTS.md](RESTORE-IMPROVEMENTS.md) | 详细改进文档 |
| [COMPARISON.md](COMPARISON.md) | 新旧版本对比 |
| [CHANGELOG.md](CHANGELOG.md) | 版本变更日志 |

## 💾 备份

打印此页面或保存为PDF，方便紧急时查阅！

---

**提示**: 使用 `./quick-restore-v2.sh -h` 查看完整帮助信息
