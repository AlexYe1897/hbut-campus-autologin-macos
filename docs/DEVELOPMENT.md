# 开发指南

## 环境

项目仅面向 macOS，需要 Apple Command Line Tools 或 Xcode。SwiftPM 清单要求 Swift 5.9 及以上，并使用 Swift 5 语言模式；本次整理验证使用 Apple Swift 6.4。

```sh
xcrun swift --version
```

如果尚未安装编译工具，可通过 Apple 的 `xcode-select --install` 安装 Command Line Tools。编辑代码不要求使用 Xcode 界面。

## 使用 VS Code

1. 选择「文件 → 打开文件夹」，打开包含 `Package.swift` 的项目根目录。
2. 可选安装项目建议的 [Swift 官方扩展](https://github.com/swiftlang/vscode-swift)，支持 SwiftPM 项目的补全、跳转和编译诊断。扩展标识为 `swiftlang.swift-vscode`。
3. `Sources/App.swift` 包含界面和系统事件，`Sources/Core.swift` 包含网络认证等核心逻辑。
4. 在「终端 → 运行任务」中选择常规版或 TUN 版的构建与离线检查。默认构建快捷键生成常规版 `.app`。

SwiftPM 用于编辑器识别和编译。可安装的应用由 `build.sh` 或 `build-tun.sh` 生成。

## 目录

```text
.
├── Sources/
│   ├── App.swift             # 设置界面、LaunchAgent 控制、系统通知
│   ├── Core.swift            # 钥匙串、网络识别、HTTP、认证、RSA
│   └── TUNSupport.swift      # TUN 构建的 Wi-Fi 选择与 HTTPS DNS
├── Resources/Info.plist      # 应用元数据、版本、隐藏 Dock 设置
├── Tests/
│   ├── CoreTests.swift       # 离线检查入口
│   ├── TUNTests.swift        # TUN 专项离线检查
│   └── RSAFixture.json       # 合成 RSA 参考数据
├── docs/                    # 开发和测试说明
├── Package.swift            # SwiftPM / 编辑器入口
├── build.sh / build-tun.sh  # 编译并签名对应构建的 .app
└── test.sh / test-tun.sh    # 编译并执行对应构建的离线检查
```

## 构建与离线检查

```sh
swift build
swift build -Xswiftc -DTUN_COMPAT
zsh test.sh
zsh test-tun.sh
zsh build.sh
zsh build-tun.sh
```

`swift build` 产出开发可执行文件，加上 `-Xswiftc -DTUN_COMPAT` 可编译 TUN 代码。两份构建脚本各自产出带应用元数据和本机临时签名的应用包。后台任务从 `~/Applications/校园网自动登录.app` 启动。

`test.sh` 和 `test-tun.sh` 是两种构建的检查入口。检查使用合成账号、测试网段和 RSA 参考值，在离线环境即可运行。

构建产物写入 `build/`。常规版版本号取自 `Resources/Info.plist`，TUN 版由 `build-tun.sh` 写入版本号和 `HBUTNetworkMode` 标记。调整版本时同步更新 README 和 CHANGELOG。

## 运行结构

设置界面和后台监听是同一个原生可执行文件的两种运行模式。LaunchAgent 以 `--agent` 启动监听器，界面通过系统通知请求检查或重新读取配置。

一次自动检查的顺序是：系统事件 → 合并并延迟约 3 秒 → 确认显示器已唤醒、当前 Wi-Fi 已登记 → 直连 HTTPS 检查 → 必要时获取新的 ePortal 引导并认证。睡眠或网络变化会取消当前工作，不在结束后安排周期任务。

认证只接受已确认学校服务器的路径和端口，并核对引导中的用户 IP 与当前连接一致。密码计算遵循学校页面的 UTF-16 反转、字节排列和 raw RSA；不是通用网页自动填写器。

## 诊断入口

在已安装应用的可执行文件上可使用以下参数：

| 参数 | 行为 |
| --- | --- |
| `--diagnose` | 输出配置、Wi-Fi 就绪和直连探测状态。TUN 版额外报告是否选中实际 Wi-Fi、当前 Wi-Fi 是否已登记 |
| `--check-keychain` | 检查本工具是否能读取已有凭据，只输出成功或失败 |
| `--once` | 按当前配置执行一次检查，必要时会真实提交认证 |
| `--agent --observe-only` | 只监听系统事件，不发送网络请求或读取凭据 |

CI 对两种构建运行编译、离线检查和应用包签名验证。真实认证测试需要连接校园网，并会改变当前认证状态。

## 提交范围

提交源码、合成测试数据、应用元数据、脚本和文档。`build/`、`.build/`、`dist/`、本机设置及日志由 `.gitignore` 排除；真实联网测试报告保留在本地 `build/` 中。

问题报告只需包含应用版本、macOS 版本、触发方式及窗口固定状态文字。不要附带钥匙串内容、完整登录网址、个人账号或原始服务器回复。
