# Xray + Cloudflare 中文一键脚本

用于在自有的全新 VPS 上部署：

```text
主节点：VLESS + XHTTP + TLS + Cloudflare
备用节点：VLESS + WebSocket + TLS + Cloudflare
```

## 使用方式

将 `xray-cf-setup.sh` 上传至新的 Ubuntu 24.04 VPS，然后运行：

```bash
chmod +x xray-cf-setup.sh
sudo bash xray-cf-setup.sh
```

首次运行选择 `1`。脚本会：

- 使用 XTLS 官方脚本安装 Xray 稳定版
- 安装 Nginx、Certbot、jq
- 自动申请 Let's Encrypt 证书
- 写入 VLESS XHTTP 主节点和 WebSocket 备用节点
- 在修改前备份旧配置
- 输出可导入 v2rayN 的链接

如果 VPS 已经运行网站、面板或其他 Nginx 服务，请先人工检查现有配置，不要直接安装。

## 域名填写

普通 Cloudflare 橙色云场景：

```text
回源域名：cdn.example.com
客户端连接域名：直接留空
```

Cloudflare for SaaS 自定义主机名场景：

```text
回源域名：origin.example.com
客户端连接域名：edge.example.net
```

## Cloudflare 设置

确保：

```text
DNS：回源域名开启橙色云
SSL/TLS：Full (Strict)
```

Cloudflare 支持代理 WebSocket，使用标准 HTTPS 端口 `443`。

XHTTP 主节点默认使用 `packet-up`，优先保证经过 Cloudflare 和反向代理时的兼容性。Cloudflare 中建议同时开启 gRPC 支持。最新版 v2rayN 使用 XHTTP 时请关闭全局 `mux.cool`。

## 注意

- 不要公开脚本导出的链接，其中包含 UUID。
- 如果 UUID 曾出现在截图或聊天中，运行菜单 `4` 进行轮换。
- 最新版 v2rayN 如需兼容固定使用 HTTP 代理端口的应用，可将本地 `mixed` 端口设置为 `10809`。
