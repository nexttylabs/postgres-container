#!/bin/bash
set -Eeo pipefail

# =============================================================================
# PostgreSQL 还原验证脚本
# 在还原完成后自动验证数据库可用性和数据完整性
# =============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 验证PostgreSQL可用性
verify_postgres_ready() {
    local namespace=$1
    local statefulset=$2
    local max_wait=${3:-300}
    
    log_info "验证PostgreSQL服务可用性..."
    
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if kubectl exec -n "$namespace" statefulset/"$statefulset" -- \
            pg_isready -U postgres >/dev/null 2>&1; then
            log_success "PostgreSQL服务已就绪"
            return 0
        fi
        
        echo -n "."
        sleep 5
        waited=$((waited + 5))
    done
    
    echo ""
    log_error "PostgreSQL服务在 ${max_wait}s 内未就绪"
    return 1
}

# 验证数据库列表
verify_databases() {
    local namespace=$1
    local statefulset=$2
    
    log_info "验证数据库列表..."
    
    local db_output=$(kubectl exec -n "$namespace" statefulset/"$statefulset" -- \
        psql -U postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        echo "数据库列表:"
        echo "$db_output" | while read -r db; do
            db=$(echo "$db" | xargs)
            [ -n "$db" ] && echo "  ✓ $db"
        done
        
        local db_count=$(echo "$db_output" | grep -v '^$' | wc -l | tr -d ' ')
        log_success "找到 ${db_count} 个数据库"
        return 0
    else
        log_error "无法查询数据库列表"
        return 1
    fi
}

# 验证PostgreSQL版本
verify_version() {
    local namespace=$1
    local statefulset=$2
    
    log_info "验证PostgreSQL版本..."
    
    local version=$(kubectl exec -n "$namespace" statefulset/"$statefulset" -- \
        psql -U postgres -t -c "SELECT version()" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        echo "PostgreSQL版本: $(echo "$version" | xargs)"
        return 0
    else
        log_error "无法获取PostgreSQL版本"
        return 1
    fi
}

# 验证数据目录权限
verify_permissions() {
    local namespace=$1
    local statefulset=$2
    local data_dir=${3:-/data}
    
    log_info "验证数据目录权限..."
    
    local perms=$(kubectl exec -n "$namespace" statefulset/"$statefulset" -- \
        stat -c "%a %U:%G" "$data_dir" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        echo "数据目录权限: $perms"
        
        # 检查权限是否为700
        local perm_code=$(echo "$perms" | awk '{print $1}')
        if [ "$perm_code" = "700" ]; then
            log_success "数据目录权限正确"
            return 0
        else
            log_warning "数据目录权限不是700，当前为: $perm_code"
            return 1
        fi
    else
        log_error "无法验证数据目录权限"
        return 1
    fi
}

# 验证复制状态（如果配置了复制）
verify_replication() {
    local namespace=$1
    local statefulset=$2
    
    log_info "检查复制状态..."
    
    local repl_status=$(kubectl exec -n "$namespace" statefulset/"$statefulset" -- \
        psql -U postgres -t -c "SELECT count(*) FROM pg_stat_replication" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        repl_status=$(echo "$repl_status" | xargs)
        if [ "$repl_status" = "0" ]; then
            log_info "未配置复制或没有活动的从库"
        else
            log_success "发现 ${repl_status} 个活动的复制连接"
            
            # 显示复制详情
            kubectl exec -n "$namespace" statefulset/"$statefulset" -- \
                psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication" 2>/dev/null
        fi
        return 0
    else
        log_warning "无法查询复制状态"
        return 1
    fi
}

# 验证WAL归档状态
verify_wal_archiving() {
    local namespace=$1
    local statefulset=$2
    
    log_info "检查WAL归档状态..."
    
    local archive_status=$(kubectl exec -n "$namespace" statefulset/"$statefulset" -- \
        psql -U postgres -t -c "SELECT archived_count, last_archived_wal, last_archived_time FROM pg_stat_archiver" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        echo "WAL归档状态:"
        echo "$archive_status"
        return 0
    else
        log_warning "无法查询WAL归档状态"
        return 1
    fi
}

# 执行基础SQL测试
verify_basic_queries() {
    local namespace=$1
    local statefulset=$2
    
    log_info "执行基础SQL查询测试..."
    
    # 测试1: 创建临时表
    if kubectl exec -n "$namespace" statefulset/"$statefulset" -- \
        psql -U postgres -c "CREATE TEMP TABLE test_restore (id int); DROP TABLE test_restore;" >/dev/null 2>&1; then
        log_success "✓ 创建/删除表测试通过"
    else
        log_error "✗ 创建/删除表测试失败"
        return 1
    fi
    
    # 测试2: 基础查询
    if kubectl exec -n "$namespace" statefulset/"$statefulset" -- \
        psql -U postgres -c "SELECT 1" >/dev/null 2>&1; then
        log_success "✓ 基础查询测试通过"
    else
        log_error "✗ 基础查询测试失败"
        return 1
    fi
    
    return 0
}

# 生成验证报告
generate_report() {
    local namespace=$1
    local statefulset=$2
    local results_file=${3:-/tmp/restore-verify-results.txt}
    
    {
        echo "========================================"
        echo "PostgreSQL还原验证报告"
        echo "========================================"
        echo "时间: $(date)"
        echo "命名空间: $namespace"
        echo "StatefulSet: $statefulset"
        echo "========================================"
        echo ""
    } > "$results_file"
    
    echo "验证报告已保存到: $results_file"
}

# 完整验证流程
run_full_verification() {
    local namespace=$1
    local statefulset=$2
    local data_dir=${3:-/data}
    
    echo ""
    echo "========================================"
    echo "PostgreSQL还原验证"
    echo "========================================"
    echo "命名空间: $namespace"
    echo "StatefulSet: $statefulset"
    echo "========================================"
    echo ""
    
    local failed=0
    
    # 1. 服务可用性
    verify_postgres_ready "$namespace" "$statefulset" || failed=$((failed + 1))
    echo ""
    
    # 2. 版本信息
    verify_version "$namespace" "$statefulset" || failed=$((failed + 1))
    echo ""
    
    # 3. 数据库列表
    verify_databases "$namespace" "$statefulset" || failed=$((failed + 1))
    echo ""
    
    # 4. 目录权限
    verify_permissions "$namespace" "$statefulset" "$data_dir" || failed=$((failed + 1))
    echo ""
    
    # 5. 复制状态
    verify_replication "$namespace" "$statefulset"
    echo ""
    
    # 6. WAL归档
    verify_wal_archiving "$namespace" "$statefulset"
    echo ""
    
    # 7. 基础查询
    verify_basic_queries "$namespace" "$statefulset" || failed=$((failed + 1))
    echo ""
    
    # 总结
    echo "========================================"
    if [ $failed -eq 0 ]; then
        log_success "所有验证项通过！"
        echo "========================================"
        return 0
    else
        log_error "有 ${failed} 项验证失败"
        echo "========================================"
        return 1
    fi
}

# 显示帮助
show_help() {
    cat << EOF
PostgreSQL还原验证脚本

用法:
    $0 <namespace> <statefulset> [data_dir]

参数:
    namespace    Kubernetes命名空间
    statefulset  PostgreSQL StatefulSet名称
    data_dir     PostgreSQL数据目录 (默认: /data)

示例:
    $0 postgres postgres
    $0 production postgres-prod /var/lib/postgresql/data

验证项:
    1. PostgreSQL服务可用性
    2. PostgreSQL版本信息
    3. 数据库列表
    4. 数据目录权限
    5. 复制状态（如果配置）
    6. WAL归档状态
    7. 基础SQL查询

EOF
}

# 主函数
main() {
    if [ $# -lt 2 ]; then
        show_help
        exit 1
    fi
    
    local namespace=$1
    local statefulset=$2
    local data_dir=${3:-/data}
    
    run_full_verification "$namespace" "$statefulset" "$data_dir"
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
