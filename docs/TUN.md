# Clash TUN 兼容方案

本方案单独编译为 TUN 兼容版，原版仍由 `build.sh` 构建。两版共用同一份校园网配置、钥匙串和用户启动任务，一次只安装并启用一个版本。

## 为什么单纯禁用 HTTP 代理不够

`curl --noproxy '*'` 只影响应用层代理选择，不改变系统路由。Clash TUN 开启自动路由后，即使系统默认接口仍显示 `en0`，到校园认证服务器的请求也可能经 `utun` 虚拟网卡。Fake-IP DNS 还可能把外网检测域名解析为 `198.18.0.0/15` 内的虚拟地址。

因此，「默认接口是 Wi-Fi」和「没有使用 HTTP 代理」都不足以证明请求直连。原版在某些 TUN 分流配置下可能仍然工作，但无法保证认证流量绕过 TUN。

## 额外构建

```sh
zsh test.sh        # 原版 44 项离线检查
zsh test-tun.sh    # 原检查在 TUN 构建下运行，再执行 TUN 专项检查
zsh build.sh       # 原版，build/校园网自动登录.app
zsh build-tun.sh   # TUN 版，build/tun/校园网自动登录.app
```

TUN 版使用 `TUN_COMPAT` 编译开关，版本为 1.0.6；原版元数据和默认构建仍保留为 1.0.5。SwiftPM 默认构建原版，编辑 TUN 代码时可用 `swift build -Xswiftc -DTUN_COMPAT`。

## 实现

1. 从 macOS 的真实 Wi-Fi 接口收集当前连接，识别已登记的校园 Wi-Fi，不依赖全局主接口是 `en0` 还是 `utun`。多个连接无法可靠区分时直接跳过。
2. 每个本工具的 HTTP 请求都通过 `curl --interface if!<Wi-Fi接口>` 绑定真实网卡。绑定不可用时结束本轮，不静默退回到 TUN。
3. 使用两个数字 IP 的 HTTP 入口获取新的校园引导，避免认证发现阶段受到 Fake-IP DNS 影响。认证服务器、路径、端口、当前用户 IP 的原有校验保留。
4. 对两个固定的外网检测域名，通过数字 IP 的 HTTPS DNS 服务解析真实 A 记录，再以 `--resolve` 发出绑定 Wi-Fi 的 HTTPS 请求。继续按原域名校验证书与 SNI，保留证书校验，不使用 `--insecure`。
5. DNS 回复必须对应所查询的域名，仅接受其 CNAME 链上的公网 IPv4 地址；拒绝 Fake-IP、私有、回环等目标。解析成功本身不算联网成功，还必须通过外部 HTTPS 检测。

仅解析 `www.baidu.com` 和 `www.apple.com`；解析请求不附带校园网账号、密码、认证参数或设备标识。校园认证仍直接使用校内 IP。解析结果只在当前有限检查中使用，不写入磁盘、不安排刷新任务。

联网检测仍限时约 5 秒，整轮约 30 秒，凭据仍最多提交一次。没有新增常驻服务、周期任务、自动唤醒或第三方运行时，不修改 Clash 的节点、规则、TUN 开关或系统 DNS。

## 安装与回退

安装路径为 `~/Applications/校园网自动登录.app`。切换版本前先在现有应用里点「停用」并关闭窗口。将旧应用移到备份位置，再把选定的应用复制到固定安装路径。

连接校园 Wi-Fi，打开新应用。继续使用旧凭据时，将账号与密码留空并点「保存并启用」。应用更换签名后，macOS 可能要求重新授权现有钥匙串项。确认是本工具后，可在系统提示中选择「始终允许」，供后台继续读取。保存会登记当前 Wi-Fi，请在校园 Wi-Fi 上进行。

回退时按同样步骤替换应用，使用常规版备份或 `build.sh` 生成的产物。

## 验证范围

2026-11-19 在 Apple 芯片 Mac、macOS 27.2、Clash Verge 2.5.10 上验证。测试期间开启 TUN 与 Fake-IP，系统 HTTP 代理关闭。

- 在非校园网络验证了物理网卡绑定、HTTPS DNS 解析以及保留证书校验的 HTTPS 联网检测。
- 在校园 Wi-Fi 上退出认证，确认出现校园网认证跳转，然后通过「立即检查」触发后台。后台完成自动登录并确认直连联网，从退出到验证结束约 10 秒。
- 保持 TUN 开启，关闭再打开 Wi-Fi。重新接入后，后台自动记录「Wi-Fi 连接变化」并确认联网，当时原认证仍有效。

TUN 开启时，从认证失效并自然唤醒到重新登录的组合还需实测。其他 TUN 配置和 VPN 组合的验证范围见 [测试与已知限制](TESTING.md)。

参考：[curl 接口绑定](https://curl.se/libcurl/c/CURLOPT_INTERFACE.html)、[Mihomo TUN 路由](https://wiki.metacubex.one/config/inbound/tun/)、[AliDNS HTTPS JSON API](https://help.aliyun.com/en/dns/httpdns-doh-json-api)。
