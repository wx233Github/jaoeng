# HSTS 严格 HTTPS（确认全站 HTTPS 稳定后使用）
add_header Strict-Transport-Security "max-age={{HSTS_MAX_AGE}}; includeSubDomains" always;
