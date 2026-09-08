#!/usr/bin/env python3
"""
生成 Silkway.xcodeproj 的 project.pbxproj（OpenStep plist 格式）。

本版本放弃 PBXFileSystemSynchronizedRootGroup，改用显式 PBXFileReference。
原因：该新特性在模板中无实例，手写格式风险极高，迭代成本远超收益。
等源文件稳定后，可在 Xcode UI 中一键迁移为 Synchronized Group。

约束：
- macOS App，最低 macOS 14.0。
- 关闭 App Sandbox。
- 开启 Hardened Runtime。
- LSUIElement = YES。
- 自动签名、无 Team。
"""
import hashlib
import os
import plistlib
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJ_DIR = os.path.join(ROOT, "Silkway.xcodeproj")


def uid(seed: str) -> str:
    """稳定 UUID。"""
    h = hashlib.md5(seed.encode("utf-8")).hexdigest().upper()
    return h[:8] + h[8:16] + h[16:24]


def new_uid() -> str:
    return uuid.uuid4().hex.upper()[:24]


SOURCE_REFS: list[tuple[str, str]] = []


def collect_sources():
    global SOURCE_REFS
    SOURCE_REFS = []
    base = os.path.join(ROOT, "Silkway")
    for root, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if d not in {"Resources"}]
        for f in files:
            if f.endswith(".swift"):
                rel = os.path.relpath(os.path.join(root, f), ROOT)
                # Xcode 里显示的文件名
                SOURCE_REFS.append((rel, f))


def write_info_plist():
    path = os.path.join(ROOT, "Silkway", "Resources", "Info.plist")
    if os.path.exists(path):
        return
    plist = {
        "CFBundleDevelopmentRegion": "zh-CN",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSApplicationCategoryType": "public.app-category.utilities",
        "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
        "LSUIElement": True,
        "NSPrincipalClass": "NSApplication",
    }
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        plistlib.dump(plist, f)


def write_app_swift():
    path = os.path.join(ROOT, "Silkway", "App", "SilkwayApp.swift")
    if os.path.exists(path):
        return
    content = '''import SwiftUI

// 占位主程序。后续由任务 1 扩展为完整 MenuBarExtra + Settings。
@main
struct SilkwayApp: App {
    var body: some Scene {
        MenuBarExtra("Silkway", systemImage: "globe.asia.australia") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    var body: some View {
        Text("Silkway 项目骨架已就绪")
            .padding()
    }
}
'''
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def build_settings(debug: bool) -> dict:
    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_STYLE": "Automatic",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "66N6G2C27H",
        "ENABLE_APP_SANDBOX": "NO",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Silkway/Resources/Info.plist",
        "INFOPLIST_KEY_LSUIElement": "YES",
        "INFOPLIST_KEY_NSHumanReadableCopyright": "",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
        "MARKETING_VERSION": "1.0.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.silkway.app",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "6.0",
        "TARGETED_DEVICE_FAMILY": "6",
    }
    if debug:
        return {**common, **{
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
        }}
    else:
        return {**common, **{
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "ENABLE_NS_ASSERTIONS": "NO",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "SWIFT_OPTIMIZATION_LEVEL": "-O",
        }}


def render_value(v, indent=0) -> str:
    """把 Python 对象渲染为 OpenStep plist 格式。"""
    tab = "\t" * indent
    if isinstance(v, bool):
        return "YES" if v else "NO"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        # 是否需要引号
        if not v:
            return '""'
        safe = all(c.isalnum() or c in "._-:/" for c in v)
        if safe and not v[0].isdigit():
            return v
        return '"' + v.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'
    if isinstance(v, list) or isinstance(v, tuple):
        if not v:
            return "()"
        lines = ["(", "\n"]
        for item in v:
            lines.append(f"\t{render_value(item, indent + 1)},\n")
        lines.append(")")
        return "".join(lines)
    if isinstance(v, dict):
        if not v:
            return "{}"
        lines = ["{", "\n"]
        for k, val in v.items():
            lines.append(f"\t{k} = {render_value(val, indent + 1)};\n")
        lines.append("}")
        return "".join(lines)
    raise ValueError(f"unsupported {type(v)}")


