# Android Remote Controller (Flutter + ADB + scrcpy)

这个项目是一个 Flutter 桌面端应用（macOS / Windows / Linux），用于通过 `adb` 和 `scrcpy` 控制另一台 Android 手机。

## 功能

- 刷新并显示 `adb devices -l` 设备列表
- `adb connect <ip:port>` 连接局域网设备
- 启动/停止 `scrcpy` 镜像控制窗口
- 发送常用按键事件（Home、Back、Recent、Power、音量）
- 发送文本输入（`adb shell input text`）
- 内置日志面板，便于排错

## 本地运行

1. 安装依赖：
   - Flutter 3.41+
   - Android platform-tools（提供 `adb`）
   - `scrcpy`
2. 启用桌面平台后运行：

```bash
flutter pub get
flutter run -d macos
```

如果 `adb` 或 `scrcpy` 不在系统 PATH，可在界面顶部填入可执行文件绝对路径。

## Android 设备准备

1. 打开手机开发者选项并启用 USB 调试。
2. 首次建议 USB 连接执行：

```bash
adb devices
adb tcpip 5555
adb connect <手机IP>:5555
```

3. 在本应用中选择设备并开始控制。

## GitHub Actions

仓库包含两个 workflow：

- `ci.yml`：`flutter analyze` + `flutter test`
- `desktop_build.yml`：在 Linux/Windows/macOS 构建桌面应用并上传 artifact

注意：GitHub Actions 只能做构建与测试，不能直接连接你的实体 Android 手机执行远程控制。
