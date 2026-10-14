#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, "-B", str(root / "Tests/SigningTests.py")], check=True)
test = root / "build/input-policy-tests"
subprocess.run(["xcrun", "swiftc", str(root / "Sources/InputPolicy.swift"),
                str(root / "Tests/InputPolicyTests.swift"), "-o", str(test)], check=True)
subprocess.run([str(test)], check=True)
subprocess.run([str(root / "build/ScreenShade.app/Contents/Helpers/ddc-helper"), "--self-test"], check=True)
