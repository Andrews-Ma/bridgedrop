#!/usr/bin/env python3
"""Generate a dependency-free Xcode project for the shared native sources."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "BridgeDrop.xcodeproj"
PROJECT.mkdir(exist_ok=True)

def ident(label):
    return hashlib.sha256(label.encode()).hexdigest()[:24].upper()

def quoted(value):
    return json.dumps(str(value), ensure_ascii=False)

objects = []
def obj(label, content):
    objects.append(f"\t\t{ident(label)} = {{ {content} }};")
    return ident(label)

sources = sorted([*ROOT.glob("App/*.swift"), *ROOT.glob("Sources/BridgeDropCore/*.swift")])
refs = []
for path in sources:
    relative = path.relative_to(ROOT).as_posix()
    refs.append(obj("ref:" + relative, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(relative)}; sourceTree = SOURCE_ROOT;"))

asset_ref = obj("assets", "isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = assets/Assets.xcassets; sourceTree = SOURCE_ROOT;")
localized_refs = []
for language in ["en", "zh-Hans"]:
    localized_refs.append(obj("infostrings:" + language, f"isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = {quoted(language)}; path = {quoted('config/' + language + '.lproj/InfoPlist.strings')}; sourceTree = SOURCE_ROOT;"))
localized_group = obj("infostrings", f"isa = PBXVariantGroup; children = ({','.join(localized_refs)}); name = InfoPlist.strings; sourceTree = {quoted('<group>')};")
products = []
targets = []
for platform, sdk, product, plist, bundle in [
    ("iOS", "iphoneos", "BridgeDrop-iOS", "config/iOS-Info.plist", "org.local.bridgedrop"),
    ("Mac", "macosx", "BridgeDrop-Mac", "config/Mac-Info.plist", "org.local.bridgedrop.mac"),
]:
    label = "target:" + platform
    product_ref = obj("product:" + platform, f"isa = PBXFileReference; explicitFileType = wrapper.application; path = {quoted(product + '.app')}; sourceTree = BUILT_PRODUCTS_DIR;")
    products.append(product_ref)
    builds = []
    for path, ref in zip(sources, refs):
        builds.append(obj(f"build:{platform}:{path.relative_to(ROOT)}", f"isa = PBXBuildFile; fileRef = {ref};"))
    phase = obj("sources:" + platform, f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(builds)}); runOnlyForDeploymentPostprocessing = 0;")
    frameworks = obj("frameworks:" + platform, "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
    asset_build = obj("assetbuild:" + platform, f"isa = PBXBuildFile; fileRef = {asset_ref};")
    localized_build = obj("infostringsbuild:" + platform, f"isa = PBXBuildFile; fileRef = {localized_group};")
    resources = obj("resources:" + platform, f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({asset_build},{localized_build}); runOnlyForDeploymentPostprocessing = 0;")
    configurations = []
    for mode in ["Debug", "Release"]:
        settings = {
            "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "", "ENABLE_APP_SANDBOX": "NO",
            "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": plist, "PRODUCT_BUNDLE_IDENTIFIER": bundle,
            "PRODUCT_NAME": product, "SDKROOT": sdk, "SWIFT_VERSION": "5.0", "MARKETING_VERSION": "1.2.0",
            "CURRENT_PROJECT_VERSION": "3", "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if mode == "Debug" else "",
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "CLANG_ENABLE_MODULES": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        }
        if platform == "iOS":
            settings.update(IPHONEOS_DEPLOYMENT_TARGET="17.0", TARGETED_DEVICE_FAMILY="1", SUPPORTED_PLATFORMS="iphoneos iphonesimulator")
        else:
            settings.update(MACOSX_DEPLOYMENT_TARGET="13.0", CODE_SIGN_ENTITLEMENTS="config/Mac.entitlements")
        text = " ".join(f"{key} = {quoted(value)};" for key, value in settings.items())
        configurations.append(obj(f"configuration:{platform}:{mode}", f"isa = XCBuildConfiguration; buildSettings = {{ {text} }}; name = {mode};"))
    config_list = obj("configs:" + platform, f"isa = XCConfigurationList; buildConfigurations = ({','.join(configurations)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
    targets.append(obj(label, f"isa = PBXNativeTarget; buildConfigurationList = {config_list}; buildPhases = ({phase},{frameworks},{resources}); buildRules = (); dependencies = (); name = {quoted(product)}; productName = {quoted(product)}; productReference = {product_ref}; productType = {quoted('com.apple.product-type.application')};"))
    schema = PROJECT / "xcshareddata" / "xcschemes" / (product + ".xcscheme")
    schema.parent.mkdir(parents=True, exist_ok=True)
    buildref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(label)}" BuildableName="{product}.app" BlueprintName="{product}" ReferencedContainer="container:BridgeDrop.xcodeproj"/>'
    schema.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{buildref}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''', encoding="utf-8")

products_group = obj("products", f"isa = PBXGroup; children = ({','.join(products)}); name = Products; sourceTree = {quoted('<group>')};")
main_group = obj("group", f"isa = PBXGroup; children = ({','.join(refs + [asset_ref, localized_group, products_group])}); sourceTree = {quoted('<group>')};")
project_configs = []
for mode in ["Debug", "Release"]:
    project_configs.append(obj("projectconfig:" + mode, f"isa = XCBuildConfiguration; buildSettings = {{ CLANG_ENABLE_OBJC_ARC = YES; }}; name = {mode};"))
project_config_list = obj("projectconfigs", f"isa = XCConfigurationList; buildConfigurations = ({','.join(project_configs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
project_id = obj("project", f"isa = PBXProject; attributes = {{ LastUpgradeCheck = 2600; }}; buildConfigurationList = {project_config_list}; compatibilityVersion = {quoted('Xcode 14.0')}; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,\"zh-Hans\",Base); mainGroup = {main_group}; productRefGroup = {products_group}; projectDirPath = \"\"; projectRoot = \"\"; targets = ({','.join(targets)});")
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {project_id};\n}}\n", encoding="utf-8")
print("Generated BridgeDrop.xcodeproj with iOS and Mac schemes")
