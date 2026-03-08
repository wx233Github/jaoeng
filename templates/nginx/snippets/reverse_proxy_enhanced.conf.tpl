# 反代增强（长响应/流式服务建议启用）
proxy_set_header X-Forwarded-Host $host;
proxy_connect_timeout 60s;
proxy_send_timeout 600s;
proxy_read_timeout 600s;
