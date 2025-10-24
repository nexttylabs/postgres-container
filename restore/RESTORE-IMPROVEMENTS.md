# PostgreSQL 还原脚本改进说明

## 📋 改进概述

针对 Kubernetes 环境的 PostgreSQL 还原脚本进行了模块化重构和功能增强。

### 主要改进

| 改进点 | 原脚本 | 新方案 |
|--------|--------|--------|
| **脚本长度** | 831行单文件 | 模块化拆分 |
| **增量备份** | ❌ 不支持 | ✅ 完整支持 |
| **还原验证** | ❌ 仅显示命令 | ✅ 自动验证 |
| **配置生成** | 21个sed替换 | 使用envsubst |
| **S3操作** | 每次下载mc | 复用安装 |
| **代码维护** | 难以维护 | 易于扩展 |

---

## 📁 新增文件说明

### 1. **quick-restore-v2.sh** (主脚本 - 简化版)
- **大小**: ~350行 (减少58%)
- **功能**: 主还原流程协调
- **特点**: 模块化设计，调用辅助脚本

```bash
# 基础用法
./quick-restore-v2.sh -l                    # 列出备份
./quick-restore-v2.sh -d 20241218          # 还原指定日期
./quick-restore-v2.sh -d 20241218 -f       # 强制还原
```

### 2. **restore-verify.sh** (验证模块)
- **功能**: 还原后自动验证
- **验证项**:
  - ✅ PostgreSQL服务可用性
  - ✅ 数据库版本信息
  - ✅ 数据库列表完整性
  - ✅ 数据目录权限
  - ✅ 复制状态
  - ✅ WAL归档状态
  - ✅ 基础SQL查询测试

```bash
# 独立使用
./restore-verify.sh postgres postgres

# 自动集成到还原流程
./quick-restore-v2.sh -d 20241218  # 默认执行验证
./quick-restore-v2.sh -d 20241218 --no-verify  # 跳过验证
```

### 3. **restore-incremental.sh** (增量备份支持)
- **功能**: 处理增量备份链
- **能力**: 
  - 列出完整备份链（全量+增量）
  - 显示备份依赖关系
  - 提供还原建议

```bash
# 查看备份链信息
./restore-incremental.sh info 20241218 postgres

# 输出示例:
# ✓ 找到全量备份: postgres-full-20241218-140000
# 
# 增量备份链:
# ============
# 1. postgres-incremental-20241218-160000
# 2. postgres-incremental-20241218-180000
# 
# ℹ 总计: 1个全量备份 + 2个增量备份
```

### 4. **s3-helper.sh** (S3操作辅助)
- **功能**: 简化远程S3操作
- **优势**:
  - 自动检测已安装的mc
  - 支持多架构 (amd64/arm64)
  - 复用mc安装，避免重复下载

```bash
# 安装mc客户端
./s3-helper.sh install

# 配置S3连接
./s3-helper.sh configure https://s3.amazonaws.com AKIAIO... wJalrXU...

# 列出备份
./s3-helper.sh list backups postgres

# 检查备份存在性
./s3-helper.sh check backups postgres 20241218
```

### 5. **restore-config-builder.sh** (配置生成器)
- **功能**: 简化Job配置生成
- **方法**: 使用envsubst替代多个sed命令

```bash
# 使用方法（通常由主脚本自动调用）
source restore-config-builder.sh
export BACKUP_DATE="20241218"
export NAMESPACE="postgres"
build_restore_job_config template.yaml output.yaml
```

---

## 🚀 使用指南

### 快速开始

1. **赋予执行权限**
```bash
chmod +x quick-restore-v2.sh restore-*.sh s3-helper.sh
```

2. **列出可用备份**
```bash
./quick-restore-v2.sh -l -n postgres
```

3. **执行还原（带自动验证）**
```bash
./quick-restore-v2.sh -d 20241218 -n postgres
```

### 高级用法

#### 场景1: 还原包含增量备份的数据
```bash
# 1. 先查看备份链
./restore-incremental.sh info 20241218 postgres

# 2. 执行还原（包含增量）
./quick-restore-v2.sh -d 20241218 --with-incremental
```

#### 场景2: 从远程S3还原
```bash
./quick-restore-v2.sh \
  -d 20241218 \
  --remote-s3 \
  --s3-endpoint https://s3.amazonaws.com \
  --s3-access-key AKIAIOSFODNN7EXAMPLE \
  --s3-secret-key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
  --s3-bucket my-backups
```

#### 场景3: 仅验证现有数据库
```bash
./restore-verify.sh postgres postgres /data
```

