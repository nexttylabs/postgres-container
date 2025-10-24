# PostgreSQL 还原脚本目录

此目录包含 Kubernetes 环境下 PostgreSQL 数据库还原相关的所有脚本和文档。

## 📁 目录结构

```
restore/
├── README.md                      # 本文件
├── quick-restore.sh               # 原始还原脚本 (v1.0)
├── quick-restore-v2.sh            # 简化版还原脚本 (v2.0)
├── quick-restore-k8s.sh           # Kubernetes原生脚本 (v2.1) ⭐⭐推荐
├── restore-verify.sh              # 还原验证模块
├── restore-incremental.sh         # 增量备份支持模块
├── s3-helper.sh                   # S3操作辅助脚本
├── restore-config-builder.sh      # Job配置生成器
├── postgres-restore-job.yaml      # Kubernetes Job配置
├── restore-rbac.yaml              # RBAC权限配置
├── QUICK-START.md                 # 快速开始指南 ⭐新手必读
├── K8S-NATIVE.md                  # Kubernetes原生版本说明 ⭐⭐
├── RESTORE-IMPROVEMENTS.md        # 详细改进说明
├── COMPARISON.md                  # 新旧版本对比分析
├── CHANGELOG.md                   # 版本变更日志
└── CHEATSHEET.md                  # 命令速查表
```

## 🚀 快速开始

### 1. 赋予执行权限

```bash
chmod +x restore/*.sh
```

### 2. 配置 RBAC 权限（仅 K8s 原生版本需要）

```bash
# 应用 RBAC 配置
kubectl apply -f restore/restore-rbac.yaml
```

### 3. 列出可用备份

```bash
# 使用 Kubernetes 原生版本（推荐 - 零本地依赖）⭐⭐
./restore/quick-restore-k8s.sh -l -n postgres

# 使用简化版本
./restore/quick-restore-v2.sh -l -n postgres

# 或使用原版本脚本
./restore/quick-restore.sh -l -n postgres
```

### 4. 执行还原

```bash
# Kubernetes 原生模式（推荐 - 所有操作在集群中）⭐⭐
./restore/quick-restore-k8s.sh -d 20241218 -n postgres

# 简化版模式
./restore/quick-restore-v2.sh -d 20241218 -n postgres

# 强制还原（跳过确认）
./restore/quick-restore-k8s.sh -d 20241218 -n postgres -f
```

### 4. 验证还原结果

```bash
# 自动验证（v2版本默认启用）
./restore/quick-restore-v2.sh -d 20241218 -n postgres

# 独立运行验证
./restore/restore-verify.sh postgres postgres
```

## 📚 脚本说明

### 主还原脚本

#### quick-restore-k8s.sh ⭐⭐强烈推荐
- **版本**: 2.1.0-k8s
- **特点**: Kubernetes 原生，零本地依赖
- **核心优势**:
  - ✅ 仅需 kubectl（无需其他工具）
  - ✅ 不占用本地磁盘空间
  - ✅ 不消耗本地网络带宽
  - ✅ 所有操作在集群中完成
  - ✅ 更快的传输速度（集群内网）
  - ✅ 更好的安全性（自动清理）
- **适用场景**: 生产环境、CI/CD、多人协作
- **文档**: 详见 [K8S-NATIVE.md](K8S-NATIVE.md)

#### quick-restore-v2.sh ⭐推荐
- **版本**: 2.0.0
- **特点**: 模块化、简化、功能增强
- **新增功能**:
  - ✅ 自动验证还原结果
  - ✅ 增量备份支持
  - ✅ S3操作优化（快15倍）
  - ✅ 更好的错误处理
- **代码行数**: ~350行（比v1减少58%）
- **适用场景**: 需要本地调试、离线操作

#### quick-restore.sh
- **版本**: 1.0.0
- **特点**: 原始版本，功能稳定
- **状态**: 保留用于向后兼容

### 辅助模块

#### restore-verify.sh
- **功能**: 还原后自动验证
- **验证项**:
  1. PostgreSQL服务可用性
  2. 数据库版本信息
  3. 数据库列表完整性
  4. 数据目录权限
  5. 复制状态检查
  6. WAL归档状态
  7. 基础SQL查询测试

#### restore-incremental.sh
- **功能**: 增量备份管理
- **能力**:
  - 列出完整备份链
  - 显示增量备份信息
  - 提供还原建议

#### s3-helper.sh
- **功能**: 简化S3操作
- **优势**:
  - 自动检测已安装的mc客户端
  - 复用安装，避免重复下载
  - 支持多架构（amd64/arm64）

#### restore-config-builder.sh
- **功能**: 简化Job配置生成
- **方法**: 使用envsubst替代多个sed命令

## 📖 文档说明

