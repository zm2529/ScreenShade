# ScreenShade

在 Codex 操作 Mac 时，同时遮黑所有已连接屏幕。物理鼠标移动、鼠标点击、滚轮或任意键按下后，立即移除遮罩并恢复原有硬件亮度。

## 使用

```sh
python3 scripts/build.py
open build/ScreenShade.app
```

App 常驻菜单栏。点击显示器图标 → **遮黑所有屏幕**。倒计时 2 秒后开始，给你时间停下鼠标。再次双击 App 或在菜单中选择恢复，也可以取消遮罩。

首次使用需要在 **系统设置 → 隐私与安全性 → 输入监控** 中允许 ScreenShade。如果列表里没有 App，点击添加，选择本项目的 `build/ScreenShade.app`，完成系统确认后开启开关，并完整退出、重新启动 App。没有权限或无法打开物理输入设备时，App 不会遮黑屏幕。App 不申请屏幕录制权限，不保存按键内容，也不发送数据。

本地 ad-hoc 签名在重新编译后会变化，macOS 可能使旧授权失效。需要时移除旧条目，重新添加更新后的 App；仅重新打开窗口不等于退出并重启进程。

紧急恢复命令：

```sh
swift scripts/control.swift restore
```

## 亮度与兼容性

- 所有活动屏幕都有不拦截鼠标的纯黑遮罩，保持桌面连接、分辨率和窗口布局。
- 在支持 DDC/CI、且能可靠读取原亮度的外接屏上，保存原值后将硬件亮度降到 0；恢复时写回原值并检查读数。
- 不支持硬件调光、读数为空或最大值为 0 的屏幕只应用遮罩。纯黑画面仍可能有 LCD 背光漏光，不等于关闭背光。
- 输入监听使用 IOHIDManager 的物理设备数据，普通 CGEvent/窗口后台输入不会触发恢复。模拟成虚拟 HID 硬件的远控软件仍可能触发，需要按实际远控方式验证。
- 不设置定时自动恢复。退出、睡眠、切换登录会话、显示器连接变化或权限丢失仍触发恢复。
- 硬件亮度恢复记录保存在 `~/Library/Application Support/ScreenShade/brightness-recovery.json`。崩溃后重新打开 App 会重试；临时断开的屏幕会保留恢复记录，在重新连接时重试。未恢复的记录存在时不开始下一轮调光。

当前构建针对运行构建脚本的 Mac 架构，DDC 传输面向 Apple Silicon。本项目使用本地 ad-hoc 签名，供个人使用，未公证。

运行状态保存在 `~/Library/Application Support/ScreenShade/status.json`，只包含遮罩状态、恢复原因、屏幕数量和硬件调光结果，不包含按键内容。

## 开发与验证

```sh
python3 scripts/build.py
python3 scripts/test.py
```

使用 Swift + AppKit + IOKit，无第三方运行时依赖。DDC 注册表和传输代码来自 [m1ddc](https://github.com/waydabber/m1ddc)，固定版本与修改说明见 `Vendor/m1ddc/UPSTREAM.md`，保留 MIT 许可。
