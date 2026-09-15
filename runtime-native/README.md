# JNI runtime bridge

Project-owned C code; external JDK headers and VM library are build inputs, not copied from the IPA.

`ms_java_start` creates one process-lifetime VM using a supplied linked creation function. The host uses `JNI_CreateJavaVM`; another VM must expose a compatible invocation ABI that is checked against its own headers and build. The bridge does not assume that renaming an OpenJ9 symbol makes the VM compatible.

`ms_java_call_string2` attaches the calling thread when necessary, creates a local-reference frame, invokes a `(String,String)->String` static method, copies UTF-8 bytes to a caller-owned buffer, clears Java exceptions created by its calls, and detaches only threads it attached. Invoke from a background worker; Java work is synchronous and must not run on the UI thread. Arguments are bounded at one MiB each; embedded NUL cannot be represented by this C-string API. This is a bootstrap API, not the binary NativeNet transport. Calls that return `MS_JAVA_BUFFER` have already executed Java: increasing the buffer and calling again repeats side effects.

The VM is not destroyed/restarted. A second start attempt is rejected even after initialization failure. No JNIEnv is shared across threads. Context-class-loader and extension unload semantics remain to be integrated with the actual backend.

Build `runtime-probe` first, then use `scripts/build-native-runtime-probe.py` with explicit JDK header paths and Java home. Header major version need not equal the VM only when using compatible JNI entries; our current host proof uses the JNI 1.8 invocation API. The definitive iOS build must use its matching runtime headers.

The host probe checks VM creation, native worker attachment, a separate JAR, and recovery after failed class lookup. It does not validate iOS, JNI registration for NativeNet/NativeChannel, Android compatibility classes, cookies, source execution or app UI integration. These sources are intentionally outside the app build until an iOS VM artifact exists. There is no pretend successful runtime path in the app.
