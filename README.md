# Android Remote Controller (Flutter + ADB + scrcpy)

这个项目是一个 Flutter 多端应用：
- 桌面端（macOS / Windows / Linux）：通过 `adb` + `scrcpy` 控制另一台 Android 手机。
- Android 端（APK）：`ADB Assistant` 模式，用于生成和复制无线调试命令（`pair/connect` 等）。

## 功能

- 桌面端控制：
  - 刷新并显示 `adb devices -l` 设备列表
  - `adb connect <ip:port>` 连接局域网设备
  - 启动/停止 `scrcpy` 镜像控制窗口
  - 发送常用按键事件（Home、Back、Recent、Power、音量）
  - 发送文本输入（`adb shell input text`）
- Android 端（车机互联 V1）：
  - 多设备档案管理（名称/IP/端口/配对码/包名）
  - 一键生成并复制 `adb pair` / `adb connect` / 常用控制命令
  - 一键复制全部命令，便于投送到终端或运维脚本
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

应用会自动查找内置 `tools/` 目录中的 `adb/scrcpy`；找不到时回退系统 PATH，不需要用户手动配置路径。

## 内置工具打包

- 通过 GitHub Actions 生成的桌面构建产物会自动下载并打包：
  - Android platform-tools（包含 `adb`）
  - 官方 `scrcpy` release 二进制
- 应用启动时会优先查找并使用产物内 `tools/` 目录下的工具；若不存在则回退到系统 PATH。
- 本地 `flutter run` 默认仍使用系统安装的 `adb/scrcpy`，也可以手动创建项目根目录 `tools/` 覆盖默认路径。

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
- `desktop_build.yml`：在 Linux/Windows/macOS 构建桌面应用，打包 `adb/scrcpy` 并上传 artifact
- `android_build.yml`：构建 Android APK 并上传 artifact

注意：GitHub Actions 只能做构建与测试，不能直接连接你的实体 Android 手机执行远程控制。
注意：`adb + scrcpy` 全功能控制依赖桌面宿主机；Android APK 当前实现为车机互联 V1（命令生成/复制 + 档案管理），不是 scrcpy 镜像控制。
