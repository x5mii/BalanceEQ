#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check updater trust/privacy settings and, optionally, the packaged framework."""
import base64
import json
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
bundle = Path(sys.argv[1]) if len(sys.argv) == 2 else None
info = plistlib.loads((bundle / "Contents/Info.plist" if bundle else root / "Resources/Info.plist").read_bytes())
assert info["SUFeedURL"] == "https://raw.githubusercontent.com/x5mii/BalanceEQ/updates/appcast.xml"
assert len(base64.b64decode(info["SUPublicEDKey"], validate=True)) == 32
for key in ("SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"):
    assert info[key] is True, key
assert info["SUSignedFeedFailureExpirationInterval"] == 0
for key in ("SUEnableAutomaticChecks", "SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate", "SUEnableSystemProfiling"):
    assert info[key] is False, key
assert "NSAppTransportSecurity" not in info, "Local test transport settings must not ship"
pins = json.loads((root / "Package.resolved").read_text())["pins"]
sparkle = next(pin for pin in pins if pin["identity"] == "sparkle")
assert sparkle["state"] == {"version": "2.10.1", "revision": "ab7d71291238df6e0492143b120c9b696a35f603"}
if bundle:
    binary = bundle / "Contents/MacOS/EqualizerMac"
    framework = bundle / "Contents/Frameworks/Sparkle.framework"
    assert (framework / "Versions/Current").is_symlink(), "Framework symlinks must survive packaging"
    assert "@rpath/Sparkle.framework/" in subprocess.check_output(["otool", "-L", str(binary)], text=True)
    assert "@executable_path/../Frameworks" in subprocess.check_output(["otool", "-l", str(binary)], text=True)
    for component in ("Autoupdate", "Updater.app/Contents/MacOS/Updater", "XPCServices/Installer.xpc/Contents/MacOS/Installer"):
        assert (framework / "Versions/B" / component).is_file(), component
    assert (bundle / "Contents/Resources/Sparkle-LICENSE.txt").read_bytes() == (root / "Resources/Sparkle-LICENSE.txt").read_bytes()
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
print("PASS updater: pinned dependency, signed feed/archive, manual checks, no profiling" + (", packaged framework" if bundle else ""))
