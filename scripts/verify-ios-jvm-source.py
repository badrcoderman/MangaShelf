#!/usr/bin/env python3
"""Evaluate the reviewed OpenJDK library flag branches; does not build/run a VM."""
import json
from pathlib import Path
import re
import subprocess
import sys


def shell_macro(source, name, platform):
    # These two pinned macros contain only platform conditionals/assignments.
    marker = f"AC_DEFUN([{name}],\n[\n"
    body = source.split(marker, 1)[1].split("\n])", 1)[0]
    body = re.sub(r"^\s*AC_SUBST\([^\n]*\)\s*$", "", body, flags=re.M)
    variable = "SHARED_LIBRARY_SUFFIX" if name == "TOOLCHAIN_SETUP_FILENAME_PATTERNS" else "SHARED_LIBRARY_FLAGS"
    script = 'TOOLCHAIN_TYPE=clang\nOPENJDK_TARGET_OS="$1"\n' + body
    script += '\nprintf "%s" "$' + variable + '"\n'
    return subprocess.check_output(["bash", "-eu", "-c", script, "source-flag-check", platform], text=True)


def link_name(source, platform):
    start = source.index("ifeq ($(call isCompiler, gcc), true)")
    end = source.index("\nendif", start) + len("\nendif")
    # Same boolean semantics as OpenJDK's compiler/OS predicates. Only evaluate
    # the selected definition, not the full source tree's make targets.
    makefile = """isCompiler = $(if $(filter $1,clang),true,false)
isTargetOs = $(if $(filter $1,$(PLATFORM)),true,false)
""" + source[start:end] + "\n$(info $(call SetSharedLibraryName,libprobe.dylib))\nall:\n\t@:\n"
    return subprocess.check_output(["make", "--no-print-directory", "-s", "-f", "-", f"PLATFORM={platform}"],
                                   input=makefile, text=True).strip()


def verify(root):
    toolchain = (root / "make/autoconf/toolchain.m4").read_text()
    flags = (root / "make/autoconf/flags-cflags.m4").read_text()
    linker = (root / "make/common/native/Link.gmk").read_text()
    results = []
    for platform in ["ios", "macosx", "linux"]:
        suffix = shell_macro(toolchain, "TOOLCHAIN_SETUP_FILENAME_PATTERNS", platform)
        shared_flags = shell_macro(flags, "FLAGS_SETUP_SHARED_LIBS", platform)
        name_flags = link_name(linker, platform)
        apple = platform in ["ios", "macosx"]
        assert suffix == (".dylib" if apple else ".so"), (platform, suffix)
        assert ("-dynamiclib" in shared_flags) == apple, (platform, shared_flags)
        assert name_flags == ("-Wl,-install_name,@rpath/libprobe.dylib" if apple
                              else "-Wl,-soname=libprobe.dylib"), (platform, name_flags)
        results.append({"platform": platform, "shared_suffix": suffix,
                        "shared_flags": shared_flags, "name_flags": name_flags})
    return {"flag_branches_verified": True, "vm_built": False, "vm_executed": False, "cases": results}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify-ios-jvm-source.py PATCHED_OPENJDK_ROOT")
    print(json.dumps(verify(Path(sys.argv[1])), indent=2))
