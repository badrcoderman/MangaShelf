// ABI definitions missing from the bsd_zero port at OpenJDK Mobile commit
// c1ed06aaef34c8dccf71e236d1ffa20918a77cfb. The matching declarations are in
// src/hotspot/share/runtime/os.hpp and THREAD_LOCAL is __thread in
// src/hotspot/share/utilities/globalDefinitions_gcc.hpp.
//
// Only the interpreter-only Zero link probe may use these definitions. They
// do not enable JIT or establish that the VM starts on an iOS device.

#if defined(__APPLE__) && defined(__aarch64__)

#if !defined(MSL_OPENJDK_ZERO) || MSL_OPENJDK_ZERO != 1
#error "The iOS W^X compatibility definitions require the pinned Zero runtime"
#endif

#if defined(MSL_OPENJDK_ZERO_SOURCE)
// The source build includes the full upstream declaration, avoiding any ABI
// reconstruction. Standalone mode below exists for older static-only evidence.
#include "runtime/os.hpp"
#else
enum WXMode {
    WXWrite = 0,
    WXExec = 1,
    WXArmedForWrite = 2,
};

// This translation unit supplies the static-member ABI only. It must not
// construct, derive from, take sizeof, or pass an os object across this shim.
class os {
public:
    static __thread bool _jit_exec_enabled;
    static void thread_wx_enable_write_impl();
};
#endif

WXMode DefaultWXWriteMode = WXWrite;
__thread bool os::_jit_exec_enabled = false;

void os::thread_wx_enable_write_impl() {
    // Zero never emits executable code. Keep the TLS state in write mode.
    _jit_exec_enabled = false;
}

#endif
