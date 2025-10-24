# 快速开始指南

## 🚀 5分钟上手新版还原脚本

### 步骤1: 赋予执行权限

```bash
cd /Users/derek/Workspaces/postgres-container/restore

chmod +x *.sh
```

### 步骤2: 测试脚本

```bash
# 查看帮助
./quick-restore-v2.sh -h

# 列出可用备份
./quick-restore-v2.sh -l -n postgres
```

### 步骤3: 执行还原（推荐流程）

```bash
# 方式1: 标准还原（含确认和自动验证）
./quick-restore-v2.sh -d 20241218 -n postgres

# 方式2: 快速还原（跳过确认，保留验证）
./quick-restore-v2.sh -d 20241218 -n postgres -f

# 方式3: 极速还原（跳过所有，紧急时使用）
./quick-restore-v2.sh -d 20241218 -n postgres -f --no-verify
```

### 步骤4: 独立验证（可选）

```bash
# 如果跳过了自动验证，可以单独运行
./restore-verify.sh postgres postgres
```

---

## 📦 文件清单

### 新增文件（6个）

| 文件名 | 大小 | 用途 |
|--------|------|------|
| `quick-restore-v2.sh` | ~350行 | 主还原脚本（简化版） |
| `restore-verify.sh` | ~280行 | 自动验证模块 |
| `restore-incremental.sh` | ~130行 | 增量备份支持 |
| `s3-helper.sh` | ~170行 | S3操作辅助 |
| `restore-config-builder.sh` | ~60行 | 配置生成器 |
| `RESTORE-IMPROVEMENTS.md` | - | 改进说明文档 |
| `COMPARISON.md` | - | 对比分析文档 |
| `QUICK-START.md` | - | 本文件 |

### 原有文件（保留）

| 文件名 | 状态 | 说明 |
|--------|------|------|
| `quick-restore.sh` | ✅ 保留 | 原脚本，可继续使用 |
| `backup/backup.sh` | ✅ 未修改 | 备份脚本，完全兼容 |
| `backup/env.sh` | ✅ 未修改 | 环境配置 |
| `postgres-restore-job.yaml` | ✅ 兼容 | Job配置模板 |

---

## 🔄 迁移策略

### 方案A: 并行运行（推荐）

```bash
# 新旧脚本可以共存，互不影响

# 继续使用旧脚本
cd restore
./quick-restore.sh -d 20241218 -n postgres

# 同时测试新脚本
./quick-restore-v2.sh -d 20241218 -n postgres
```

### 方案B: 完全替换

```bash
# 如果测试通过，可以替换
mv quick-restore.sh quick-restore-v1-backup.sh
ln -s quick-restore-v2.sh quick-restore.sh

# 现在运行 quick-restore.sh 会使用新版本
```

---

## 📋 功能对比表

| 功能 | v1 (原脚本) | v2 (新脚本) | 命令 |
|------|-------------|-------------|------|
| **列出备份** | ✅ | ✅ | `-l` |
| **基础还原** | ✅ | ✅ | `-d DATE` |
| **强制还原** | ✅ | ✅ | `-f` |
| **远程S3** | ✅ 慢 | ✅ 快15x | `--remote-s3` |
| **自动验证** | ❌ | ✅ | 默认启用 |
| **跳过验证** | - | ✅ | `--no-verify` |
| **增量备份** | ❌ | ✅ | `--with-incremental` |
| **模块化** | ❌ | ✅ | - |

---

## 💡 典型使用场景

### 场景1: 日常还原测试

```bash
# 每周五测试还原流程
cd restore
./quick-restore-v2.sh -d $(date -d "yesterday" +%Y%m%d) -n postgres-test -f

# 自动执行：
# 1. 检查备份可用性
# 2. 执行还原
# 3. 自动验证7项指标
# 4. 生成验证报告
```

### 场景2: 生产环境紧急恢复

```bash
# 快速恢复，跳过确认但保留验证
./quick-restore-v2.sh -d 20241218 -n production -f

# 如果时间紧急，可跳过验证（不推荐）
./quick-restore-v2.sh -d 20241218 -n production -f --no-verify

# 稍后手动验证
./restore-verify.sh production postgres
```

### 场景3: 从AWS S3恢复

```bash
# 首次使用（会自动下载mc）
./quick-restore-v2.sh -d 20241218 \
  --remote-s3 \
  --s3-endpoint https://s3.amazonaws.com \
  --s3-access-key AKIAIOSFODNN7EXAMPLE \
  --s3-secret-key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
  --s3-bucket production-backups

# 后续使用（复用mc，速度快15倍）
./quick-restore-v2.sh -d 20241219 --remote-s3 ...
```

### 场景4: 查看和还原增量备份

```bash
# 1. 先查看备份链
./restore-incremental.sh info 20241218 postgres

# 输出：
# ✅ 全量: postgres-full-20241218-140000
# 增量链:
#   1. postgres-incremental-20241218-160000
#   2. postgres-incremental-20241218-180000
# ℹ️  总计: 1全量 + 2增量

# 2. 还原（未来版本将支持自动应用增量）
./quick-restore-v2.sh -d 20241218 --with-incremental
```

---

## 🛠️ 故障排查

### 问题1: 找不到备份

```bash
# 检查MinIO Pod
kubectl get pods -n postgres -l app.kubernetes.io/name=minio

# 手动检查备份
kubectl exec -n postgres <minio-pod> -- mc ls backups/postgres/files/

# 使用辅助脚本检查
./s3-helper.sh list backups postgres
```

### 问题2: 还原失败

```bash
# 查看Job状态
kubectl get jobs -n postgres

# 查看Pod日志
kubectl logs -n postgres -l app.kubernetes.io/name=postgres-restore

# 查看详细错误
kubectl describe job postgres-restore -n postgres
```

### 问题3: 验证失败

```bash
# 重新运行验证
./restore-verify.sh postgres postgres

# 手动检查PostgreSQL
kubectl exec -n postgres statefulset/postgres -- pg_isready
kubectl exec -n postgres statefulset/postgres -- psql -U postgres -c '\l'
```

### 问题4: S3连接失败

```bash
# 测试S3连接
./s3-helper.sh install
./s3-helper.sh configure https://s3.amazonaws.com ACCESS_KEY SECRET_KEY
./s3-helper.sh list backups postgres

# 检查凭证
echo $S3_ACCESS_KEY
echo $S3_ENDPOINT_URL
```

---

## 📞 获取帮助

```bash
# 查看各脚本帮助
./quick-restore-v2.sh -h
./restore-verify.sh
./restore-incremental.sh
./s3-helper.sh

# 阅读详细文档
cat RESTORE-IMPROVEMENTS.md
cat COMPARISON.md
```

---

## ✅ 推荐检查清单

在生产环境使用前：

- [ ] 已在测试环境验证所有脚本
- [ ] 已赋予执行权限
- [ ] 已测试列出备份功能
- [ ] 已测试还原功能
- [ ] 已测试验证功能
- [ ] 已配置远程S3（如需要）
- [ ] 已了解故障排查步骤
- [ ] 已制定回滚计划

---

**祝你使用愉快！** 🎉
