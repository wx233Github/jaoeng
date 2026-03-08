#!/usr/bin/env bash

tm_nginx_template_snippet_by_id() {
  local template_id="${1:-}"
  local snippet_rel=""
  local snippet_path=""
  tm_ensure_template_manifest_available || return 1
  # shellcheck disable=SC2016
  snippet_rel=$(tm_manifest_query --arg id "$template_id" '.templates[] | select(.id == $id) | .snippet_file' 2>/dev/null || true)
  if [ -z "$snippet_rel" ] || [ "$snippet_rel" = "null" ]; then
    return 1
  fi
  snippet_path="${NGINX_TEMPLATE_DIR%/}/${snippet_rel}"
  if ! _require_safe_path "$snippet_path" "读取模板文件"; then
    return 1
  fi
  if [ ! -f "$snippet_path" ]; then
    log_message ERROR "模板文件不存在: ${snippet_path}"
    return 1
  fi
  cat "$snippet_path"
}

tm_template_id_to_name() {
  local template_id="${1:-}"
  local name=""
  tm_ensure_template_manifest_available || {
    printf '%s\n' "$template_id"
    return 0
  }
  # shellcheck disable=SC2016
  name=$(tm_manifest_query --arg id "$template_id" '.templates[] | select(.id == $id) | .name' 2>/dev/null || true)
  if [ -z "$name" ] || [ "$name" = "null" ]; then
    printf '%s\n' "$template_id"
  else
    printf '%s\n' "$name"
  fi
}

tm_ensure_template_manifest_available() {
  local manifest_json=""
  local snippet_rel=""
  local snippet_abs=""
  local schema_file="${NGINX_TEMPLATE_DIR%/}/manifest.schema.json"
  if [ -n "${TEMPLATE_MANIFEST_CACHE:-}" ]; then
    return 0
  fi
  if ! _require_safe_path "$NGINX_TEMPLATE_MANIFEST" "读取模板清单"; then
    return 1
  fi
  if [ ! -f "$NGINX_TEMPLATE_MANIFEST" ]; then
    log_message ERROR "模板清单不存在: ${NGINX_TEMPLATE_MANIFEST}"
    return 1
  fi
  if ! manifest_json=$(cat "$NGINX_TEMPLATE_MANIFEST" 2>/dev/null); then
    log_message ERROR "读取模板清单失败: ${NGINX_TEMPLATE_MANIFEST}"
    return 1
  fi
  if ! jq -e . <<<"$manifest_json" >/dev/null 2>&1; then
    log_message ERROR "模板清单 JSON 非法: ${NGINX_TEMPLATE_MANIFEST}"
    return 1
  fi
  if [ -f "$schema_file" ]; then
    if ! _require_safe_path "$schema_file" "读取模板 Schema"; then
      return 1
    fi
    if ! jq -e . "$schema_file" >/dev/null 2>&1; then
      log_message ERROR "模板 Schema JSON 非法: ${schema_file}"
      return 1
    fi
  fi
  if ! jq -e '
    (.version | type == "number") and
    (.templates | type == "array" and length > 0) and
    (.default_combos | type == "array" and length > 0) and
    (all(.templates[]; has("id") and has("name") and has("snippet_file") and (.id | type == "string") and (.id | test("^[a-z0-9_]+$")))) and
    (all(.templates[]; ((.min_nginx_version // "") | type == "string") and (((.min_nginx_version // "") == "") or ((.min_nginx_version // "") | test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$"))))) and
    (all(.templates[]; ((.vars // {}) | type == "object"))) and
    (all(.templates[]; ((.vars // {}) | to_entries | all(.[]; (.key | test("^[A-Z][A-Z0-9_]*$")) and (((.value.default // "") | type) == "string") and (((.value.pattern // "") | type) == "string"))))) and
    (all(.default_combos[]; has("id") and has("name") and (.templates | type == "array" and length > 0)))
  ' <<<"$manifest_json" >/dev/null 2>&1; then
    log_message ERROR "模板清单结构校验失败: ${NGINX_TEMPLATE_MANIFEST}"
    return 1
  fi
  if ! jq -e '([.templates[].id] | length) == ([.templates[].id] | unique | length)' <<<"$manifest_json" >/dev/null 2>&1; then
    log_message ERROR "模板清单中存在重复模板 ID"
    return 1
  fi
  if ! jq -e '
    ([.templates[].id] | unique) as $ids
    | all(.default_combos[].templates[]; ($ids | index(.) != null))
  ' <<<"$manifest_json" >/dev/null 2>&1; then
    log_message ERROR "默认模板组合引用了不存在的模板 ID"
    return 1
  fi
  if ! jq -e '
    ([.templates[].id] | unique) as $ids
    | all(.templates[]; ((.requires // []) + (.conflicts // [])) | all(.[]; ($ids | index(.) != null)))
  ' <<<"$manifest_json" >/dev/null 2>&1; then
    log_message ERROR "模板 requires/conflicts 引用了不存在的模板 ID"
    return 1
  fi
  while IFS= read -r snippet_rel; do
    [ -z "$snippet_rel" ] && continue
    snippet_abs="${NGINX_TEMPLATE_DIR%/}/${snippet_rel}"
    if ! _require_safe_path "$snippet_abs" "读取模板片段"; then
      return 1
    fi
    if [ ! -f "$snippet_abs" ]; then
      log_message ERROR "模板片段不存在: ${snippet_abs}"
      return 1
    fi
  done < <(jq -r '.templates[].snippet_file' <<<"$manifest_json")

  TEMPLATE_MANIFEST_CACHE="$manifest_json"
  return 0
}

tm_manifest_query() {
  if [ "$#" -gt 0 ]; then
    jq -r "$@" <<<"${TEMPLATE_MANIFEST_CACHE:-{}}"
  else
    jq -r . <<<"${TEMPLATE_MANIFEST_CACHE:-{}}"
  fi
}
