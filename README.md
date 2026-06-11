# proxy 
## 使用
- 服务端
```shell
sudo ./manage.sh install_server
sudo ./manage.sh set_dns
sudo ./manage.sh set_cert
sudo ./manage.sh set_server
```
- 客户端
```shell
sudo ./manage.sh install_client
sudo ./manage.sh set_client  # 默认开tun

关闭 TUN：
sudo ./manage.sh disable_tun

开启 TUN：
sudo ./manage.sh enable_tun
```

