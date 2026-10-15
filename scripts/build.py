#!/usr/bin/env python3
"""Build a macOS app, preserving the selected local code signing identity."""
import argparse
from pathlib import Path
import os
import plistlib
import platform
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build" / "ScreenShade.app"
SIGNING_CONFIG = ROOT / "build" / "signing-identity.txt"


def run(*args):
    subprocess.run(list(map(str, args)), cwd=ROOT, check=True)


def choose_identity(identities, requested=None, saved=None, ad_hoc=False):
    """Never silently change the saved identity or fall back to ad-hoc signing."""
    if ad_hoc:
        if saved or requested:
            raise ValueError("已经配置固定签名证书，不能用 --ad-hoc 覆盖日常使用的 App。"
                             "请运行 python3 scripts/build.py 沿用证书；若确需临时签名实验，请使用单独的项目副本。")
        return "-", "ad-hoc"
    selected = requested or saved
    if selected:
        matches = [(fingerprint, name) for fingerprint, name in identities
                   if fingerprint.lower() == selected.lower() or name == selected]
        if len(matches) != 1:
            raise ValueError("指定或已保存的签名证书不可用或不唯一。请用 security find-identity -v -p codesigning 检查，"
                             "再用 --sign 指定有效证书；不会自动更换签名。")
        return matches[0]
    if len(identities) == 1:
        return identities[0]
    if identities:
        raise ValueError("找到多个签名证书。请用 security find-identity -v -p codesigning 查看，"
                         "再用 --sign 指定证书 SHA-1。选择会保存在 build/ 中。")
    raise ValueError("没有可用签名证书。请配置自己的 Apple Development 证书，或显式使用 --ad-hoc。"
                     "临时签名在代码更新后可能需要重新授予输入监控权限。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--sign", metavar="IDENTITY", help="Certificate SHA-1 or exact name; saved locally")
    group.add_argument("--ad-hoc", action="store_true", help="Use temporary signing; updates may invalidate permissions")
    args = parser.parse_args()
    identities = []
    if not args.ad_hoc:
        output = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
        identities = re.findall(r'^\s*\d+\) ([0-9A-Fa-f]{40}) "([^"\n]+)"\s*$', output, re.MULTILINE)
    requested = args.sign or os.environ.get("SCREENSHADE_SIGNING_IDENTITY")
    saved = SIGNING_CONFIG.read_text().strip() if SIGNING_CONFIG.exists() else None
    try:
        identity, name = choose_identity(identities, requested, saved, args.ad_hoc)
    except ValueError as error:
        parser.error(str(error))

    # Replacing a running bundle can invalidate macOS's view of its signature.
    processes = subprocess.run(["pgrep", "-x", "ScreenShade"], capture_output=True, text=True)
    if processes.returncode == 0:
        parser.error("请先从菜单栏完整退出 ScreenShade，再构建；构建不会覆盖运行中的 App。")
    if processes.returncode != 1:
        parser.error("无法确认 ScreenShade 是否已退出，构建已停止。")

    # A failed build must preserve the existing app.
    staging = ROOT / "build" / "staging"
    if staging.exists():
        shutil.rmtree(staging)
    staged_app = staging / "ScreenShade.app"
    contents = staged_app / "Contents"
    for directory in (contents / "MacOS", contents / "Helpers", contents / "Resources"):
        directory.mkdir(parents=True, exist_ok=True)
    vendor = ROOT / "Vendor" / "m1ddc"
    helper = contents / "Helpers" / "ddc-helper"
    run("xcrun", "clang", "-mmacosx-version-min=13.0", "-fmodules", "-Wall", "-Wextra", "-Werror", "-DMAX_DISPLAYS=16",
        "-I", vendor / "headers", ROOT / "Sources/DDCHelper.m",
        vendor / "sources/ioregistry.m", vendor / "sources/i2c.m",
        "-framework", "Foundation", "-framework", "CoreDisplay", "-framework", "IOKit",
        "-framework", "CoreGraphics", "-o", helper)
    target = f"{platform.machine()}-apple-macos13.0"
    run("xcrun", "swiftc", "-target", target, "-swift-version", "5", "-O", "-framework", "Cocoa", "-framework", "IOKit",
        *sorted((ROOT / "Sources").glob("*.swift")), "-o", contents / "MacOS/ScreenShade")
    info = {
        "CFBundleIdentifier": "local.ScreenShade",
        "CFBundleName": "ScreenShade",
        "CFBundleDisplayName": "ScreenShade",
        "CFBundleExecutable": "ScreenShade",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.1.0",
        "CFBundleVersion": "3",
        "LSUIElement": True,
        "LSMinimumSystemVersion": "13.0",
        "NSHighResolutionCapable": True,
        "NSHumanReadableCopyright": "ScreenShade; DDC transport includes m1ddc (MIT).",
        "NSInputMonitoringUsageDescription": "检测本地鼠标和键盘活动，以恢复屏幕；不记录按键内容。",
    }
    with (contents / "Info.plist").open("wb") as file:
        plistlib.dump(info, file)
    shutil.copyfile(vendor / "LICENSE", contents / "Resources/m1ddc-LICENSE.txt")
    options = ["--options", "runtime", "--timestamp"] if name.startswith("Developer ID Application:") else ["--timestamp=none"]
    run("codesign", "--force", "--sign", identity, *options, "--identifier", "local.ScreenShade.ddc-helper", helper)
    run("codesign", "--force", "--sign", identity, *options, "--identifier", "local.ScreenShade", staged_app)
    run("codesign", "--verify", "--deep", "--strict", staged_app)
    backup = ROOT / "build" / "previous-ScreenShade.app"
    if backup.exists():
        shutil.rmtree(backup)
    if APP.exists():
        APP.rename(backup)
    try:
        staged_app.rename(APP)
    except OSError:
        if backup.exists():
            backup.rename(APP)
        raise
    if identity != "-":
        SIGNING_CONFIG.write_text(identity + "\n")
    if backup.exists():
        shutil.rmtree(backup)
    shutil.rmtree(staging)
    print("签名：" + ("临时签名（更新后可能需要重新授权）" if identity == "-" else "固定证书；后续构建沿用本机选择"))
    print(APP)


if __name__ == "__main__":
    main()
