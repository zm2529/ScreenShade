#!/usr/bin/env python3
"""Build a standalone, locally signed macOS app with Apple's command-line tools."""
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build" / "ScreenShade.app"
CONTENTS = APP / "Contents"
for directory in (CONTENTS / "MacOS", CONTENTS / "Helpers", CONTENTS / "Resources"):
    directory.mkdir(parents=True, exist_ok=True)

def run(*args):
    subprocess.run(list(map(str, args)), cwd=ROOT, check=True)

vendor = ROOT / "Vendor" / "m1ddc"
helper = CONTENTS / "Helpers" / "ddc-helper"
run("xcrun", "clang", "-mmacosx-version-min=13.0", "-fmodules", "-Wall", "-Wextra", "-Werror", "-DMAX_DISPLAYS=16",
    "-I", vendor / "headers", ROOT / "Sources/DDCHelper.m",
    vendor / "sources/ioregistry.m", vendor / "sources/i2c.m",
    "-framework", "Foundation", "-framework", "CoreDisplay", "-framework", "IOKit",
    "-framework", "CoreGraphics", "-o", helper)
target = f"{platform.machine()}-apple-macos13.0"
run("xcrun", "swiftc", "-target", target, "-swift-version", "5", "-O", "-framework", "Cocoa", "-framework", "IOKit",
    *sorted((ROOT / "Sources").glob("*.swift")), "-o", CONTENTS / "MacOS/ScreenShade")
info = {
    "CFBundleIdentifier": "local.ScreenShade",
    "CFBundleName": "ScreenShade",
    "CFBundleDisplayName": "ScreenShade",
    "CFBundleExecutable": "ScreenShade",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0.0",
    "CFBundleVersion": "1",
    "LSUIElement": True,
    "LSMinimumSystemVersion": "13.0",
    "NSHighResolutionCapable": True,
    "NSHumanReadableCopyright": "ScreenShade; DDC transport includes m1ddc (MIT).",
    "NSInputMonitoringUsageDescription": "检测本地鼠标和键盘活动，以恢复屏幕；不记录按键内容。",
}
with (CONTENTS / "Info.plist").open("wb") as file:
    plistlib.dump(info, file)
shutil.copyfile(vendor / "LICENSE", CONTENTS / "Resources/m1ddc-LICENSE.txt")
run("codesign", "--force", "--sign", "-", "--identifier", "local.ScreenShade.ddc-helper", helper)
run("codesign", "--force", "--sign", "-", "--identifier", "local.ScreenShade", APP)
run("codesign", "--verify", "--deep", "--strict", APP)
print(APP)
