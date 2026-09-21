// Compatibility stubs for linking OpenJDK Zero static libraries on iOS arm64.
// Zero is an interpreter-only VM without JIT compilation, so W^X thread-state
// switching on Apple Silicon is a no-op.

#if defined(__APPLE__) && defined(__aarch64__)

class os {
public:
    static void thread_wx_enable_write_impl();
};

void os::thread_wx_enable_write_impl() {
    // No-op for iOS Zero interpreter runtime
}

#endif
