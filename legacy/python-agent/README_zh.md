# AgentBeacon Companion 安装包

这个安装包用于安装 Codex 会话 raw-signal companion agent。它会在本机读取 `.codex` 状态，做基础裁剪和 secret masking，然后在局域网提供：

```text
http://本机IP:42180/status
```

树莓派上的 AgentBeacon 面板会自动发现或轮询这个接口，并由树莓派统一判断“思考、工具调用、完成、中断”等状态。

## Windows

1. 解压安装包。
2. 双击 `install_windows.cmd`。
3. 如果 Windows 防火墙弹窗，允许“专用网络”访问。

安装后会复制到：

```text
%LOCALAPPDATA%\AgentBeacon\Companion
```

并在当前用户的启动文件夹创建登录自启快捷方式。

卸载：双击 `uninstall_windows.cmd`。

## macOS

在终端进入解压后的目录，然后运行：

```sh
sh install_macos.sh
```

安装后会复制到：

```text
~/Library/Application Support/AgentBeacon/Companion
```

并创建 LaunchAgent：

```text
~/Library/LaunchAgents/com.agentbeacon.companion.plist
```

卸载：

```sh
sh uninstall_macos.sh
```

## 要求

- 需要 Python 3。
- 端口默认是 `42180`。
- Windows/macOS 设备和树莓派需要在同一个局域网内。
