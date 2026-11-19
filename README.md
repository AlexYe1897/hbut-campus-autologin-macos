# 湖北工业大学校园网自动登录 for macOS

HBUT Campus Auto Login · 原生 Swift

一个轻量的 macOS 校园网工具，在系统唤醒或校园 Wi-Fi 连接变化后按需检查并登录锐捷 ePortal。

## 功能

- 已认证时直接结束，需要认证时再登录。
- 只处理首次配置时登记的校园 Wi-Fi，其他网络直接跳过。
- 使用系统通知处理唤醒和网络变化，合并短时间内的重复事件。
- TUN 兼容版适用于 Clash TUN、普通系统代理和无代理环境。
- 账号密码存入本机 macOS 钥匙串，配置和日志不保存凭据。
- 后台及设置窗口都不显示 Dock 图标，也不占用菜单栏。
- 设置窗口显示后台状态、最近检查时间、触发原因和结果。
- 没有第三方运行时或第三方 Swift 包依赖。

## 适用范围

当前适配湖北工业大学的锐捷 ePortal，服务固定为「校园网 / default」。`http://1.1.1.1` 是引导入口，实际认证服务器为 `http://172.16.54.18/eportal/`。程序每次重新获取本次网络的引导参数，不固定用户 IP、MAC 或会话。

部署目标为 macOS 14 及以上。常规版和 TUN 版均已在 Apple 芯片 Mac 上实测。具体系统版本、代理配置和场景见 [测试与已知限制](docs/TESTING.md)。

## 代理兼容性

**1.0.6 TUN 兼容版可用于下面三种网络设置。** 它自动识别已登记的校园 Wi-Fi，并始终通过实际 Wi-Fi 网卡发送本工具的请求。窗口里的「TUN」是构建标记，切换 Clash 设置后仍可使用同一个应用。

| 网络设置 | 1.0.6 的行为与验证 |
| --- | --- |
| 开启 Clash TUN | 经实际 Wi-Fi 直连，为联网检测绕开 Fake-IP。已实测重新认证和 Wi-Fi 重连触发检查 |
| 仅开启普通系统代理（HTTP / HTTPS） | 本工具的请求绕过系统代理。1.0.5 已实测，1.0.6 的完整重登待专项验证 |
| 关闭 TUN 和系统代理 | 本工具沿用同一条 Wi-Fi 直连路径。1.0.6 的完整重登待专项验证 |

TUN 开启时，退出校园网认证后通过「立即检查」触发后台，约 10 秒完成登录并确认联网。随后关开 Wi-Fi，后台自行触发检查，当时认证仍有效。详见 [TUN 兼容说明](docs/TUN.md)。

## 构建与安装

需要 Apple Command Line Tools 或 Xcode，并能运行 `xcrun swiftc`。

| 构建 | 运行命令 | 生成的应用 |
| --- | --- | --- |
| TUN 兼容版，适合在三种代理设置之间切换 | `zsh build-tun.sh` | `build/tun/校园网自动登录.app`（1.0.6） |
| 常规版，适合无代理或仅开启系统代理 | `zsh build.sh` | `build/校园网自动登录.app`（1.0.5，默认构建） |

将选定的应用放到**当前用户的** `~/Applications/` 文件夹。后台任务从固定路径 `~/Applications/校园网自动登录.app` 启动。

以首次安装 TUN 版为例，在项目目录运行：

```sh
mkdir -p "$HOME/Applications"
ditto "build/tun/校园网自动登录.app" "$HOME/Applications/校园网自动登录.app"
open "$HOME/Applications/校园网自动登录.app"
```

更新或切换版本时，先在设置中点「停用」并关闭窗口。用 Finder 替换用户「应用程序」中的旧应用，再连接校园 Wi-Fi，打开新应用并点「保存并启用」。如果 macOS 提示钥匙串访问，请核对应用名称并按需授权。两种构建都使用本机临时签名。

## 使用

1. 连接校园 Wi-Fi，打开「校园网自动登录」。
2. 在本机窗口填写账号密码，点「保存并启用」。
3. 关闭窗口即可。后台在系统唤醒或重新连接此 Wi-Fi 后检查，等待约 3 秒让网络就绪。

查看状态时，从用户「应用程序」文件夹重新打开本工具。可点「立即检查」手动检查；修改凭据时重新填写并保存，两项都留空则使用已有凭据。

认证失败会区分账户校验、服务绑定、会话异常等原因。部分失败会暂停自动提交，避免反复登录；可手动重试一次或修正设置后保存。需要验证码或额外认证时，仍需使用网页处理。

「停用」停止后台；「卸载」停止后台、移除本工具的启动配置和钥匙串项，并将应用和数据目录移到废纸篓。

## 低功耗设计

- 平时在后台等待 macOS 通知。系统唤醒、Wi-Fi 变化或手动检查等事件才会触发检查。后台没有定时联网轮询或保活请求。
- 短时间内的重复事件会合并。连上已登记的校园 Wi-Fi 后，确认已联网就结束检查，需要认证时才登录。一轮限时约 30 秒，最多提交一次凭据。
- 系统睡眠时会取消检查。程序不安排自动唤醒，也不阻止 Mac 进入睡眠。

空闲资源占用的抽样结果见 [测试与已知限制](docs/TESTING.md)。目前没有整机电池续航测试数据。

## 开发

可以用 VS Code 打开整个项目，配合 [Swift 官方扩展](https://github.com/swiftlang/vscode-swift) 编辑源码。项目提供 `Package.swift`、扩展建议和构建 / 检查任务。

```sh
zsh test.sh        # 常规版离线检查
zsh test-tun.sh    # TUN 版离线检查
swift build        # SwiftPM 编译，用于开发与编辑器支持
```

源码入口为 [Sources/App.swift](Sources/App.swift) 和 [Sources/Core.swift](Sources/Core.swift)。详细结构、VS Code 使用方法和诊断入口见 [开发指南](docs/DEVELOPMENT.md)。

GitHub Actions 的 macOS 工作流会构建并离线检查两种应用。

## 本机数据与隐私

| 内容 | 位置 |
| --- | --- |
| 应用 | `~/Applications/校园网自动登录.app` |
| 用户启动任务 | `~/Library/LaunchAgents/local.hbut.autologin.plist` |
| 配置与固定状态日志 | `~/Library/Application Support/HBUTAutoLogin/` |
| 账号密码 | macOS 钥匙串，服务名 `local.hbut.autologin` |

不采集遥测，不写入原始服务器回复或带会话参数的认证网址。

构建产物、缓存、本机配置和真实联网测试记录不纳入 Git。提交问题时，只需提供版本、固定状态文字和触发方式，不附账号密码或完整认证网址。

## 许可

[MIT License](LICENSE)。更新记录见 [CHANGELOG.md](CHANGELOG.md)。
