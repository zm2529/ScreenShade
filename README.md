# ScreenShade

在 Codex 操作 Mac 时，同时遮黑所有已连接屏幕。物理鼠标移动、鼠标点击、滚轮或任意键按下后，立即移除遮罩并恢复原有硬件亮度；也可点击任一屏幕右上角的“关闭遮罩”恢复全部屏幕。

## 使用

支持 Apple Silicon Mac，要求 macOS 13 或更新版本。源码构建需要 Python 3 和 Apple Command Line Tools（`xcode-select --install`）。

已有本机签名配置时，构建前完整退出 App，然后沿用保存的证书：

```sh
python3 scripts/build.py
open build/ScreenShade.app
```

首次构建且有多个证书时，按下文用 `--sign` 选择自己的证书。没有开发证书、也尚未配置固定签名时，可以显式使用临时签名：

```sh
python3 scripts/build.py --ad-hoc
open build/ScreenShade.app
```

临时签名适合直接使用同一份构建产物；重新打开同一份 App 不会改变签名。**更新代码并重新构建后，可能需要重新授权**。经常更新的用户建议使用下文的固定证书构建方式。已配置证书后再次运行 `--ad-hoc` 会报错停止，避免无意间使已有授权失效。

日常使用可在完整退出 App 后，将已验证的 `build/ScreenShade.app` 复制到 `/Applications`，从应用程序目录打开并为这份 App 授权。后续开发构建不会自动替换安装版本；需要更新安装版本时，先退出 App，再用同一证书构建并替换。不要混用签名身份不同的构建版和安装版。

App 常驻菜单栏。点击显示器图标 → **遮黑所有屏幕**。倒计时 2 秒后开始，给你时间停下鼠标。在菜单中选择恢复，或点击遮罩右上角的关闭按钮，可以取消遮罩。重复打开 App 不会切换遮罩；未遮罩时只显示控制窗口，遮罩期间保持原状。

使用向日葵等远程控制软件时，远端可能也会看到黑色遮罩。远程鼠标和键盘输入通常不会触发物理输入监听；此时直接点击所连屏幕右上角的 **关闭遮罩**，即可恢复所有屏幕及原有硬件亮度。按钮支持 App 未激活时直接点击，不需要先切换到 ScreenShade。

还可以从远端向 Mac 发送 **Control + Option + Command + R（⌃⌥⌘R）**，主动唤醒全部屏幕并恢复原亮度，不需要先激活 ScreenShade。这是唯一专用全局组合键，普通移动、点击和按键不会触发。远控软件需要将该组合键转发给被控 Mac，不能由控制端系统拦截；向日葵的实际转发仍需按所用客户端确认。若快捷键无法注册（如已被其他应用独占），App 会标明不可用并禁用硬件待机，不会只凭已保存的勾选继续关屏。紧急恢复命令也仍保留。

首次使用需要在 **系统设置 → 隐私与安全性 → 输入监控** 中允许 ScreenShade。如果列表里没有 App，点击添加，选择本项目的 `build/ScreenShade.app`，完成系统确认后开启开关，并完整退出、重新启动 App。没有权限或无法打开物理输入设备时，App 不会遮黑屏幕。App 不申请屏幕录制权限，不保存按键内容，也不发送数据。

若开关已经开启但 App 仍显示未允许，先完整退出 App，在输入监控中移除旧条目，再添加当前构建的 App 并允许，然后重新打开。更换签名身份（包括从临时签名切换为证书签名）需要重新授权；仅重新打开窗口不等于退出并重启进程。

权限已允许但输入设备不可用时，App 会显示设备错误，不会要求再次授权。

紧急恢复命令：

```sh
swift scripts/control.swift restore
```

## 亮度与兼容性

- 所有活动屏幕都有黑色遮罩，右上角保留“关闭遮罩”按钮。除按钮区域外，遮罩不拦截鼠标，保持桌面连接、分辨率和窗口布局。
- 在支持 DDC/CI、且能可靠读取原亮度的外接屏上，保存原值后将硬件亮度降到 0；恢复时写回原值并检查读数。
- 不支持硬件调光、读数为空或最大值为 0 的屏幕只应用遮罩。纯黑画面仍可能有 LCD 背光漏光，不等于关闭背光。
- 输入监听使用 IOHIDManager 的物理设备数据，普通 CGEvent/Computer Use 键鼠输入不会触发自动恢复；明确标为 Virtual、未知的外接传输以及 AirPlay 输入也不作为物理输入。按设备报告的传输类型及内置标记识别，不是防范伪装硬件设备的安全边界。
- 切换应用、应用失去焦点、普通系统对话框不会触发恢复。关闭按钮、菜单恢复、专用唤醒组合键和紧急恢复命令是主动退出入口，Computer Use 明确操作这些入口时可以关闭遮罩。
- 不设置定时自动恢复。退出、睡眠、切换登录会话、显示器连接变化或权限丢失仍触发恢复。
- 硬件亮度恢复记录保存在 `~/Library/Application Support/ScreenShade/brightness-recovery.json`。崩溃后重新打开 App 会重试；临时断开的屏幕会保留恢复记录，在重新连接时重试。未恢复的记录存在时不开始下一轮调光。

## 硬件待机（可选）

控制窗口和菜单栏提供 **硬件待机（逐屏设置）**，每块显示器各有一个勾选项，默认全部关闭。选择按显示器 UUID 分别保存，取消一块不会改变其他屏幕的选择。仅对已勾选、且已完成本机连接、唤醒和 Computer Use 验证的显示器发送 DDC 电源指令；未勾选的屏幕使用黑色遮罩和最低亮度。未通过验证的屏幕会标明原因并禁用待机勾选项。待机不改变分辨率或主动断开显示器，Computer Use 的普通键鼠输入仍不会解除遮罩；本机物理输入或主动恢复会唤醒屏幕。

