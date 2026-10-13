#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise installer transactions on macOS without network, app launch, or real HOME writes."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import zipfile


INSTALLER = Path(__file__).resolve().with_name("install.sh")
APP_ID = "org.equalizerformac.app"
TOOLS = r'''
import json, os, pathlib, shutil, subprocess, sys
name = pathlib.Path(sys.argv[1]).name
args = sys.argv[2:]
root = pathlib.Path(os.environ["BALANCEEQ_INSTALLER_TEST"])
mode = os.environ["BALANCEEQ_INSTALLER_CASE"]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps({"tool": name, "args": args}) + "\n")
if name == "uname":
    print("Darwin")
elif name == "sw_vers":
    print("14.1" if mode == "old_os" else "14.2")
elif name == "pgrep":
    sys.exit(0 if mode == "running" else 1)
elif name == "curl":
    if mode == "download_failure":
        sys.exit(22)
    asset = next(arg.rsplit("/", 1)[-1] for arg in args if arg.startswith("https://"))
    assert asset in ("BalanceEQ.zip", "BalanceEQ.zip.sha256")
    output = pathlib.Path(args[args.index("--output") + 1])
    assert output.is_relative_to(root)
    shutil.copyfile(root / "fixtures" / asset, output)
elif name == "codesign":
    sys.exit(1 if mode == "bad_signature" else 0)
elif name == "spctl":
    sys.exit(1 if mode == "gatekeeper" else 0)
elif name == "mv":
    assert all(pathlib.Path(arg).is_relative_to(root) for arg in args)
    if mode == "failed_replacement" and pathlib.Path(args[0]).name == "BalanceEQ.app" and pathlib.Path(args[0]).parent.name.startswith(".balanceeq-install."):
        print("Test: replacement move failed", file=sys.stderr)
        sys.exit(73)
    sys.exit(subprocess.call(["/bin/mv", *args]))
elif name != "open":
    raise AssertionError("Unexpected test command: " + name)
'''


def bundle_files(version, identifier=APP_ID):
    return {
        "Contents/Info.plist": plistlib.dumps({
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "EqualizerMac",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": version,
        }),
        "Contents/MacOS/EqualizerMac": f"#!/bin/sh\n# Fixture {version}; never launched.\nexit 0\n".encode(),
    }


def snapshot(app):
    return {str(path.relative_to(app)): path.read_bytes() for path in app.rglob("*") if path.is_file()}


def check_case(mode, error=None, existing=True):
    with tempfile.TemporaryDirectory(prefix="balanceeq-installer-check-") as directory:
        root = Path(directory).resolve()
        test_home, temporary, fixtures, commands = [root / name for name in ("home", "tmp", "fixtures", "bin")]
        for path in (test_home, temporary, fixtures, commands):
            path.mkdir()
        destination = test_home / "Applications/BalanceEQ.app"
        old_files = bundle_files("old")
        if existing:
            for name, data in old_files.items():
                path = destination / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
        presets = test_home / "Library/Application Support/EqualizerForMac/state.json"
        presets.parent.mkdir(parents=True)
        saved_presets = b'{"version":1,"presets":[],"lastPreset":null}\n'
        presets.write_bytes(saved_presets)

        incoming = bundle_files("new", "example.unrelated" if mode == "invalid_bundle" else APP_ID)
        archive = fixtures / "BalanceEQ.zip"
        with zipfile.ZipFile(archive, "w") as zipped:
            for name, data in incoming.items():
                entry = zipfile.ZipInfo("BalanceEQ.app/" + name)
                entry.external_attr = (0o100755 if name.endswith("EqualizerMac") else 0o100644) << 16
                zipped.writestr(entry, data)
        digest = "0" * 64 if mode == "bad_checksum" else hashlib.sha256(archive.read_bytes()).hexdigest()
        (fixtures / "BalanceEQ.zip.sha256").write_text(digest + "  BalanceEQ.zip\n")
        dispatcher = root / "tools.py"
        dispatcher.write_text(TOOLS)
        wrapper = f'#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(dispatcher))} "$0" "$@"\n'
        for name in ("uname", "sw_vers", "pgrep", "curl", "codesign", "spctl", "open", "mv"):
            command = commands / name
            command.write_text(wrapper)
            command.chmod(0o755)
        env = dict(os.environ, HOME=str(test_home), TMPDIR=str(temporary),
                   PATH=f"{commands}:/usr/bin:/bin:/usr/sbin:/sbin",
                   BALANCEEQ_INSTALLER_TEST=str(root), BALANCEEQ_INSTALLER_CASE=mode)
        env.pop("BASH_ENV", None)
        env.pop("ENV", None)
        result = subprocess.run(["/bin/bash", str(INSTALLER)], env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        assert (result.returncode == 0) == (error is None), (mode, result.returncode, result.stdout)
        if error:
            assert error in result.stdout, (mode, result.stdout)
        assert snapshot(destination) == (old_files if error and existing else {} if error else incoming), mode
        assert presets.read_bytes() == saved_presets, mode
        assert not list(temporary.iterdir()), (mode, "Download files leaked")
        assert not list((test_home / "Applications").glob(".balanceeq-install.*")), (mode, "Staging files leaked")
        calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
        opened = [call for call in calls if call["tool"] == "open"]
        assert opened == ([] if error else [{"tool": "open", "args": [str(destination)]}]), mode
        if mode in ("running", "old_os"):
            assert not any(call["tool"] == "curl" for call in calls), mode
        if mode == "failed_replacement":
            assert any(call["tool"] == "mv" and call["args"][0].endswith("/previous.app") for call in calls), "Rollback was not attempted"
        print(f"PASS installer: {mode}")


if __name__ == "__main__":
    if sys.platform != "darwin" or os.geteuid() == 0:
        sys.exit("Installer checks require macOS and a non-root user.")
    check_case("first_install", existing=False)
    check_case("update")
    for case, message in (
        ("running", "Quit BalanceEQ"),
        ("bad_checksum", "checksum mismatch"),
        ("invalid_bundle", "unexpected app identity"),
        ("bad_signature", "signature verification failed"),
        ("gatekeeper", "macOS did not approve"),
        ("old_os", "macOS 14.2 or later"),
        ("failed_replacement", "replacement move failed"),
        ("download_failure", "No downloadable signed release"),
    ):
        check_case(case, message)
