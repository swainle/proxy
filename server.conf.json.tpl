{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "up_mbps": ${HY2_UP_MBPS},
      "down_mbps": ${HY2_DOWN_MBPS},
      "users": [
        {
          "name": "${HY2_USER_NAME}",
          "password": "${HY2_PASSWORD}"
        }
      ],
      "obfs": {
        "type": "salamander",
        "password": "${HY2_OBFS_PASSWORD}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${HY2_DOMAIN}",
        "certificate_path": "${CERT_FULLCHAIN}",
        "key_path": "${CERT_PRIVKEY}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}