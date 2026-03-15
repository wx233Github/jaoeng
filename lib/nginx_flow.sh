#!/usr/bin/env bash

check_and_auto_renew_certs() {
  _generate_op_id
  if ! acquire_cert_lock; then return 1; fi
  if ! preflight_hard_gate "cron_renew"; then
    return "${ERR_CFG_VALIDATE:-20}"
  fi
  log_message INFO "正在执行 Cron 守护检测并批量续期..."
  local success=0 fail=0
  local reload_needed="false"
  _renew_fail_cleanup
  local IFS=$'\1'
  while IFS=$'\1' read -r domain cert_file method; do
    [[ -z "$domain" ]] && continue
    printf '%b' "检查: $domain ... "
    if [ "$method" == "reuse" ]; then
      printf '%b' "跳过(跟随主域)\n"
      continue
    fi
    local should_reload="false"
    if [ ! -f "$cert_file" ] || ! openssl x509 -checkend $((RENEW_THRESHOLD_DAYS * 86400)) -noout -in "$cert_file"; then
      printf '%b' "${BRIGHT_RED}触发续期...${NC}\n"
      local project_json
      project_json=$(_get_project_json "$domain")
      if [[ -n "$project_json" ]]; then
        if _issue_and_install_certificate "$project_json"; then
          success=$((success + 1))
          _renew_fail_reset "$domain"
          _send_tg_notify "success" "$domain" "证书已成功安装。" ""
          should_reload="true"
        else
          fail=$((fail + 1))
          local fcount
          fcount=$(_renew_fail_incr "$domain")
          if [ "$fcount" -ge "$RENEW_FAIL_THRESHOLD" ]; then
            _send_tg_notify "fail" "$domain" "自动续签失败(${fcount}次)。" ""
          else
            log_message WARN "续签失败次数未达阈值(${fcount}/${RENEW_FAIL_THRESHOLD})，暂不通知。"
          fi
        fi
      else
        log_message ERROR "无法读取 $domain 的配置元数据"
        fail=$((fail + 1))
      fi
    else printf '%b' "${GREEN}有效期充足${NC}\n"; fi
    if [ "$should_reload" = "true" ]; then reload_needed="true"; fi
  done < <(jq -r '.[] | "\(.domain)\1\(.cert_file)\1\(.acme_validation_method)' "$PROJECTS_METADATA_FILE" 2>/dev/null)
  unset IFS
  # shellcheck disable=SC2034
  NGINX_RELOAD_NEEDED="${reload_needed}"
  if ! control_nginx_reload_if_needed; then
    _tx_emit_marker "RECONCILE_DRIFT" "reload_failed during cron_renew" "ERROR"
    return 1
  fi

  log_message INFO "批量任务结束: $success 成功, $fail 失败。"
  if [ "$fail" -gt 0 ]; then
    _tx_emit_marker "RECONCILE_DRIFT" "renew_failures=${fail}" "ERROR"
    return 1
  fi
  _tx_emit_marker "RECONCILE_OK" "renew_success=${success}"
  return 0
}

