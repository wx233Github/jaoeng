# 反代增强（长响应/流式服务建议启用）
proxy_set_header X-Forwarded-Host $host;
proxy_connect_timeout {{PROXY_CONNECT_TIMEOUT}};
proxy_send_timeout {{PROXY_SEND_TIMEOUT}};
proxy_read_timeout {{PROXY_READ_TIMEOUT}};
