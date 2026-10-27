# 湖北工业大学校园网自动登录

HBUT Campus Auto Login · 原生 Swift / macOS · v1.0.5

一个在系统唤醒或校园 Wi-Fi 连接变化后，按需检查并登录锐捷 ePortal 的小工具。平时等待系统事件，不定时联网，不发送保活请求。

## 功能

- 已认证时直接结束，需要认证时再登录。
- 只处理首次配置时登记的校园 Wi-Fi，其他网络直接跳过。
- 使用系统通知处理唤醒和网络变化，合并短时间内的重复事件。
- 请求直连认证服务器，无需修改 Clash 系统代理开关。
- 账号密码存入本机 macOS 钥匙串，配置和日志不保存凭据。
- 后台及设置窗口都不显示 Dock 图标，也不占用菜单栏。
- 设置窗口显示后台状态、最近检查时间、触发原因和结果。
- 没有第三方运行时或第三方 Swift 包依赖。

## 适用范围

当前适配湖北工业大学的锐捷 ePortal，服务固定为「校园网 / default」。`http://1.1.1.1` 是引导入口，实际认证服务器为 `http://172.16.54.18/eportal/`。程序每次重新获取本次网络的引导参数，不固定用户 IP、MAC 或会话。

部署目标为 macOS 14 及以上；实际验证环境是 Apple 芯片、macOS 27.0.1、Wi-Fi、Clash Verge 2.5.8。其他 macOS 版本、Intel Mac、其他运营商服务和有线网络尚未实测。

真实退出认证后的自动登录已通过本机测试；自然唤醒场景仍在持续观察。具体范围见 [测试与已知限制](docs/TESTING.md)。

## 构建与安装

需要 Apple Command Line Tools 或 Xcode，并能运行 `xcrun swiftc`。

```sh
zsh build.sh
```

产物位于 `build/校园网自动登录.app`。将它放到**当前用户的** `~/Applications/` 文件夹；后台任务使用这个固定位置，不是系统的 `/Applications/`。

首次安装可在项目终端执行：

```sh
mkdir -p "$HOME/Applications"
ditto "build/校园网自动登录.app" "$HOME/Applications/校园网自动登录.app"
open "$HOME/Applications/校园网自动登录.app"
```

更新已有安装前，先在设置中点「停用」并关闭窗口，再替换应用，重新打开并启用。构建使用本机临时签名，尚未做 Developer ID 签名或 Apple 公证。

## 使用

1. 连接校园 Wi-Fi，打开「校园网自动登录」。
2. 在本机窗口填写账号密码，点「保存并启用」。
3. 关闭窗口即可。后台在系统唤醒或重新连接此 Wi-Fi 后检查，等待约 3 秒让网络就绪。

查看状态时，从用户「应用程序」文件夹重新打开本工具。可点「立即检查」手动检查；修改凭据时重新填写并保存，两项都留空则使用已有凭据。

认证失败会区分账户校验、服务绑定、会话异常等原因。部分失败会暂停自动提交，避免反复登录；可手动重试一次或修正设置后保存。需要验证码或额外认证时，仍需使用网页处理。

「停用」停止后台；「卸载」停止后台、移除本工具的启动配置和钥匙串项，并将应用和数据目录移到废纸篓。

## 开发

可以用 VS Code 打开整个项目，配合 [Swift 官方扩展](https://github.com/swiftlang/vscode-swift) 编辑源码。项目提供 `Package.swift`、扩展建议和构建 / 检查任务。

```sh
zsh test.sh    # 离线检查，不读取真实凭据、不提交认证
swift build    # SwiftPM 编译，用于开发与编辑器支持
zsh build.sh   # 生成可安装的 .app
```

源码入口为 [Sources/App.swift](Sources/App.swift) 和 [Sources/Core.swift](Sources/Core.swift)。详细结构、VS Code 使用方法和诊断入口见 [开发指南](docs/DEVELOPMENT.md)。

仓库附带 GitHub Actions 的 macOS 编译与离线检查配置，云端检查不访问校园网。

## 本机数据与隐私

| 内容 | 位置 |
| --- | --- |
| 应用 | `~/Applications/校园网自动登录.app` |
| 用户启动任务 | `~/Library/LaunchAgents/local.hbut.autologin.plist` |
| 配置与固定状态日志 | `~/Library/Application Support/HBUTAutoLogin/` |
| 账号密码 | macOS 钥匙串，服务名 `local.hbut.autologin` |

不采集遥测，不写入原始服务器回复或带会话参数的认证网址。单轮检查限时约 30 秒，最多提交一次凭据；不安排电脑自动唤醒，不持有电源断言。

构建产物、缓存、本机配置和真实联网测试记录不纳入 Git。提交问题时，只需提供版本、固定状态文字和触发方式，不附账号密码或完整认证网址。

## 许可

[MIT License](LICENSE)。更新记录见 [CHANGELOG.md](CHANGELOG.md)。