def write_project():
    os.makedirs(PROJ_DIR, exist_ok=True)

    # 主 group
    main_group_id = uid("mainGroup")
    products_group_id = uid("productsGroup")
    silkway_group_id = uid("silkwayGroup")
    products_ref_id = uid("Silkway.app")
    project_id = uid("project")
    target_id = uid("Silkway.target")
    target_config_list_id = uid("Silkway.configList")

    debug_config_id = uid("Debug.config")
    release_config_id = uid("Release.config")
    project_config_list_id = uid("project.configList")
    project_debug_id = uid("Project.debug")
    project_release_id = uid("Project.release")

    frameworks_phase_id = uid("frameworksPhase")
    sources_phase_id = uid("sourcesPhase")
    resources_phase_id = uid("resourcesPhase")

    info_plist_ref_id = uid("Info.plist.ref")
    assets_ref_id = uid("Assets.xcassets.ref")

    objects: dict[str, dict] = {}

    # PBXFileReference for Info.plist / Assets.xcassets / Product
    objects[info_plist_ref_id] = {
        "isa": "PBXFileReference",
        "lastKnownFileType": "text.plist.xml",
        "path": "Info.plist",
        "sourceTree": "<group>",
    }
    objects[assets_ref_id] = {
        "isa": "PBXFileReference",
        "lastKnownFileType": "folder.assetcatalog",
        "path": "Assets.xcassets",
        "sourceTree": "<group>",
    }

    # 菜单栏图标 PDF：连/断两态，template image（纯黑+alpha，已在 Design/assets 验证）
    menubar_pdf_refs = {}
    for state, filename in [("connected", "Silkway-menubar-connected.pdf"),
                            ("disconnected", "Silkway-menubar-disconnected.pdf")]:
        ref_id = uid(f"menubar.{state}.ref")
        build_id = uid(f"menubar.{state}.build")
        menubar_pdf_refs[ref_id] = build_id
        objects[ref_id] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": "image.pdf",
            "path": filename,
            "sourceTree": "<group>",
        }
        objects[build_id] = {
            "isa": "PBXBuildFile",
            "fileRef": ref_id,
        }
    objects[products_ref_id] = {
        "isa": "PBXFileReference",
        "explicitFileType": "wrapper.application",
        "includeInIndex": 0,
        "path": "Silkway.app",
        "sourceTree": "BUILT_PRODUCTS_DIR",
    }

    # Silkway 主 group（必须先创建，因为 mainGroup 要引用它）
    objects[silkway_group_id] = {
        "isa": "PBXGroup",
        "children": (),
        "name": "Silkway",
        "path": "Silkway",
        "sourceTree": "<group>",
    }

    # sing-box 二进制引用（必须在 Resources group 之前创建，group children 要用）
    singbox_ref_id = uid("singbox.ref")
    singbox_build_id = uid("singbox.build")
    objects[singbox_ref_id] = {
        "isa": "PBXFileReference",
        "lastKnownFileType": "compiled.mach-o.executable",
        "path": "sing-box",
        "sourceTree": "<group>",
    }
    objects[singbox_build_id] = {
        "isa": "PBXBuildFile",
        "fileRef": singbox_ref_id,
    }

    # LaunchDaemons：特权 daemon 的 plist 必须落在 Contents/Library/LaunchDaemons/，
    # 这不是普通资源，需要 Copy Files 构建阶段（dstSubfolderSpec=1 表示 Wrapper 即 Contents/）
    daemon_plist_ref_id = uid("daemonplist.ref")
    daemon_plist_build_id = uid("daemonplist.build")
    objects[daemon_plist_ref_id] = {
        "isa": "PBXFileReference",
        "lastKnownFileType": "text.plist.xml",
        "path": "LaunchDaemons/com.silkway.singbox.plist",
        "sourceTree": "<group>",
    }
    objects[daemon_plist_build_id] = {
        "isa": "PBXBuildFile",
        "fileRef": daemon_plist_ref_id,
    }
    launchdaemons_phase_id = uid("launchDaemonsPhase")
    objects[launchdaemons_phase_id] = {
        "isa": "PBXCopyFilesBuildPhase",
        "buildActionMask": 2147483647,
        "dstPath": "Contents/Library/LaunchDaemons",
        "dstSubfolderSpec": 1,
        "files": (daemon_plist_build_id,),
        "runOnlyForDeploymentPostprocessing": 0,
        "name": "Copy LaunchDaemons",
    }

    # Group for Silkway/Resources
    resources_group_id = uid("Resources.group")
    objects[resources_group_id] = {
        "isa": "PBXGroup",
        "children": [assets_ref_id, info_plist_ref_id, *menubar_pdf_refs.keys(), singbox_ref_id, daemon_plist_ref_id],
        "path": "Resources",
        "sourceTree": "<group>",
    }

    # Source files
    # Source files：全部直接挂到 Silkway group 下，避免嵌套 group 的复杂引用关系
    source_file_refs: list[str] = []
    source_build_files: list[str] = []

    for rel, name in SOURCE_REFS:
        file_ref_id = new_uid()
        build_file_id = new_uid()
        source_file_refs.append(file_ref_id)
        source_build_files.append(build_file_id)
        objects[file_ref_id] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": "sourcecode.swift",
            "path": os.path.relpath(os.path.join(os.path.dirname(rel), name), "Silkway").replace(os.sep, "/"),
            "sourceTree": "<group>",
        }
        objects[build_file_id] = {
            "isa": "PBXBuildFile",
            "fileRef": file_ref_id,
        }

    objects[silkway_group_id]["children"] = tuple([resources_group_id] + source_file_refs)

    # Groups
    objects[main_group_id] = {
        "isa": "PBXGroup",
        "children": (silkway_group_id, products_group_id),
        "sourceTree": "<group>",
    }
    objects[products_group_id] = {
        "isa": "PBXGroup",
        "children": (products_ref_id,),
        "name": "Products",
        "sourceTree": "<group>",
    }

    # Build phases
    objects[frameworks_phase_id] = {
        "isa": "PBXFrameworksBuildPhase",
        "buildActionMask": 2147483647,
        "files": (),
        "runOnlyForDeploymentPostprocessing": 0,
    }
    objects[sources_phase_id] = {
        "isa": "PBXSourcesBuildPhase",
        "buildActionMask": 2147483647,
        "files": tuple(source_build_files),
        "runOnlyForDeploymentPostprocessing": 0,
    }
    # sing-box 二进制嵌入 bundle：普通模式从 Contents/Resources/sing-box 加载
    objects[resources_phase_id] = {
        "isa": "PBXResourcesBuildPhase",
        "buildActionMask": 2147483647,
        "files": tuple([uid("Assets.build"), *menubar_pdf_refs.values(), singbox_build_id]),
        "runOnlyForDeploymentPostprocessing": 0,
    }
    objects[uid("Assets.build")] = {
        "isa": "PBXBuildFile",
        "fileRef": assets_ref_id,
    }

    # 构建后用同一张开发证书重签嵌入的 sing-box。
    # SMAppService daemon 注册要求所有可执行文件同 Team ID 签名，
    # 官方下载的 sing-box 是 adhoc 签名，不满足要求。
    resign_phase_id = uid("resignPhase")
    objects[resign_phase_id] = {
        "isa": "PBXShellScriptBuildPhase",
        "buildActionMask": 2147483647,
        "files": (),
        "inputPaths": (),
        "outputPaths": (),
        "runOnlyForDeploymentPostprocessing": 0,
        "shellPath": "/bin/sh",
        "shellScript": """if [ -n "$EXPANDED_CODE_SIGN_IDENTITY" ]; then
  codesign --force --options runtime --timestamp=none \
    --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    "$BUILT_PRODUCTS_DIR/Silkway.app/Contents/Resources/sing-box"
fi
""",
        "name": "Re-sign sing-box",
    }

    # Target
    objects[target_id] = {
        "isa": "PBXNativeTarget",
        "buildConfigurationList": target_config_list_id,
        "buildPhases": (frameworks_phase_id, sources_phase_id, resources_phase_id, launchdaemons_phase_id, resign_phase_id),
        "buildRules": (),
        "dependencies": (),
        "name": "Silkway",
        "productName": "Silkway",
        "productReference": products_ref_id,
        "productType": "com.apple.product-type.application",
    }

    # Build configs
    objects[debug_config_id] = {
        "isa": "XCBuildConfiguration",
        "buildSettings": build_settings(debug=True),
        "name": "Debug",
    }
    objects[release_config_id] = {
        "isa": "XCBuildConfiguration",
        "buildSettings": build_settings(debug=False),
        "name": "Release",
    }
    objects[target_config_list_id] = {
        "isa": "XCConfigurationList",
        "buildConfigurations": (debug_config_id, release_config_id),
        "defaultConfigurationIsVisible": 0,
        "defaultConfigurationName": "Debug",
    }

    objects[project_debug_id] = {
        "isa": "XCBuildConfiguration",
        "buildSettings": {
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "CLANG_ANALYZER_NONNULL": "YES",
            "CLANG_CXX_LANGUAGE_STANDARD": "gnu++17",
            "CLANG_ENABLE_MODULES": "YES",
            "CLANG_ENABLE_OBJC_ARC": "YES",
            "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
            "CLANG_WARN_BOOL_CONVERSION": "YES",
            "CLANG_WARN_COMMA": "YES",
            "CLANG_WARN_CONSTANT_CONVERSION": "YES",
            "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
            "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
            "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
            "CLANG_WARN_EMPTY_BODY": "YES",
            "CLANG_WARN_ENUM_CONVERSION": "YES",
            "CLANG_WARN_INFINITE_RECURSION": "YES",
            "CLANG_WARN_INT_CONVERSION": "YES",
            "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
            "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
            "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
            "CLANG_WARN_STRICT_PROTOTYPES": "YES",
            "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
            "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
            "CLANG_WARN_UNREACHABLE_CODE": "YES",
            "COPY_PHASE_STRIP": "NO",
            "DEAD_CODE_STRIPPING": "YES",
            "ENABLE_STRICT_OBJC_MSGSEND": "YES",
            "GCC_C_LANGUAGE_STANDARD": "gnu17",
            "GCC_NO_COMMON_BLOCKS": "YES",
            "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
            "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
            "GCC_WARN_UNDECLARED_SELECTOR": "YES",
            "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
            "GCC_WARN_UNUSED_FUNCTION": "YES",
            "GCC_WARN_UNUSED_VARIABLE": "YES",
            "MACOSX_DEPLOYMENT_TARGET": "14.0",
            "MTL_FAST_MATH": "YES",
            "ONLY_ACTIVE_ARCH": "YES",
            "SDKROOT": "macosx",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        },
        "name": "Debug",
    }
    objects[project_release_id] = {
        "isa": "XCBuildConfiguration",
        "buildSettings": {
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "CLANG_ANALYZER_NONNULL": "YES",
            "CLANG_CXX_LANGUAGE_STANDARD": "gnu++17",
            "CLANG_ENABLE_MODULES": "YES",
            "CLANG_ENABLE_OBJC_ARC": "YES",
            "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
            "CLANG_WARN_BOOL_CONVERSION": "YES",
            "CLANG_WARN_COMMA": "YES",
            "CLANG_WARN_CONSTANT_CONVERSION": "YES",
            "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
            "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
            "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
            "CLANG_WARN_EMPTY_BODY": "YES",
            "CLANG_WARN_ENUM_CONVERSION": "YES",
            "CLANG_WARN_INFINITE_RECURSION": "YES",
            "CLANG_WARN_INT_CONVERSION": "YES",
            "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
            "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
            "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
            "CLANG_WARN_STRICT_PROTOTYPES": "YES",
            "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
            "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
            "CLANG_WARN_UNREACHABLE_CODE": "YES",
            "COPY_PHASE_STRIP": "NO",
            "DEAD_CODE_STRIPPING": "YES",
            "ENABLE_NS_ASSERTIONS": "NO",
            "ENABLE_STRICT_OBJC_MSGSEND": "YES",
            "GCC_C_LANGUAGE_STANDARD": "gnu17",
            "GCC_NO_COMMON_BLOCKS": "YES",
            "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
            "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
            "GCC_WARN_UNDECLARED_SELECTOR": "YES",
            "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
            "GCC_WARN_UNUSED_FUNCTION": "YES",
            "GCC_WARN_UNUSED_VARIABLE": "YES",
            "MACOSX_DEPLOYMENT_TARGET": "14.0",
            "MTL_FAST_MATH": "YES",
            "SDKROOT": "macosx",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "SWIFT_OPTIMIZATION_LEVEL": "-O",
        },
        "name": "Release",
    }
    objects[project_config_list_id] = {
        "isa": "XCConfigurationList",
        "buildConfigurations": (project_debug_id, project_release_id),
        "defaultConfigurationIsVisible": 0,
        "defaultConfigurationName": "Debug",
    }

    # PBXProject
    objects[project_id] = {
        "isa": "PBXProject",
        "attributes": {
            "BuildIndependentTargetsInParallel": 1,
            "LastSwiftUpdateCheck": 2700,
            "LastUpgradeCheck": 2700,
            "TargetAttributes": {
                target_id: {
                    "CreatedOnToolsVersion": "27.0",
                }
            },
        },
        "buildConfigurationList": project_config_list_id,
        "compatibilityVersion": "Xcode 15.0",
        "developmentRegion": "zh-CN",
        "hasScannedForEncodings": 0,
        "knownRegions": ("zh-CN", "en"),
        "mainGroup": main_group_id,
        "minimizedProjectReferenceProxies": 1,
        "preferredProjectObjectVersion": 77,
        "productRefGroup": products_group_id,
        "projectDirPath": "",
        "projectRoot": "",
        "targets": (target_id,),
    }

    # 写入
    project = {
        "archiveVersion": 1,
        "classes": {},
        "objectVersion": 77,
        "objects": objects,
        "rootObject": project_id,
    }

    pbxproj = os.path.join(PROJ_DIR, "project.pbxproj")
    with open(pbxproj, "w", encoding="utf-8") as f:
        f.write("// !$*UTF8*$!\n")
        f.write(render_value(project))
        f.write("\n")

    # workspace
    workspace_dir = os.path.join(PROJ_DIR, "project.xcworkspace")
    os.makedirs(workspace_dir, exist_ok=True)
    contents = '<?xml version="1.0" encoding="UTF-8"?>\n' \
               '<Workspace version="1.0">\n' \
               '   <FileRef location="self:">\n' \
               '   </FileRef>\n' \
               '</Workspace>\n'
    with open(os.path.join(workspace_dir, "contents.xcworkspacedata"), "w") as f:
        f.write(contents)

    # 资产目录：AppIcon 若已接入真实图标（Contents.json 含 filename 字段）则不覆盖，
    # 否则写占位。重新生成 pbxproj 绝不能抹掉已接入的图标。
    assets_dir = os.path.join(ROOT, "Silkway", "Resources", "Assets.xcassets")
    appicon_dir = os.path.join(assets_dir, "AppIcon.appiconset")
    os.makedirs(appicon_dir, exist_ok=True)
    contents_path = os.path.join(appicon_dir, "Contents.json")
    needs_placeholder = True
    if os.path.exists(contents_path):
        with open(contents_path) as f:
            # 占位文件没有 filename 字段；真实图标有
            needs_placeholder = '"filename"' not in f.read()
    if needs_placeholder:
        with open(contents_path, "w") as f:
            f.write('{\n  "images" : [\n    {\n      "idiom" : "mac",\n      "size" : "16x16",\n      "scale" : "1x"\n    }\n  ],\n  "info" : {\n    "version" : 1,\n    "author" : "xcode"\n  }\n}\n')

    print(f"已生成 {pbxproj}")


if __name__ == "__main__":
    write_app_swift()
    write_info_plist()
    collect_sources()
    write_project()