#### 场景4: 强制还原且跳过验证（快速模式）
```bash
./quick-restore-v2.sh -d 20241218 -f --no-verify
```

---

## 🔄 迁移指南

### 从旧脚本迁移

**旧脚本 (quick-restore.sh)**:
```bash
./quick-restore.sh -d 20241218 -n postgres -f
```

**新脚本 (quick-restore-v2.sh)** - 完全兼容:
```bash
./quick-restore-v2.sh -d 20241218 -n postgres -f
```

### 参数对照表

| 旧参数 | 新参数 | 说明 |
|--------|--------|------|
| `-d DATE` | `-d DATE` | ✅ 完全相同 |
| `-f` | `-f` | ✅ 完全相同 |
| `-n NS` | `-n NS` | ✅ 完全相同 |
| `-l` | `-l` | ✅ 完全相同 |
| - | `--with-incremental` | ⭐ 新增 |
| - | `--no-verify` | ⭐ 新增 |

---

## 📊 性能对比

### 代码复杂度

```
原脚本 (quick-restore.sh):
- 总行数: 831行
- 函数数: 14个
- sed命令: 21个连续替换
- 维护难度: ⭐⭐⭐⭐

新方案 (模块化):
- 主脚本: ~350行
- 模块脚本: 4个独立文件
- 代码复用: 高
- 维护难度: ⭐⭐
```

### 功能覆盖

| 功能 | 原脚本 | 新方案 |
|------|--------|--------|
| 基础还原 | ✅ | ✅ |
| 远程S3 | ✅ | ✅ 优化 |
| 增量备份 | ❌ | ✅ |
| 自动验证 | ❌ | ✅ |
| 错误诊断 | ⚠️ 基础 | ✅ 详细 |
| 备份链管理 | ❌ | ✅ |

---

## 🛠️ 技术细节

### 增量备份还原逻辑

根据备份脚本的结构：
```
backups/postgres/files/
├── 20241218/                    # 日期目录
│   ├── postgres-full-20241218-140000.tar.zst    # 全量备份
│   └── incremental/              # 增量备份目录
│       ├── postgres-incremental-20241218-160000.tar.zst
│       └── postgres-incremental-20241218-180000.tar.zst
```

还原步骤：
1. 解压全量备份到临时目录
2. 按时间顺序应用所有增量备份
3. 使用pg_combinebackup合并（PostgreSQL 17+）或手动应用
4. 复制到数据目录
5. 启动PostgreSQL

### 验证流程

```mermaid
graph TD
    A[开始验证] --> B[检查服务可用性]
    B --> C[验证PostgreSQL版本]
    C --> D[检查数据库列表]
    D --> E[验证目录权限]
    E --> F[检查复制状态]
    F --> G[验证WAL归档]
    G --> H[执行SQL测试]
    H --> I{所有检查通过?}
    I -->|是| J[还原成功]
    I -->|否| K[报告失败项]
```

---

## ⚠️ 注意事项

### 增量备份限制

1. **PostgreSQL版本要求**
   - 增量备份: PostgreSQL 13+
   - pg_combinebackup: PostgreSQL 17+
   - 低于17版本需手动合并增量备份

2. **备份链完整性**
   - 必须有完整的备份链（全量+所有增量）
   - 缺少任何增量备份将导致还原失败
   - 建议使用`restore-incremental.sh info`预先检查

3. **存储空间**
   - 还原时需要额外空间存放解压的备份
   - 建议预留 2x 备份大小的空间

### 兼容性

- ✅ 与现有备份脚本完全兼容
- ✅ 可以与旧还原脚本共存
- ✅ 支持现有的Job配置文件
- ⚠️ 增量备份功能需要PostgreSQL 13+

---

## 📝 TODO / 未来改进

- [ ] 支持并行还原（多个数据库）
- [ ] 备份元数据缓存
- [ ] 还原进度百分比显示
- [ ] Webhook通知（成功/失败）
- [ ] 还原历史记录
- [ ] 回滚到指定时间点（PITR）
- [ ] 图形化进度界面

---

## 🤝 贡献

欢迎提交改进建议和bug报告。

### 开发指南

1. 每个模块脚本应独立可测试
2. 保持向后兼容
3. 添加详细的错误处理
4. 更新此文档

---

## 📞 支持

遇到问题？

1. 检查 `restore-verify.sh` 的验证报告
2. 查看 Job Pod 日志: `kubectl logs -n postgres <pod-name>`
3. 使用 `restore-incremental.sh info` 检查备份链
4. 验证S3连接: `./s3-helper.sh list backups postgres`

---

**版本**: 2.0.0  
**最后更新**: 2024-12-18
