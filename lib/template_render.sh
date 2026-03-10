#!/usr/bin/env bash

_render_snippet_with_template_vars() {
  local template_id="${1:-}"
  local snippet="${2:-}"
  local rendered="${2:-}"
  local key=""
  local def=""
  local pattern=""
  local val=""
  while IFS=$'\t' read -r key def pattern; do
    [ -z "$key" ] && continue
    if [ -n "${TEMPLATE_VARS[$key]+x}" ]; then
      val="${TEMPLATE_VARS[$key]}"
    else
      val="$def"
    fi
    if [ -z "$val" ]; then
      log_message ERROR "模板变量缺失: ${key}"
      return 1
    fi
    if [ -n "$pattern" ] && ! [[ "$val" =~ $pattern ]]; then
      log_message ERROR "模板变量校验失败: ${key}=${val} 不匹配 ${pattern}"
      return 1
    fi
    rendered="${rendered//\{\{${key}\}\}/$val}"
  done < <(_manifest_query --arg id "$template_id" ".templates[] | select(.id == \$id) | (.vars // {}) | to_entries[]? | [.key, (.value.default // \"\"), (.value.pattern // \"\")] | @tsv" 2>/dev/null)
  if grep -Eq '\{\{[A-Z0-9_]+\}\}' <<<"$rendered"; then
    log_message ERROR "模板变量未完全替换: ${template_id}"
    return 1
  fi
  printf '%s\n' "$rendered"
}

_render_templates_payload() {
  local ids=("$@")
  local id=""
  local snippet=""
  local wrapped=""
  local all_payload=""
  for id in "${ids[@]}"; do
    if ! snippet=$(_nginx_template_snippet_by_id "$id"); then
      log_message ERROR "未知模板: ${id}"
      return 1
    fi
    if ! snippet=$(_render_snippet_with_template_vars "$id" "$snippet"); then
      return 1
    fi
    if ! _is_valid_custom_directive_silent "$snippet"; then
      log_message ERROR "内置模板未通过安全校验，已阻止应用: ${id}"
      return 1
    fi
    wrapped=$(_template_block_wrap "$id" "$snippet")
    if [ -n "$all_payload" ]; then
      all_payload+=$'\n'
    fi
    all_payload+="$wrapped"
  done
  printf '%s\n' "$all_payload"
}
