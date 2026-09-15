#!/usr/bin/env python3
"""Deterministically emit a dependency-free Xcode app project using the local Swift package."""
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT/"iOS/MangaShelf.xcodeproj"
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
project=add("project","PBXProject",attributes={"LastUpgradeCheck":"1500","BuildIndependentTargetsInParallel":"YES"},
            buildConfigurationList=config_list("project-config",base),compatibilityVersion="Xcode 14.0",developmentRegion="en",
            hasScannedForEncodings="0",knownRegions=["ar","en","Base"],mainGroup=group,packageReferences=[package],productRefGroup=products,
            projectDirPath="",projectRoot="",targets=[target])
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
def ref(parent):ET.SubElement(parent,"BuildableReference",BuildableIdentifier="primary",BlueprintIdentifier=target,BuildableName="MangaShelf.app",BlueprintName="MangaShelf",ReferencedContainer="container:MangaShelf.xcodeproj")
ref(entry)
launch=ET.SubElement(scheme,"LaunchAction",buildConfiguration="Debug",selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB",launchStyle="0",useCustomWorkingDirectory="NO",ignoresPersistentStateOnLaunch="NO",debugDocumentVersioning="YES",allowLocationSimulation="YES")
ref(ET.SubElement(launch,"BuildableProductRunnable",runnableDebuggingMode="0"))
ET.SubElement(scheme,"AnalyzeAction",buildConfiguration="Debug")
ET.SubElement(scheme,"ArchiveAction",buildConfiguration="Release",revealArchiveInOrganizer="YES")
scheme_dir=PROJECT/"xcshareddata/xcschemes";scheme_dir.mkdir(parents=True,exist_ok=True)
ET.indent(scheme);ET.ElementTree(scheme).write(scheme_dir/"MangaShelf.xcscheme",encoding="utf-8",xml_declaration=True)
print("Generated",PROJECT)
