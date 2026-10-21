#!/usr/bin/env python3
"""Evaluate the reviewed OpenJDK library flag branches; does not build/run a VM."""
import hashlib
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


def make_flag(source, platform, macro, argument=''):
    start = source.index("ifeq ($(call isCompiler, gcc), true)")
    end = source.index("\nendif", start) + len("\nendif")
    # Same boolean semantics as OpenJDK's compiler/OS predicates. Only evaluate
    # the selected definition, not the full source tree's make targets.
    makefile = """isCompiler = $(if $(filter $1,clang),true,false)
isTargetOs = $(if $(filter $1,$(PLATFORM)),true,false)
DOLLAR = $$
""" + source[start:end] + '\n$(info $(call ' + macro + ',' + argument + '))\nall:\n\t@:\n'
    return subprocess.check_output(["make", "--no-print-directory", "-s", "-f", "-", f"PLATFORM={platform}"],
                                   input=makefile, text=True).strip()


def stack_flags(source, platform):
    start = source.index('  if (test "x$TOOLCHAIN_TYPE" = xgcc || test "x$TOOLCHAIN_TYPE" = xclang)')
    end = source.index('\n  # Setup OS-dependent LDFLAGS', start)
    script = 'TOOLCHAIN_TYPE=clang\nOPENJDK_TARGET_OS="$1"\nHAS_NOEXECSTACK=1\nBASIC_LDFLAGS=""\n'
    script += source[start:end] + '\nprintf "%s" "$BASIC_LDFLAGS"\n'
    return subprocess.check_output(['bash', '-eu', '-c', script, 'stack-flag-check', platform], text=True).strip()


def libjava_link_flags(source, flag_source, platform):
    # Evaluate the actual libjava call with a named-argument capture stub, then
    # the pinned upstream SetupLinkerFlags body. No compile/link targets run.
    start = source.index('$(eval $(call SetupJdkLibrary, BUILD_LIBJAVA,')
    end = source.index('\n))', start) + len('\n))')
    selector = flag_source.split('define SetupLinkerFlags\n', 1)[1].split('\nendef', 1)[0]
    makefile = """OPENJDK_TARGET_OS_TYPE := unix
TOOLCHAIN_TYPE := clang
LIBDL := -ldl
LIBM := -lm
isTargetOs = $(if $(filter $1,$(OPENJDK_TARGET_OS)),true,false)
PARAM_NUMBERS := """ + ' '.join(str(n) for n in range(2, 33)) + """
SetupJdkLibrary = $(foreach arg,$(PARAM_NUMBERS),$(if $(strip $($(arg))),$(eval $(strip $1)_$(strip $($(arg))))))
define SetupLinkerFlags
""" + selector + "\nendef\n" + source[start:end] + """
$(eval $(call SetupLinkerFlags,BUILD_LIBJAVA))
$(info $(strip $(BUILD_LIBJAVA_LIBS) $(BUILD_LIBJAVA_EXTRA_LIBS)))
all:
	@:
"""
    return subprocess.check_output(
        ['make', '--no-print-directory', '-s', '-f', '-', f'OPENJDK_TARGET_OS={platform}'],
        input=makefile, text=True).strip()


def libjli_exclusions(source, platform):
    assignment = source.index('  LIBJLI_EXCLUDE_FILES += java_md.c')
    start = source.rindex('\nifeq (', 0, assignment) + 1
    end = source.index('\nendif', assignment) + len('\nendif')
    makefile = 'isTargetOs = $(if $(filter $1,$(PLATFORM)),true,false)\n'
    makefile += source[start:end] + '\n$(info $(strip $(LIBJLI_EXCLUDE_FILES)))\nall:\n\t@:\n'
    return subprocess.check_output(
        ['make', '--no-print-directory', '-s', '-f', '-', f'PLATFORM={platform}'],
        input=makefile, text=True).strip().split()


def verify(root):
    toolchain = (root / "make/autoconf/toolchain.m4").read_text()
    flags = (root / "make/autoconf/flags-cflags.m4").read_text()
    linker = (root / "make/common/native/Link.gmk").read_text()
    native = (root / "make/common/JdkNativeCompilation.gmk").read_text()
    ldflags = (root / "make/autoconf/flags-ldflags.m4").read_text()
    core = (root / 'make/modules/java.base/lib/CoreLibraries.gmk').read_text()
    flag_bytes = (root / 'make/common/native/Flags.gmk').read_bytes()
    if hashlib.sha256(flag_bytes).hexdigest() != '29265e2886f737e9fcf0ff36d6c5d43490a6bae67117fe96492c699f2ec99f33':
        raise ValueError('Unexpected upstream native/Flags.gmk; refusing Make evaluation')
    flag_source = flag_bytes.decode()
    results = []
    for platform in ["ios", "macosx", "linux"]:
        suffix = shell_macro(toolchain, "TOOLCHAIN_SETUP_FILENAME_PATTERNS", platform)
        shared_flags = shell_macro(flags, "FLAGS_SETUP_SHARED_LIBS", platform)
        name_flags = make_flag(linker, platform, 'SetSharedLibraryName', 'libprobe.dylib')
        library_origin = make_flag(native, platform, 'SetSharedLibraryOrigin')
        executable_origin = make_flag(native, platform, 'SetExecutableOrigin')
        stack = stack_flags(ldflags, platform)
        java_flags = libjava_link_flags(core, flag_source, platform)
        jli_excluded = libjli_exclusions(core, platform)
        expected_java_flags = {
            'ios': '-framework CoreFoundation',
            'macosx': '-framework CoreFoundation -framework Foundation -framework SystemConfiguration',
            'linux': '-ldl',
        }
        assert java_flags == expected_java_flags[platform], (platform, java_flags)
        apple = platform in ["ios", "macosx"]
        assert jli_excluded == (['java_md.c'] if apple else []), (platform, jli_excluded)
        assert suffix == (".dylib" if apple else ".so"), (platform, suffix)
        assert ("-dynamiclib" in shared_flags) == apple, (platform, shared_flags)
        assert name_flags == ("-Wl,-install_name,@rpath/libprobe.dylib" if apple
                              else "-Wl,-soname=libprobe.dylib"), (platform, name_flags)
        if apple:
            assert library_origin == executable_origin == '-Wl,-rpath,@loader_path/.', (platform, library_origin, executable_origin)
            assert stack == '', (platform, stack)
        else:
            assert '-Wl,-z,origin' in library_origin and 'ORIGIN' in executable_origin
            assert stack == '-Wl,-z,noexecstack', stack
        results.append({"platform": platform, "shared_suffix": suffix,
                        "shared_flags": shared_flags, "name_flags": name_flags,
                        "library_origin": library_origin, "executable_origin": executable_origin,
                        "stack_flags_with_probe_enabled": stack,
                        "libjava_platform_libraries": java_flags,
                        "libjli_excluded_files": jli_excluded})
    return {"flag_branches_verified": True, "vm_built": False, "vm_executed": False, "cases": results}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify-ios-jvm-source.py PATCHED_OPENJDK_ROOT")
    print(json.dumps(verify(Path(sys.argv[1])), indent=2))
