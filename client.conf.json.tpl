{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "remote-dns",
        "type": "https",
        "server": "1.1.1.1",
        "detour": "proxy"
      },
      {
        "tag": "local-dns",
        "type": "udp",
        "server": "223.5.5.5"
      }
    ],
    "rules": [
      {
        "domain_suffix": ["lan", "local"],
        "server": "local-dns"
      }
    ],
    "final": "remote-dns",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": ${MIXED_PORT}
    },
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "${TUN_NAME}",
      "address": [
        "${TUN_ADDR4}",
        "${TUN_ADDR6}"
      ],
      "auto_route": true,
      "strict_route": true
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "proxy",
      "server": "${HY2_DOMAIN}",
      "server_port": ${HY2_PORT},
      "password": "${HY2_PASSWORD}",
      "obfs": {
        "type": "salamander",
        "password": "${HY2_OBFS_PASSWORD}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${HY2_DOMAIN}"
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": {
      "server": "local-dns"
    },
    "rules": [
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "port": 53,
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      }
    ],
    "final": "proxy"
  }
}