硬件待机不会删除遮罩窗口或关闭按钮。在已验证保留显示连接的配置中，物理屏幕待机时软件桌面仍存在，远程采集仍可显示按钮；即使所有可用显示器都勾选了待机，也可以使用上述专用组合键或紧急恢复命令唤醒。不同远控软件的采集和按键转发行为需要实测，不能把显示器的 DDC 兼容结果当成向日葵客户端验收。

兼容配置保存在 `~/Library/Application Support/ScreenShade/standby-compatibility.json`，按显示器 UUID 和整套屏幕坐标、缩放、像素分辨率、刷新率及旋转绑定，不随源码分发。配置缺失、连接或桌面布局改变时，不使用未匹配的硬件待机配置。更换线材、扩展坞或显示器电源/USB 设置后也应重新验证。

关屏前原子保存原电源状态和亮度，恢复时先唤醒并检查读数，再恢复亮度；唤醒最多重试三次，失败保留恢复记录供后续重试或重新启动恢复。紧急恢复命令仍为 `swift scripts/control.swift restore`。不发送 DDC 的写入型彻底关机值 5，以免关屏后失去软件唤醒能力。

显示器可能接受 DDC 写入却不进入待机，或需要重试才能唤醒。验证时应检查电源状态读数、恢复原亮度、Computer Use 操作，以及屏幕数量、桌面布局、原窗口位置和 USB 连接是否保持。电源读数不能代替对背光是否完全熄灭的目视确认；一种连接方式的结果也不能代表其他连接方式。

显示器型号、UUID、桌面布局、签名选择和实机测试证据仅保存在使用者本机，不随源码提交。`build/`、本机兼容配置、恢复记录和运行状态均排除在版本控制之外。

当前构建针对运行构建脚本的 Mac 架构，DDC 传输面向 Apple Silicon。源码构建默认不公证。

运行状态保存在 `~/Library/Application Support/ScreenShade/status.json`，只包含遮罩状态、恢复原因、屏幕数量、已选待机屏幕和硬件调光结果，不包含按键内容。

## 开发与验证

使用自己的 Apple Development 证书进行本地开发构建（在 Xcode 的账户设置中配置开发账号和证书）：

```sh
security find-identity -v -p codesigning
python3 scripts/build.py --sign '<所选证书的 SHA-1>'
```

首次成功构建后，证书选择保存在被 Git 忽略的 `build/signing-identity.txt`。以后保持相同证书和 Bundle ID 构建：

```sh
python3 scripts/build.py
python3 scripts/test.py
```

只有一个有效签名证书时可以自动选择；有多个时需要首次指定。也可以用 `SCREENSHADE_SIGNING_IDENTITY` 环境变量指定证书。证书缺失或选择不唯一时构建会停止，不会自动换成临时签名。已有保存的证书选择或环境变量指定身份时，`--ad-hoc` 会被拒绝；临时签名实验应使用单独的项目副本。

构建前需完整退出 ScreenShade，避免覆盖正在运行的 App。编译和签名校验成功后才替换现有 App。证书私钥始终留在用户自己的钥匙串中；仓库不包含开发者证书、私钥或本机签名配置。不要将 `build/` 删除后误认为仍保留了本机证书选择。

使用 Swift + AppKit + IOKit，无第三方运行时依赖。DDC 注册表和传输代码来自 [m1ddc](https://github.com/waydabber/m1ddc)，固定版本与修改说明见 `Vendor/m1ddc/UPSTREAM.md`，保留 MIT 许可。

## GitHub 发行版

当前仓库提供源码构建方式，尚未提供经过 Apple 公证的下载版。其他用户不需要项目作者的证书：可以在自己的 Mac 上选择自己的证书，或使用 `--ad-hoc` 构建。

若发布供普通用户直接下载的 App，应使用发布者的 **Developer ID Application** 证书签名，并提交 Apple 公证；Apple Development 签名只用于开发构建。构建脚本在选择 Developer ID Application 证书时自动开启 Hardened Runtime 和安全时间戳，但**不会自动完成公证**。发布者可以按以下流程准备产物：

```sh
python3 scripts/build.py --sign '<Developer ID Application 证书的 SHA-1>'
ditto -c -k --keepParent build/ScreenShade.app build/ScreenShade-notarization.zip
# 提前按 Apple 文档在钥匙串中配置自己的公证凭据；不要提交凭据。
xcrun notarytool submit build/ScreenShade-notarization.zip --keychain-profile '<公证凭据名称>' --wait
# 仅在公证结果为 Accepted 后继续：
xcrun stapler staple build/ScreenShade.app
xcrun stapler validate build/ScreenShade.app
spctl --assess --type execute --verbose build/ScreenShade.app
ditto -c -k --keepParent build/ScreenShade.app build/ScreenShade.zip
```

校验通过后才将最终 ZIP 上传 GitHub Release。本项目的物理输入监听和硬件调光仍需在该发行签名下验证。下载者将 App 放在固定位置（例如 `/Applications`），首次打开后手动授予输入监控权限。后续发行版应保持 Bundle ID 和签名身份一致，避免无必要地更换授权身份；源码自行签名版与正式发行版切换时可能需要重新授权。

参考：[Apple 代码签名要求](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)、[Developer ID 分发](https://developer.apple.com/developer-id/)、[macOS 软件公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。
