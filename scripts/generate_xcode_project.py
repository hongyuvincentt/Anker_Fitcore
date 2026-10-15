#!/usr/bin/env python3
"""Generate the checked-in Xcode project using only Python's standard library.

Run after adding/removing Swift source files outside Xcode. IDs are derived from
paths, making regeneration stable. Configuration belongs in ios/Configuration.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios"
PROJECT = IOS / "Fitcore.xcodeproj"
OBJECTS = {}


def identifier(key):
    return hashlib.sha256(key.encode()).hexdigest()[:24].upper()


def add(key, **values):
    key_id = identifier(key)
    OBJECTS[key_id] = values
    return key_id


sources, resources = [], []


def group(directory):
    children = []
    for path in sorted(directory.iterdir()):
        if path.name.startswith(".") or path.name == "Local.xcconfig":
            continue
        relative = path.relative_to(IOS).as_posix()
        if path.is_dir() and path.suffix != ".xcassets":
            children.append(group(path))
            continue
        kind = {
            ".swift": "sourcecode.swift", ".plist": "text.plist.xml",
            ".xcassets": "folder.assetcatalog", ".xcconfig": "text.xcconfig",
            ".example": "text", ".md": "net.daringfireball.markdown",
        }.get(path.suffix)
        if kind is None:
            continue
        ref = add("file:" + relative, isa="PBXFileReference", lastKnownFileType=kind,
                  path=path.name, sourceTree="<group>")
        children.append(ref)
        if path.suffix in (".swift", ".xcassets"):
            build = add("build:" + relative, isa="PBXBuildFile", fileRef=ref)
            (sources if path.suffix == ".swift" else resources).append(build)
    return add("group:" + directory.relative_to(IOS).as_posix(), isa="PBXGroup",
               children=children, path=directory.name, sourceTree="<group>")


def configuration_list(owner):
    configs = []
    for name in ("Debug", "Release"):
        if owner == "target":
            settings = {"baseConfigurationReference": identifier(f"file:Configuration/{name}.xcconfig"),
                        "buildSettings": {}}
        else:
            settings = {"buildSettings": {"SDKROOT": "iphoneos", "CLANG_ENABLE_MODULES": "YES",
                        "CLANG_ENABLE_OBJC_ARC": "YES", "ALWAYS_SEARCH_USER_PATHS": "NO"}}
        configs.append(add(f"config:{owner}:{name}", isa="XCBuildConfiguration", name=name, **settings))
    return add("configs:" + owner, isa="XCConfigurationList", buildConfigurations=configs,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def serialize(value, level=0):
    indent = "\t" * level
    if isinstance(value, dict):
        return "{\n" + "".join(
            f"{indent}\t{json.dumps(str(k))} = {serialize(v, level + 1)};\n"
            for k, v in value.items()) + indent + "}"
    if isinstance(value, list):
        return "(\n" + "".join(f"{indent}\t{serialize(v, level + 1)},\n" for v in value) + indent + ")"
    return json.dumps(value, ensure_ascii=False)


app_group = group(IOS / "Fitcore")
config_group = group(IOS / "Configuration")
product = add("product", isa="PBXFileReference", explicitFileType="wrapper.application",
              includeInIndex=0, path="Fitcore.app", sourceTree="BUILT_PRODUCTS_DIR")
products = add("products", isa="PBXGroup", children=[product], name="Products", sourceTree="<group>")
main_group = add("main", isa="PBXGroup", children=[app_group, config_group, products], sourceTree="<group>")
phases = []
for name, isa, files in (("sources", "PBXSourcesBuildPhase", sources),
                         ("frameworks", "PBXFrameworksBuildPhase", []),
                         ("resources", "PBXResourcesBuildPhase", resources)):
    phases.append(add("phase:" + name, isa=isa, buildActionMask=2147483647,
                      files=files, runOnlyForDeploymentPostprocessing=0))
target = add("target", isa="PBXNativeTarget", buildConfigurationList=configuration_list("target"),
             buildPhases=phases, buildRules=[], dependencies=[], name="Fitcore", productName="Fitcore",
             productReference=product, productType="com.apple.product-type.application")
project = add("project", isa="PBXProject", attributes={"LastUpgradeCheck": "2600", "LastSwiftUpdateCheck": "2600",
              "TargetAttributes": {target: {"CreatedOnToolsVersion": "26.0"}}},
              buildConfigurationList=configuration_list("project"), compatibilityVersion="Xcode 14.0",
              developmentRegion="zh-Hans", hasScannedForEncodings=0, knownRegions=["zh-Hans", "en", "Base"],
              mainGroup=main_group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[target])
contents = {"archiveVersion": 1, "classes": {}, "objectVersion": 56,
            "objects": OBJECTS, "rootObject": project}
PROJECT.mkdir(parents=True, exist_ok=True)
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(contents) + "\n")
reference = (f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" '
             f'BuildableName="Fitcore.app" BlueprintName="Fitcore" ReferencedContainer="container:Fitcore.xcodeproj"/>')
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
shared = PROJECT / "xcshareddata" / "xcschemes"
shared.mkdir(parents=True, exist_ok=True)
(shared / "Fitcore-Mock.xcscheme").write_text(scheme)
workspace = PROJECT / "project.xcworkspace"
workspace.mkdir(parents=True, exist_ok=True)
(workspace / "contents.xcworkspacedata").write_text(
    '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n')
print(f"Generated {PROJECT.relative_to(ROOT)}: {len(sources)} Swift sources, {len(resources)} resource catalog(s)")
