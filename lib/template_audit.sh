#!/usr/bin/env bash

tm_json_escape() {
  printf '%s' "${1:-}" | jq -Rsa .
}

tm_rotate_template_audit_log_if_needed() {
  local log_path="${1:-}"
  local max_size=$((1024 * 1024))
  local keep=5
  local idx=0
  [ -z "$log_path" ] && return 0
  [ ! -f "$log_path" ] && return 0
  local size
  size=$(wc -c <"$log_path" 2>/dev/null || printf '%s' "0")
  if [ "$size" -lt "$max_size" ]; then
    return 0
  fi
  for ((idx = keep; idx >= 1; idx--)); do
    if [ -f "${log_path}.${idx}" ]; then
      if [ "$idx" -eq "$keep" ]; then
        rm -f -- "${log_path}.${idx}" 2>/dev/null || true
      else
        mv "${log_path}.${idx}" "${log_path}.$((idx + 1))" 2>/dev/null || true
      fi
    fi
  done
  mv "$log_path" "${log_path}.1" 2>/dev/null || true
  touch "$log_path" 2>/dev/null || true
}

tm_append_template_audit_log() {
  local action="${1:-unknown}"
  local domain="${2:-unknown}"
  local detail="${3:-}"
  local rc="${4:-0}"
  local elapsed_ms="${5:-0}"
  local actor="${SUDO_USER:-${USER:-unknown}}"
  local log_path
  log_path=$(_sanitize_log_file "$NGINX_TEMPLATE_AUDIT_LOG" 2>/dev/null || true)
  [ -z "$log_path" ] && log_path="/tmp/nginx_template_audit.log"
  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
  tm_rotate_template_audit_log_if_needed "$log_path"
  printf '%s\t%s\t%s\top=%s\tactor=%s\trc=%s\telapsed_ms=%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$action" "$domain" "${OP_ID:-NA}" "$actor" "$rc" "$elapsed_ms" "$detail" >>"$log_path" 2>/dev/null || true
}

tm_template_audit_report() {
  local log_path=""
  local combined=""
  local files=""
  local total=0
  local apply_ok=0
  local apply_fail=0
  local cleanup_ok=0
  local cleanup_fail=0
  local rollback_ok=0
  local rollback_fail=0
  local recent_ops=""
  local top_failed_domains=""
  local avg_elapsed_ms=0
  local f=""

  log_path=$(_sanitize_log_file "$NGINX_TEMPLATE_AUDIT_LOG" 2>/dev/null || true)
  [ -z "$log_path" ] && log_path="/tmp/nginx_template_audit.log"

  if [ -f "$log_path" ]; then
    files="$log_path"
  fi
  local i=1
  for ((i = 1; i <= 5; i++)); do
    if [ -f "${log_path}.${i}" ]; then
      files+=" ${log_path}.${i}"
    fi
  done
  if [ -z "$files" ]; then
    log_message ERROR "模板审计日志不存在: ${log_path}"
    if [ "${TEMPLATE_OUTPUT_JSON:-false}" = "true" ]; then
      printf '{"error":"audit_log_not_found","path":%s}\n' "$(tm_json_escape "$log_path")"
    fi
    return "$EX_DATAERR"
  fi

  for f in $files; do
    combined+="$(cat "$f" 2>/dev/null || true)"
    combined+=$'\n'
  done
  if [ -z "$combined" ]; then
    if [ "${TEMPLATE_OUTPUT_JSON:-false}" = "true" ]; then
      printf '{"total":0,"apply_ok":0,"apply_fail":0,"cleanup_ok":0,"cleanup_fail":0,"rollback_ok":0,"rollback_fail":0}\n'
    else
      log_message INFO "模板审计日志为空。"
    fi
    return 0
  fi

  total=$(awk 'END{print NR+0}' <<<"$combined")
  apply_ok=$(grep -Ec $'\tapply\t' <<<"$combined" || printf '%s' "0")
  apply_fail=$(grep -Ec $'\tapply-failed\t' <<<"$combined" || printf '%s' "0")
  cleanup_ok=$(grep -Ec $'\tcleanup\t' <<<"$combined" || printf '%s' "0")
  cleanup_fail=$(grep -Ec $'\tcleanup-failed\t' <<<"$combined" || printf '%s' "0")
  rollback_ok=$(grep -Ec $'\trollback\t' <<<"$combined" || printf '%s' "0")
  rollback_fail=$(grep -Ec $'\trollback-failed\t' <<<"$combined" || printf '%s' "0")
  recent_ops=$(awk -F '\top=' '{if (NF>1){split($2,a,"\t"); print a[1]}}' <<<"$combined" | sed '/^$/d' | sort | uniq | tail -n 10 | tr '\n' ' ')
  top_failed_domains=$(awk -F '\t' '($2 ~ /-failed$/){cnt[$3]++} END{for (d in cnt) printf "%s:%d\n", d, cnt[d]}' <<<"$combined" | sort -t: -k2,2nr | head -n 5 | tr '\n' ' ')
  avg_elapsed_ms=$(awk -F 'elapsed_ms=' 'NF>1{split($2,a,"\t"); if (a[1] ~ /^[0-9]+$/){sum+=a[1]; n++}} END{if(n>0) printf "%d", sum/n; else printf "0"}' <<<"$combined")

  if [ "${TEMPLATE_OUTPUT_JSON:-false}" = "true" ]; then
    printf '{"total":%s,"apply_ok":%s,"apply_fail":%s,"cleanup_ok":%s,"cleanup_fail":%s,"rollback_ok":%s,"rollback_fail":%s,"avg_elapsed_ms":%s,"recent_ops":%s,"top_failed_domains":%s}\n' \
      "$total" "$apply_ok" "$apply_fail" "$cleanup_ok" "$cleanup_fail" "$rollback_ok" "$rollback_fail" "$avg_elapsed_ms" "$(tm_json_escape "${recent_ops%% }")" "$(tm_json_escape "${top_failed_domains%% }")"
  else
    log_message INFO "模板审计统计: total=${total}, apply_ok=${apply_ok}, apply_fail=${apply_fail}, cleanup_ok=${cleanup_ok}, cleanup_fail=${cleanup_fail}, rollback_ok=${rollback_ok}, rollback_fail=${rollback_fail}, avg_elapsed_ms=${avg_elapsed_ms}"
  fi
  return 0
}