configure_nginx_projects() {
  _generate_op_id
  local mode="${1:-standard}"
  local json
  _ensure_menu_interactive
  if [ "${JB_NONINTERACTIVE:-false}" = "true" ] || [ "$IS_INTERACTIVE_MODE" != "true" ]; then
    log_message ERROR "非交互模式无法配置新项目"
    return 1
  fi
  printf '%b' "\n${CYAN}开始配置新项目...${NC}\n"
  if ! json=$(_gather_project_details "{}" "false" "$mode"); then
    log_message WARN "用户取消配置。"
    return
  fi

  _issue_and_install_certificate "$json"
  local domain method
  IFS=$'\t' read -r domain method < <(jq -r '[.domain, (.acme_validation_method // "")] | @tsv' <<<"$json")
  local old_json=""
  old_json=$(_get_project_json "$domain")
  local cert="$SSL_CERTS_BASE_DIR/$domain.cer"
  if [ -f "$cert" ] || [ "$method" = "reuse" ]; then
    snapshot_project_json "$domain" "$json"
    if _apply_project_transaction "$domain" "$json" "$old_json" "$mode"; then
      log_message SUCCESS "配置已保存。"
      if [ -n "$LAST_CERT_ELAPSED" ]; then printf '%b' "\n申请耗时: ${LAST_CERT_ELAPSED}\n"; fi
      if [ -n "$LAST_CERT_CERT" ] && [ -n "$LAST_CERT_KEY" ]; then
        printf '%b' "证书路径: ${LAST_CERT_CERT}\n"
        printf '%b' "私钥路径: ${LAST_CERT_KEY}\n"
      fi
      if [ "$mode" != "cert_only" ]; then
        printf '%b' "\n网站已上线: https://${domain}\n"
      fi
    else
      log_message WARN "配置失败，已执行回滚。"
    fi
  else log_message ERROR "证书申请失败,未保存。"; fi
}

main_menu() {
  _generate_op_id
  _ensure_menu_interactive
  while true; do
    _draw_dashboard
    printf '%b' "${PURPLE}【HTTP(S) 业务】${NC}\n"
    printf '%b' " 1. 配置新域名反代 (支持泛域名免代理)\n"
    printf '%b' " 2. HTTP 项目管理\n"
    printf '%b' " 3. 仅申请证书 (S-UI/V2Ray 专用)\n"
    printf '%b' "\n"
    printf '%b' "${PURPLE}【TCP 负载均衡】${NC}\n"
    printf '%b' " 4. 配置 TCP 反代/负载均衡\n"
    printf '%b' " 5. 管理 TCP 反向代理\n"
    printf '%b' "\n"
    printf '%b' "${PURPLE}【运维监控与系统维护】${NC}\n"
    printf '%b' " 6. 批量续期\n"
    printf '%b' " 7. 查看日志 (Logs - Nginx/acme)\n"
    printf '%b' " 8. ${BRIGHT_RED}${BOLD}Cloudflare 防御中心 (状态/更新/切换)${NC}\n"
    printf '%b' " 9. 备份/还原与配置重建\n"
    printf '%b' "10. 设置 Telegram 机器人通知\n"
    printf '%b' "11. 配置模板中心 (Block追加/Site替换)\n"
    printf '%b' "\n"
    local c
    if ! c=$(prompt_menu_choice "1-11" "true"); then
      exit 10
    fi
    case "$c" in
    1)
      configure_nginx_projects
      press_enter_to_continue
      ;;
    2) manage_configs ;;
    3)
      configure_nginx_projects "cert_only"
      press_enter_to_continue
      ;;
    4)
      configure_tcp_proxy
      press_enter_to_continue
      ;;
    5) manage_tcp_configs ;;
    6) if confirm_or_cancel "确认检查所有项目?"; then
      check_and_auto_renew_certs
      press_enter_to_continue
    fi ;;
    7)
      _render_menu "查看日志" "1. Nginx 全局访问/错误日志" "2. acme.sh 证书运行日志"
      local log_c
      if log_c=$(prompt_menu_choice "1-2" "true"); then
        if [ "$log_c" = "1" ]; then
          _view_nginx_global_log
        else
          _view_acme_log
        fi
        press_enter_to_continue
      fi
      ;;
    8) _manage_cloudflare_defense ;;
    9) _handle_backup_restore ;;
    10)
      setup_tg_notifier
      press_enter_to_continue
      ;;
    11) _manage_nginx_template_center ;;
    "") exit 10 ;;
    *) log_message ERROR "无效选择" ;;
    esac
  done
}

_ensure_menu_interactive() {
  if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
    return 0
  fi
  if [ "${IS_INTERACTIVE_MODE}" = "true" ]; then
    return 0
  fi
  if [ -t 0 ] || _tty_available; then
    IS_INTERACTIVE_MODE="true"
    log_message WARN "检测到交互终端，已恢复交互模式"
  fi
}
