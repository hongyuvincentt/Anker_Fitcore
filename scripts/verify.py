#!/usr/bin/env python3
"""Offline scaffold checks; optional iOS build is separate and requires full Xcode."""
from __future__ import annotations

import ast
import json
import plistlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios"
APP = IOS / "Fitcore"


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)


project_file = IOS / "Fitcore.xcodeproj/project.pbxproj"
run("plutil", "-lint", str(project_file), str(APP / "Resources/Info.plist"))
raw = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project_file)])
project = json.loads(raw)
objects = project["objects"]
root = objects[project["rootObject"]]
assert root["isa"] == "PBXProject"
target_id = root["targets"][0]
target = objects[target_id]
paths = {}


def resolve(ref, parent):
    obj = objects[ref]
    if obj.get("sourceTree") == "BUILT_PRODUCTS_DIR":
        return
    path = parent / obj.get("path", "")
    if obj["isa"] == "PBXGroup":
        for child in obj["children"]:
            resolve(child, path)
    elif obj["isa"] == "PBXFileReference":
        assert path.exists(), f"Missing Xcode reference: {path}"
        paths[ref] = path


resolve(root["mainGroup"], IOS)
source_ids = next(objects[p]["files"] for p in target["buildPhases"] if objects[p]["isa"] == "PBXSourcesBuildPhase")
compiled = {paths[objects[b]["fileRef"]] for b in source_ids}
swift_files = set(APP.rglob("*.swift"))
assert compiled == swift_files, "Xcode source membership does not match the filesystem"
for obj in objects.values():
    if obj["isa"] == "XCBuildConfiguration" and "baseConfigurationReference" in obj:
        assert obj["baseConfigurationReference"] in paths
scheme = ET.parse(IOS / "Fitcore.xcodeproj/xcshareddata/xcschemes/Fitcore-Mock.xcscheme")
for ref in scheme.findall(".//BuildableReference"):
    assert ref.attrib["BlueprintIdentifier"] == target_id
ET.parse(IOS / "Fitcore.xcodeproj/project.xcworkspace/contents.xcworkspacedata")
for catalog in APP.rglob("Contents.json"):
    metadata = json.loads(catalog.read_text())
    for entry in metadata.get("images", []):
        if "filename" in entry:
            assert (catalog.parent / entry["filename"]).is_file()
with (APP / "Resources/Info.plist").open("rb") as f:
    info = plistlib.load(f)
assert "UIBackgroundModes" not in info, "Mock app does not need background entitlements"
for path in (ROOT / "backend").rglob("*.py"):
    if ".venv" not in path.parts:
        ast.parse(path.read_text(), filename=str(path))
run("swiftc", "-frontend", "-parse", *map(str, sorted(swift_files)))
core = sorted((APP / "Core").rglob("*.swift")) + sorted((APP / "Services").rglob("*.swift"))
with tempfile.TemporaryDirectory(prefix="fitcore-check-") as directory:
    for check in ("check_core", "check_dynamic_records"):
        executable = str(Path(directory) / check)
        run("swiftc", "-swift-version", "5", "-strict-concurrency=complete", "-warnings-as-errors",
            "-module-cache-path", str(Path(directory) / "module-cache"),
            *map(str, core), str(APP / "App/AppStore.swift"), str(ROOT / f"scripts/{check}.swift"), "-o", executable)
        run(executable)
print("Scaffold checks passed. This is NOT an iOS SDK build or a backend runtime test.")
