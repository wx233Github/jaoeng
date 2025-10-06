#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装与管理脚本 (v75.0-重构主菜单排版)
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v75.0"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}

# --- 脚本核心逻辑 ---
main(){
    # 确保只以 root 或 sudo 权限运行
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误：此脚本需要以 root 或 sudo 权限运行。" >&2
        exit 1
    fi
    
    # 获取脚本所在目录的绝对路径
    local script_dir; script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    
    # 加载配置文件和通用工具函数
    local config_file="${script_dir}/config.json"
    local utils_file="${script_dir}/utils.sh"
    
    if [ ! -f "$config_file" ]; then echo "错误: 配置文件 config.json 未找到！" >&2; exit 1; fi
    if [ ! -f "$utils_file" ]; then echo "错误: 工具库 utils.sh 未找到！" >&2; exit 1; fi
    source "$utils_file"

    # --- 全局变量定义 ---
    # 从 config.json 读取配置
    BASE_URL=$(jq -r '.base_url' "$config_file")
    INSTALL_DIR=$(jq -r '.install_dir' "$config_file")
    BIN_DIR=$(jq -r '.bin_dir' "$config_file")
    LOCK_FILE=$(jq -r '.lock_file' "$config_file")
    export JB_ENABLE_AUTO_CLEAR=$(jq -r '.enable_auto_clear' "$config_file")
    export JB_TIMEZONE=$(jq -r '.timezone' "$config_file")

    # --- 锁文件机制，防止多实例运行 ---
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then log_err "脚本已在运行。"; exit 1; fi
    trap 'flock -u 200; rm -f "$LOCK_FILE"' EXIT

    # --- 核心函数定义 ---
    
    # 快捷命令创建
    create_shortcut(){
        local shortcut_path="${BIN_DIR}/vps"
        if [ -f "$shortcut_path" ]; then
            log_info "快捷命令 'vps' 已存在。"
        else
            ln -s "${script_dir}/install.sh" "$shortcut_path"
            log_success "已创建快捷命令 'vps'。"
        fi
    }

    # 依赖检查与安装
    check_and_install_dependencies(){
        local deps; deps=$(jq -r '.dependencies.common' "$config_file")
        log_info "检查依赖: ${deps}..."
        local missing_deps=""
        for dep in $deps; do
            if ! command -v "$dep" &>/dev/null; then
                missing_deps="${missing_deps} ${dep}"
            fi
        done

        if [ -n "$missing_deps" ]; then
            log_warn "缺失依赖: ${missing_deps}"
            if command -v apt-get &>/dev/null; then
                run_with_sudo apt-get update
                run_with_sudo apt-get install -y $missing_deps
            elif command -v yum &>/dev/null; then
                run_with_sudo yum install -y $missing_deps
            else
                log_err "不支持的包管理器。请手动安装: ${missing_deps}"
                exit 1
            fi
        else
            log_success "所有依赖均已安装。"
        fi
    }

    # 运行模块脚本
    run_module(){
        local module_script="$1"
        local module_name="$2"
        local module_path="${INSTALL_DIR}/${module_script}"

        log_info "您选择了 [${module_name}]"
        
        # 导出从 config.json 中读取的模块特定配置
        local module_key; module_key=$(basename "$module_script" .sh | tr '[:upper:]' '[:lower:]')
        if jq -e ".module_configs.$module_key" "$config_file" >/dev/null; then
            local keys; keys=$(jq -r ".module_configs.$module_key | keys[]" "$config_file")
            for key in $keys; do
                if [[ "$key" == "comment_"* ]]; then continue; fi
                local value; value=$(jq -r ".module_configs.$module_key.$key" "$config_file")
                local var_name="WATCHTOWER_CONF_$(echo "$key" | tr '[:lower:]' '[:upper:]')"
                export "$var_name"="$value"
                log_debug "Exporting from config.json: $var_name=$value"
            done
        fi
        
        set +e
        bash "$module_path"
        local exit_code=$?
        set -e

        if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 10 ]; then
            log_warn "模块 [${module_name}] 执行出错 (码: ${exit_code})."
            press_enter_to_continue
        fi
    }
    
    # 强制更新
    force_update() {
        log_info "正在从 ${BASE_URL} 强制更新所有脚本..."
        local files_to_update=("install.sh" "utils.sh" "config.json")
        
        # 动态获取所有模块脚本
        local main_menu_items; main_menu_items=$(jq -r '.menus.MAIN_MENU.items[].action' "$config_file" | grep -v 'confirm_and_force_update\|uninstall_script\|TOOLS_MENU')
        local tools_menu_items; tools_menu_items=$(jq -r '.menus.TOOLS_MENU.items[].action' "$config_file")

        for item in $main_menu_items $tools_menu_items; do
            files_to_update+=("$item")
        done
        
        mkdir -p "$INSTALL_DIR/tools"
        
        for file in "${files_to_update[@]}"; do
            local dest_path
            if [[ "$file" == "install.sh" || "$file" == "utils.sh" || "$file" == "config.json" ]]; then
                dest_path="${script_dir}/${file}"
            else
                dest_path="${INSTALL_DIR}/${file}"
            fi

            log_info "  -> 下载 ${file}..."
            if ! curl -fsSL "${BASE_URL}/${file}" -o "${dest_path}.tmp"; then
                log_err "下载 ${file} 失败。"
                rm -f "${dest_path}.tmp"
                continue
            fi

            if [ -f "$dest_path" ] && cmp -s "${dest_path}.tmp" "$dest_path"; then
                log_info "     ${file} 无变化。"
                rm -f "${dest_path}.tmp"
            else
                mv "${dest_path}.tmp" "$dest_path"
                chmod +x "$dest_path" 2>/dev/null || true
                log_success "     ${file} 已更新。"
            fi
        done
        log_success "强制更新完成。"
    }

    confirm_and_force_update() {
        if confirm_action "确定要强制更新所有脚本文件吗？"; then
            force_update
            log_info "脚本已更新，请重新运行以使更改生效。"
            exit 0
        else
            log_info "操作已取消。"
        fi
    }

    uninstall_script() {
        if confirm_action "警告：这将移除脚本、模块和快捷命令，确定吗？"; then
            log_info "正在卸载..."
            rm -f "${BIN_DIR}/vps"
            rm -rf "$INSTALL_DIR"
            rm -f "${script_dir}/install.sh" "${script_dir}/utils.sh" "${script_dir}/config.json"
            log_success "卸载完成。"
            exit 0
        else
            log_info "操作已取消。"
        fi
    }
    
    # --- 状态检查函数 ---
    _get_docker_status() {
        local docker_ok=false
        local compose_ok=false
        local status_str=""

        if systemctl is-active --quiet docker; then docker_ok=true; fi
        
        # 检查 docker-compose (v1) 或 docker compose (v2)
        if command -v docker-compose &>/dev/null || docker compose version &>/dev/null 2>&1; then
            compose_ok=true
        fi

        if $docker_ok && $compose_ok; then
            echo -e "${GREEN}已运行${NC}"
        else
            if ! $docker_ok; then status_str+="Docker${RED}未运行${NC} "; fi
            if ! $compose_ok; then status_str+="Compose${RED}未运行${NC}"; fi
            echo -e "$status_str"
        fi
    }

    _get_nginx_status() {
        if systemctl is-active --quiet nginx; then
            echo -e "${GREEN}已运行${NC}"
        else
            echo -e "${RED}未运行${NC}"
        fi
    }

    _get_watchtower_status() {
        # 仅当 docker 服务运行时才检查
        if systemctl is-active --quiet docker; then
            if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
                echo -e "${GREEN}已运行${NC}"
            else
                echo -e "${YELLOW}未运行${NC}"
            fi
        else
            echo -e "${RED}Docker未运行${NC}"
        fi
    }

    # --- 主菜单渲染 ---
    main_menu() {
        while true; do
            if [ "$JB_ENABLE_AUTO_CLEAR" = "true" ]; then clear; fi
            
            # 准备菜单项
            local docker_status=$(_get_docker_status)
            local nginx_status=$(_get_nginx_status)
            local watchtower_status=$(_get_watchtower_status)
            
            # 使用 printf 格式化对齐
            local -a items_array=(
                "$(printf "%-22s │ %s" "1. 🐳 Docker" "docker: $docker_status")"
                "$(printf "%-22s │ %s" "2. 🌐 Nginx" "Nginx: $nginx_status")"
                "$(printf "%-22s │ %s" "3. 🛠️ 常用工具" "Watchtower: $watchtower_status")"
                "$(printf "%-22s │ %s" "4. 📜 证书申请" "a.⚙️ 强制重置")"
                "$(printf "%-22s │ %s" "" "c.🗑️ 卸载脚本")"
            )

            _render_menu "🖥️ VPS 一键安装脚本" "${items_array[@]}"
            read -r -p " └──> 请选择 [1-4], 或 [a,c] 操作: " choice < /dev/tty

            case "$choice" in
                1) run_module "docker.sh" "Docker" ;;
                2) run_module "nginx.sh" "Nginx" ;;
                3) tools_menu ;;
                4) run_module "cert.sh" "证书申请" ;;
                a|A) confirm_and_force_update; press_enter_to_continue ;;
                c|C) uninstall_script ;;
                "") exit 0 ;;
                *) log_warn "无效选项。"; sleep 1 ;;
            esac
        done
    }

    # 工具子菜单
    tools_menu() {
        while true; do
            if [ "$JB_ENABLE_AUTO_CLEAR" = "true" ]; then clear; fi
            local -a items_array=("  1. › Watchtower (Docker 更新)")
            _render_menu "🛠️ 常用工具" "${items_array[@]}"
            read -r -p " └──> 请选择 [1-1], 或 [Enter] 返回: " choice < /dev/tty
            case "$choice" in
                1) run_module "tools/Watchtower.sh" "Watchtower (Docker 更新)" ;;
                "") return ;;
                *) log_warn "无效选项。"; sleep 1 ;;
            esac
        done
    }
    
    # --- 脚本执行入口 ---
    # 检查是否首次运行
    if [ ! -d "$INSTALL_DIR" ]; then
        log_info "首次运行，正在进行初始化..."
        mkdir -p "$INSTALL_DIR"
        force_update
        check_and_install_dependencies
        create_shortcut
        log_success "初始化完成！"
        press_enter_to_continue
    fi
    
    # 检查 sudo 权限
    source "${INSTALL_DIR}/sudo_check.sh"
    check_sudo_privileges
    
    # 显示主菜单
    main_menu
}

# --- 脚本启动 ---
main "$@"