### QUICK-START.md ⭐新手必读
- 5分钟快速上手指南
- 常见使用场景示例
- 故障排查步骤

### RESTORE-IMPROVEMENTS.md
- 详细的改进说明
- 技术实现细节
- 使用指南和最佳实践

### COMPARISON.md
- 新旧版本详细对比
- 代码改进分析
- 性能提升数据

## 🔄 版本选择建议

| 场景 | 推荐版本 | 原因 |
|------|----------|------|
| **生产环境** | v2.1-k8s ⭐⭐ | 零本地依赖，更安全快速 |
| **CI/CD 自动化** | v2.1-k8s ⭐⭐ | 无环境差异，易于集成 |
| **多人协作** | v2.1-k8s ⭐⭐ | 无需本地工具安装 |
| **本地磁盘受限** | v2.1-k8s ⭐⭐ | 不占用本地空间 |
| **需要本地调试** | v2.0 ⭐ | 更多控制选项 |
| **离线环境** | v2.0 ⭐ | kubectl可能不可用 |
| **兼容性需求** | v1.0 | 保持与现有流程一致 |

### 本地依赖对比

| 依赖项 | v1.0 | v2.0 | v2.1-k8s |
|--------|------|------|----------|
| kubectl | ✅ | ✅ | ✅ |
| mc 客户端 | ✅ | ✅ | ❌ |
| zstd | ✅ | ✅ | ❌ |
| curl | ✅ | ✅ | ❌ |
| 本地磁盘 | ✅ 需要 | ✅ 需要 | ❌ 不需要 |

## 💡 常用命令示例

### 日常操作

```bash
# 列出最近7天的备份
./restore/quick-restore-v2.sh -l

# 还原昨天的备份
./restore/quick-restore-v2.sh -d $(date -d "yesterday" +%Y%m%d)

# 验证当前数据库状态
./restore/restore-verify.sh postgres postgres
```

### 远程S3操作

```bash
# 从AWS S3列出备份
./restore/quick-restore-v2.sh -l \
  --remote-s3 \
  --s3-endpoint https://s3.amazonaws.com \
  --s3-access-key AKIAIO... \
  --s3-secret-key wJalrXU...

# 从阿里云OSS还原
./restore/quick-restore-v2.sh -d 20241218 \
  --remote-s3 \
  --s3-endpoint https://oss-cn-hangzhou.aliyuncs.com \
  --s3-access-key LTAI5t... \
  --s3-secret-key xxxxxxxx \
  --s3-bucket aliyun-backups
```

### 增量备份操作

```bash
# 查看备份链信息
./restore/restore-incremental.sh info 20241218 postgres

# 还原包含增量备份
./restore/quick-restore-v2.sh -d 20241218 --with-incremental
```

## 🛠️ 故障排查

### 常见问题

**Q: 脚本提示权限不足**
```bash
chmod +x restore/*.sh
```

**Q: 找不到备份文件**
```bash
# 检查MinIO状态
kubectl get pods -n postgres -l app.kubernetes.io/name=minio

# 手动列出备份
kubectl exec -n postgres <minio-pod> -- mc ls backups/postgres/files/
```

**Q: 还原失败**
```bash
# 查看Job日志
kubectl logs -n postgres -l app.kubernetes.io/name=postgres-restore

# 查看详细状态
kubectl describe job postgres-restore -n postgres
```

**Q: 验证失败**
```bash
# 重新运行验证
./restore/restore-verify.sh postgres postgres

# 手动检查
kubectl exec -n postgres statefulset/postgres -- pg_isready
kubectl exec -n postgres statefulset/postgres -- psql -U postgres -c '\l'
```

## 📞 获取帮助

```bash
# 查看脚本帮助
./restore/quick-restore-v2.sh -h
./restore/restore-verify.sh -h
./restore/restore-incremental.sh
./restore/s3-helper.sh

# 阅读详细文档
cat restore/QUICK-START.md
cat restore/RESTORE-IMPROVEMENTS.md
cat restore/COMPARISON.md
```

## 🔗 相关目录

- `../backup/` - 备份脚本目录
  - `backup.sh` - PostgreSQL备份脚本
  - `env.sh` - 环境配置

## 📝 注意事项

1. **还原前务必确认**：还原操作会覆盖现有数据
2. **建议先测试**：在测试环境验证脚本功能
3. **保留备份**：还原前建议备份当前数据
4. **检查权限**：确保脚本有执行权限
5. **验证结果**：还原后务必验证数据完整性

## 🎯 最佳实践

1. **使用v2版本**进行新的还原操作
2. **启用自动验证**确保数据完整性
3. **定期测试**还原流程
4. **记录操作**保存还原日志
5. **监控过程**及时发现问题

---

**版本**: 2.0.0  
**最后更新**: 2024-12-18  
**维护者**: DevOps Team
