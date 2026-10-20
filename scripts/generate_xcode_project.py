#!/usr/bin/env python3
"""Emit the app project, or an opt-in simulator UI-test project alongside it."""
import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--ui-tests", action="store_true",
                    help="emit iOS/MangaShelfUI.xcodeproj and its screenshot test scheme")
arguments = parser.parse_args()
PROJECT = ROOT/("iOS/MangaShelfUI.xcodeproj" if arguments.ui_tests else "iOS/MangaShelf.xcodeproj")
objects = {}
def identifier(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(object_label, isa, **values):
    key=identifier(object_label); objects[key]={"isa":isa,**values}; return key
def config_list(name, base):
    configs=[]
    for kind in ("Debug","Release"):
        settings={**base,"SWIFT_OPTIMIZATION_LEVEL":"-Onone" if kind=="Debug" else "-O"}
        configs.append(add(name+kind,"XCBuildConfiguration",name=kind,buildSettings=settings))
    return add(name+"List","XCConfigurationList",buildConfigurations=configs,defaultConfigurationIsVisible="0",defaultConfigurationName="Release")

file_refs=[]; source_builds=[]
for path in sorted((ROOT/"iOS/MangaShelf").glob("*.swift")):
    ref=add("file:"+path.name,"PBXFileReference",lastKnownFileType="sourcecode.swift",path="MangaShelf/"+path.name,sourceTree="<group>")
    file_refs.append(ref);source_builds.append(add("build:"+path.name,"PBXBuildFile",fileRef=ref))
privacy=add("privacy","PBXFileReference",lastKnownFileType="text.xml",path="MangaShelf/PrivacyInfo.xcprivacy",sourceTree="<group>")
plist=add("plist","PBXFileReference",lastKnownFileType="text.plist.xml",path="MangaShelf/Info.plist",sourceTree="<group>")
file_refs.extend([privacy,plist])
resource_builds=[]
for path in sorted((ROOT/"iOS/MangaShelf/Resources").iterdir()):
    kind = "folder" if path.is_dir() else "file"
    ref=add("resource:"+path.name,"PBXFileReference",lastKnownFileType=kind,
            path="MangaShelf/Resources/"+path.name,sourceTree="<group>")
    file_refs.append(ref)
    resource_builds.append(add("resource-build:"+path.name,"PBXBuildFile",fileRef=ref))
product=add("product","PBXFileReference",explicitFileType="wrapper.application",includeInIndex="0",path="MangaShelf.app",sourceTree="BUILT_PRODUCTS_DIR")
products=add("products","PBXGroup",children=[product],name="Products",sourceTree="<group>")
group=add("root-group","PBXGroup",children=file_refs+[products],sourceTree="<group>")
package=add("package","XCLocalSwiftPackageReference",relativePath="..")
dependency=add("reader-core","XCSwiftPackageProductDependency",package=package,productName="ReaderCore")
framework=add("reader-core-build","PBXBuildFile",productRef=dependency)
sources=add("sources","PBXSourcesBuildPhase",buildActionMask="2147483647",files=source_builds,runOnlyForDeploymentPostprocessing="0")
frameworks=add("frameworks","PBXFrameworksBuildPhase",buildActionMask="2147483647",files=[framework],runOnlyForDeploymentPostprocessing="0")
privacy_build=add("privacy-build","PBXBuildFile",fileRef=privacy)
resources=add("resources","PBXResourcesBuildPhase",buildActionMask="2147483647",files=[privacy_build]+resource_builds,runOnlyForDeploymentPostprocessing="0")
base={"SDKROOT":"iphoneos","IPHONEOS_DEPLOYMENT_TARGET":"26.0","SWIFT_VERSION":"5.0","CLANG_ENABLE_MODULES":"YES",
      "CLANG_ENABLE_OBJC_ARC":"YES","ENABLE_USER_SCRIPT_SANDBOXING":"YES","GCC_C_LANGUAGE_STANDARD":"c11"}
target_settings={"PRODUCT_BUNDLE_IDENTIFIER":"app.mangashelf.reader","PRODUCT_NAME":"$(TARGET_NAME)","INFOPLIST_FILE":"MangaShelf/Info.plist",
                 "GENERATE_INFOPLIST_FILE":"NO","TARGETED_DEVICE_FAMILY":"1,2","CODE_SIGN_STYLE":"Automatic",
                 "SWIFT_VERSION":"5.0","SWIFT_STRICT_CONCURRENCY":"targeted","SUPPORTED_PLATFORMS":"iphoneos iphonesimulator",
                 "ENABLE_PREVIEWS":"YES","LD_RUNPATH_SEARCH_PATHS":["$(inherited)","@executable_path/Frameworks"]}
target=add("target","PBXNativeTarget",buildConfigurationList=config_list("target-config",target_settings),buildPhases=[sources,frameworks,resources],
           buildRules=[],dependencies=[],name="MangaShelf",packageProductDependencies=[dependency],productName="MangaShelf",productReference=product,
           productType="com.apple.product-type.application")
targets=[target]
ui_target=None
if arguments.ui_tests:
    ui_source_builds=[]
    for path in sorted((ROOT/"iOS/MangaShelfUISnapshots").glob("*.swift")):
        ref_id=add("ui-file:"+path.name,"PBXFileReference",lastKnownFileType="sourcecode.swift",
                   path="MangaShelfUISnapshots/"+path.name,sourceTree="<group>")
        objects[group]["children"].insert(-1,ref_id)
        ui_source_builds.append(add("ui-build:"+path.name,"PBXBuildFile",fileRef=ref_id))
    if not ui_source_builds:
        parser.error("UI screenshot test sources are missing")
    ui_product=add("ui-product","PBXFileReference",explicitFileType="wrapper.cfbundle",includeInIndex="0",
                   path="MangaShelfUISnapshots.xctest",sourceTree="BUILT_PRODUCTS_DIR")
    objects[products]["children"].append(ui_product)
    ui_proxy=add("ui-proxy","PBXContainerItemProxy",containerPortal=identifier("project"),proxyType="1",
                 remoteGlobalIDString=target,remoteInfo="MangaShelf")
    ui_dependency=add("ui-dependency","PBXTargetDependency",target=target,targetProxy=ui_proxy)
    ui_sources=add("ui-sources","PBXSourcesBuildPhase",buildActionMask="2147483647",files=ui_source_builds,
                   runOnlyForDeploymentPostprocessing="0")
    ui_frameworks=add("ui-frameworks","PBXFrameworksBuildPhase",buildActionMask="2147483647",files=[],
                      runOnlyForDeploymentPostprocessing="0")
    ui_resources=add("ui-resources","PBXResourcesBuildPhase",buildActionMask="2147483647",files=[],
                    runOnlyForDeploymentPostprocessing="0")
    ui_settings={"PRODUCT_BUNDLE_IDENTIFIER":"app.mangashelf.reader.uisnapshots","PRODUCT_NAME":"$(TARGET_NAME)",
                 "GENERATE_INFOPLIST_FILE":"YES","TARGETED_DEVICE_FAMILY":"1,2","CODE_SIGN_STYLE":"Automatic",
                 "SWIFT_VERSION":"5.0","SWIFT_STRICT_CONCURRENCY":"targeted","SUPPORTED_PLATFORMS":"iphonesimulator",
                 "TEST_TARGET_NAME":"MangaShelf","LD_RUNPATH_SEARCH_PATHS":["$(inherited)","@executable_path/Frameworks","@loader_path/Frameworks"]}
    ui_target=add("ui-target","PBXNativeTarget",buildConfigurationList=config_list("ui-target-config",ui_settings),
                  buildPhases=[ui_sources,ui_frameworks,ui_resources],buildRules=[],dependencies=[ui_dependency],
                  name="MangaShelfUISnapshots",productName="MangaShelfUISnapshots",productReference=ui_product,
                  productType="com.apple.product-type.bundle.ui-testing")
    targets.append(ui_target)
project=add("project","PBXProject",attributes={"LastUpgradeCheck":"1500","BuildIndependentTargetsInParallel":"YES"},
            buildConfigurationList=config_list("project-config",base),compatibilityVersion="Xcode 14.0",developmentRegion="en",
            hasScannedForEncodings="0",knownRegions=["ar","en","Base"],mainGroup=group,packageReferences=[package],productRefGroup=products,
            projectDirPath="",projectRoot="",targets=targets)
if ui_target:
    objects[project]["attributes"]["TargetAttributes"]={ui_target:{"CreatedOnToolsVersion":"26.0","TestTargetID":target}}
document={"archiveVersion":"1","classes":{},"objectVersion":"56","objects":objects,"rootObject":project}
def serialize(value, level=0):
    indent="\t"*level
    if isinstance(value,dict):return "{\n"+"".join(indent+"\t"+json.dumps(k)+" = "+serialize(v,level+1)+";\n" for k,v in value.items())+indent+"}"
    if isinstance(value,list):return "("+", ".join(serialize(v,level) for v in value)+("," if value else "")+")"
    return json.dumps(value,ensure_ascii=False)
PROJECT.mkdir(parents=True,exist_ok=True)
(PROJECT/"project.pbxproj").write_text("// !$*UTF8*$!\n"+serialize(document)+"\n")
scheme=ET.Element("Scheme",LastUpgradeVersion="1500",version="1.7")
build=ET.SubElement(scheme,"BuildAction",parallelizeBuildables="YES",buildImplicitDependencies="YES")
entries=ET.SubElement(build,"BuildActionEntries")
entry=ET.SubElement(entries,"BuildActionEntry",buildForTesting="YES",buildForRunning="YES",buildForProfiling="YES",buildForArchiving="YES",buildForAnalyzing="YES")
def ref(parent, blueprint=target, name="MangaShelf", product_name="MangaShelf.app"):
    ET.SubElement(parent,"BuildableReference",BuildableIdentifier="primary",BlueprintIdentifier=blueprint,
                  BuildableName=product_name,BlueprintName=name,ReferencedContainer="container:"+PROJECT.name)
ref(entry)
if ui_target:
    ui_entry=ET.SubElement(entries,"BuildActionEntry",buildForTesting="YES",buildForRunning="NO",
                          buildForProfiling="NO",buildForArchiving="NO",buildForAnalyzing="YES")
    ref(ui_entry,ui_target,"MangaShelfUISnapshots","MangaShelfUISnapshots.xctest")
    test=ET.SubElement(scheme,"TestAction",buildConfiguration="Debug",
                       selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                       selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB",shouldUseLaunchSchemeArgsEnv="YES")
    testables=ET.SubElement(test,"Testables")
    testable=ET.SubElement(testables,"TestableReference",skipped="NO",parallelizable="NO")
    ref(testable,ui_target,"MangaShelfUISnapshots","MangaShelfUISnapshots.xctest")
launch=ET.SubElement(scheme,"LaunchAction",buildConfiguration="Debug",selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB",launchStyle="0",useCustomWorkingDirectory="NO",ignoresPersistentStateOnLaunch="NO",debugDocumentVersioning="YES",allowLocationSimulation="YES")
ref(ET.SubElement(launch,"BuildableProductRunnable",runnableDebuggingMode="0"))
ET.SubElement(scheme,"AnalyzeAction",buildConfiguration="Debug")
ET.SubElement(scheme,"ArchiveAction",buildConfiguration="Release",revealArchiveInOrganizer="YES")
scheme_dir=PROJECT/"xcshareddata/xcschemes";scheme_dir.mkdir(parents=True,exist_ok=True)
scheme_name="MangaShelfUI.xcscheme" if arguments.ui_tests else "MangaShelf.xcscheme"
ET.indent(scheme);ET.ElementTree(scheme).write(scheme_dir/scheme_name,encoding="utf-8",xml_declaration=True)
print("Generated",PROJECT)
