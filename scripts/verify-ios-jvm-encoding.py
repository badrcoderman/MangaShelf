#!/usr/bin/env python3
"""Run pinned OpenJDK native encoding initialization with host test stubs.

Linux compiles the entire public-source java_props_md.c. Other hosts compile
its actual codec branch and report that narrower scope. This does not build a
JVM or prove iOS ABI/device behavior.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


SOURCE_PATH = 'src/java.base/unix/native/libjava/java_props_md.c'
PRISTINE_SHA256 = '1c1a28595b3d4f49aec19c8c3eb145abb6592e3170cff6bbce48a3a134fe83a8'
PATCHED_SHA256 = 'dcd072f3c2f8e75327bee027a4b509842a6dd156f586712ed65ff7a0c9129c92'
HEADER_PINS = {
    'src/java.base/share/native/libjava/java_props.h':
        '99c135542d20fdbdf2fc201102976127ba468497a805bfc2c513dddf246be71a',
    'src/java.base/unix/native/libjava/locale_str.h':
        '9e86ec793b83ed0910bb5b6f83f070a771d8ab0f046f96ec57ae62ad701d4168',
}
ORIGINAL = b'#ifdef MACOSX\n    sprops.sun_jnu_encoding = "UTF-8";'
PATCHED = b'''#if defined(__IOS__)
    /* MangaShelf: iOS paths and application log streams use UTF-8, even in the C locale. */
    sprops.encoding = "UTF-8";
    sprops.sun_jnu_encoding = "UTF-8";
#elif defined(MACOSX)
    sprops.sun_jnu_encoding = "UTF-8";'''
FULL_NATIVE_PROPERTIES = sys.platform.startswith('linux')
SCOPE = (
    'Whole host native C with authored JNI/macOS platform stubs; no VM, '
    'iOS ABI, physical device, or extension execution proof'
    if FULL_NATIVE_PROPERTIES else
    'Actual pinned codec branch compiled as host C with seeded C-locale '
    'encoding/language; full native properties not compiled on this host; '
    'no VM, iOS ABI, physical device, or extension execution proof'
)

# JNI stubs fail if the tested function reaches a Java error path. The source
# performs its original locale parsing and property initialization in full.
JNI_STUB = r'''#ifndef MSL_TEST_JNI_UTIL_H
#define MSL_TEST_JNI_UTIL_H
#include <stdlib.h>
typedef void JNIEnv;
typedef void *jstring;
static inline void JNU_ThrowOutOfMemoryError(JNIEnv *env, const char *why) {
    (void)env; (void)why; abort();
}
static inline void JNU_ThrowByName(JNIEnv *env, const char *type, const char *why) {
    (void)env; (void)type; (void)why; abort();
}
#define JNU_CHECK_EXCEPTION_RETURN(env, value) do { (void)(env); } while (0)
static inline jstring JNU_NewStringPlatform(JNIEnv *env, const char *str) {
    (void)env; return (void *)str;
}
#endif
'''

# The macOS platform functions normally call OS services. These stubs provide
# the explicit C locale and unrelated OS metadata; the original whole C source
# still executes its MACOSX ParseLocale and filesystem-encoding branches.
MACOS_STUB = r'''#ifndef MSL_TEST_JAVA_PROPS_MACOSX_H
#define MSL_TEST_JAVA_PROPS_MACOSX_H
#include <locale.h>
#include <stdlib.h>
#include <string.h>
#include "java_props.h"
#ifndef _CS_DARWIN_USER_TEMP_DIR
#define _CS_DARWIN_USER_TEMP_DIR 32767
#endif
static inline char *setupMacOSXLocale(int category) {
    const char *value = setlocale(category, NULL);
    return value ? strdup(value) : NULL;
}
static inline void setOSNameAndVersion(java_props_t *props) {
    props->os_name = "Host encoding test";
    props->os_version = "test";
}
static inline void setUserHome(java_props_t *props) {
    props->user_home = "/test-home";
}
static inline void setProxyProperties(java_props_t *props) { (void)props; }
#endif
'''

DRIVER = r'''#include <stdio.h>
#include "java_props.h"
int main(void) {
    java_props_t *props = GetJavaProperties(NULL);
    if (!props || !props->encoding || !props->sun_jnu_encoding ||
        !props->format_language) return 1;
    printf("native=%s\njnu=%s\nlanguage=%s\n", props->encoding,
           props->sun_jnu_encoding, props->format_language);
    return 0;
}
'''

PLATFORM_DEFINES = {
    'ios': ['-U__linux__', '-UMACOSX', '-D_ALLBSD_SOURCE', '-D__IOS__'],
    'macosx': ['-U__linux__', '-U__IOS__', '-D_ALLBSD_SOURCE', '-DMACOSX'],
    'linux': ['-U__IOS__', '-UMACOSX', '-U_ALLBSD_SOURCE', '-D__linux__'],
    'bsd': ['-U__linux__', '-U__IOS__', '-UMACOSX', '-D_ALLBSD_SOURCE'],
}


def _inputs(root):
    root = Path(root)
    source = (root / SOURCE_PATH).read_bytes()
    digest = hashlib.sha256(source).hexdigest()
    if digest not in (PRISTINE_SHA256, PATCHED_SHA256):
        raise ValueError('Unexpected java_props_md.c; refusing native compilation')
    headers = {}
    for path, expected in HEADER_PINS.items():
        data = (root / path).read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f'Unexpected {path}; refusing native compilation')
        headers[Path(path).name] = data
    return source, digest, headers


def _properties(source, headers, platform):
    if platform not in PLATFORM_DEFINES:
        raise ValueError(f'Unsupported encoding macro case: {platform}')
    compiler = shutil.which('cc') or shutil.which('clang')
    if compiler is None:
        raise RuntimeError('A host C compiler is required for encoding validation')
    with tempfile.TemporaryDirectory(prefix='msl-native-encoding-') as directory:
        work = Path(directory)
        (work / 'java_props_md.c').write_bytes(source)
        for name, data in headers.items():
            (work / name).write_bytes(data)
        (work / 'jni_util.h').write_text(JNI_STUB)
        (work / 'java_props_macosx.h').write_text(MACOS_STUB)
        (work / 'main.c').write_text(DRIVER)
        executable = work / 'encoding-properties'
        if FULL_NATIVE_PROPERTIES:
            command = [compiler, '-std=gnu11', '-Werror', *PLATFORM_DEFINES[platform],
                       '-DARCHPROPNAME="aarch64"', '-I', str(work),
                       str(work / 'java_props_md.c'), str(work / 'main.c'),
                       '-o', str(executable)]
        else:
            # Darwin headers cannot be assumed compatible with synthetic Linux
            # defines. Compile the actual pinned encoding branch on this host;
            # keep the narrower scope visible in every returned report.
            marker = PATCHED if PATCHED in source else ORIGINAL
            start = source.index(marker)
            end = source.index(b'\n#endif', start) + len(b'\n#endif')
            definitions = '\n'.join(
                '#undef ' + flag[2:] if flag.startswith('-U') else
                '#define ' + flag[2:] + ' 1'
                for flag in PLATFORM_DEFINES[platform])
            branch_driver = ('#include <stdio.h>\n' + definitions + '''
int main(void) {
    struct { const char *encoding; const char *sun_jnu_encoding; }
        sprops = {"US-ASCII", NULL};
''' + source[start:end].decode('ascii') + r'''
    printf("native=%s\njnu=%s\nlanguage=en\n", sprops.encoding,
           sprops.sun_jnu_encoding);
    return 0;
}
''')
            (work / 'codec-branch.c').write_text(branch_driver)
            command = [compiler, '-std=gnu11', '-Werror',
                       str(work / 'codec-branch.c'), '-o', str(executable)]
        subprocess.run(command, check=True, capture_output=True, text=True, timeout=120)
        environment = os.environ.copy()
        environment.update({'LC_ALL': 'C', 'LANG': 'C'})
        result = subprocess.run([str(executable)], env=environment, check=True,
                                capture_output=True, text=True, timeout=10)
        properties = dict(line.split('=', 1) for line in result.stdout.splitlines())
        if set(properties) != {'native', 'jnu', 'language'} or result.stderr:
            raise AssertionError((platform, result.stdout, result.stderr))
        return properties


def encoding_properties(root, platform='ios', patched_required=False):
    """Compile pinned C and return native/jnu/language plus validation scope."""
    source, digest, headers = _inputs(root)
    if patched_required:
        assert digest == PATCHED_SHA256, 'iOS native encoding patch is missing'
    return {
        **_properties(source, headers, platform),
        'platform_macro_case': platform,
        'locale': 'C',
        'source_sha256': digest,
        'full_native_properties_checked': FULL_NATIVE_PROPERTIES,
        'scope': SCOPE,
    }


def verify_encoding(root):
    """Prove the C-locale regression and require the current iOS codec fix."""
    current, digest, headers = _inputs(root)
    if digest == PRISTINE_SHA256:
        pristine = current
        assert pristine.count(ORIGINAL) == 1
        patched = pristine.replace(ORIGINAL, PATCHED, 1)
    else:
        patched = current
        assert patched.count(PATCHED) == 1
        pristine = patched.replace(PATCHED, ORIGINAL, 1)
    # Both compiled variants must match the reviewed whole-file identities.
    assert hashlib.sha256(pristine).hexdigest() == PRISTINE_SHA256
    assert hashlib.sha256(patched).hexdigest() == PATCHED_SHA256
    matrix = []
    for platform in PLATFORM_DEFINES:
        before = _properties(pristine, headers, platform)
        after = _properties(patched, headers, platform)
        if platform == 'ios':
            assert before['native'] == before['jnu'] != 'UTF-8', before
            assert after['native'] == after['jnu'] == 'UTF-8', after
            assert before['language'] == after['language'], (before, after)
        else:
            assert before == after, (platform, before, after)
            if platform == 'macosx':
                assert before['jnu'] == 'UTF-8', before
                assert before['native'] != 'UTF-8', before
        matrix.append({'platform_macro_case': platform, 'locale': 'C',
                       'pristine': before, 'patched': after})
    assert digest == PATCHED_SHA256, 'iOS native encoding patch is missing'
    return {'scope': SCOPE, 'source_sha256': digest,
            'full_native_properties_checked': FULL_NATIVE_PROPERTIES,
            'header_sha256': HEADER_PINS, 'cases': matrix}


verify = verify_encoding


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source_root', type=Path)
    parser.add_argument('--properties', choices=PLATFORM_DEFINES,
                        help='Report the current source instead of requiring the fix')
    args = parser.parse_args()
    result = (encoding_properties(args.source_root, args.properties)
              if args.properties else verify_encoding(args.source_root))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
