# JNI runtime bridge

Project-owned C code; external JDK headers and VM library are build inputs, not copied from the IPA.

`ms_java_start` creates one process-lifetime VM using a supplied linked creation function. The host uses `JNI_CreateJavaVM`; another VM must expose a compatible invocation ABI that is checked against its own headers and build. The bridge does not assume that renaming an OpenJ9 symbol makes the VM compatible.

`ms_java_call_string2` attaches the calling thread when necessary, creates a local-reference frame, invokes a `(String,String)->String` static method, copies UTF-8 bytes to a caller-owned buffer, clears Java exceptions created by its calls, and detaches only threads it attached. Invoke from a background worker; Java work is synchronous and must not run on the UI thread. Arguments are bounded at one MiB each; embedded NUL cannot be represented by this C-string API. This is a bootstrap API, not the binary NativeNet transport. Calls that return `MS_JAVA_BUFFER` have already executed Java: increasing the buffer and calling again repeats side effects.

The VM is not destroyed/restarted. A second start attempt is rejected even after initialization failure. No JNIEnv is shared across threads. Context-class-loader and extension unload semantics remain to be integrated with the actual backend.

Build `runtime-probe` first, then use `scripts/build-native-runtime-probe.py` with explicit JDK header paths and Java home. Header major version need not equal the VM only when using compatible JNI entries; our current host proof uses the JNI 1.8 invocation API. The definitive iOS build must use its matching runtime headers.

`NativeNet.call_utf8` returns two byte arrays: UTF-8 response metadata and a binary body. Metadata is limited to 256 KiB in either direction, request bodies to 32 MiB and response bodies to 64 MiB. An Okio-shaped object must expose `size(): long` and `readByteArray(): byte[]`; its advertised size is checked before the consuming read, and the returned byte count must match. Missing, empty or oversized metadata, unsupported bodies, body exceptions and oversized bodies fail before transport with error metadata and an empty body. Malformed, oversized or failed callback responses similarly return an error, never successful metadata with a silently discarded body. JNI allocation failures in the bridge preserve the Java exception and return null. JSON schema validation remains the transport's responsibility.

The transport callback receives borrowed request spans for the duration of the call. It must return separately allocated response buffers and a matching free callback; the bridge releases those buffers on success and rejection. A null body with zero length is a valid empty response. A nonzero length with a null pointer, aliased metadata/body allocations, or a missing release callback is rejected. These checks validate the buffer descriptors, not arbitrary native pointer provenance.

The host probe checks VM creation, concurrent native worker attachment, a separate project-owned JAR, Unicode and recovery after failed class/method lookup. It registers project-owned NativeNet/NativeChannel callbacks and calls the exported JNI entrypoints directly with real JVM objects. Network cases cover a byte array, a synthetic Okio-shaped buffer, size preflight, missing methods, throwing/null/mismatched reads, oversized request metadata/body, invalid response pointer/length pairs, `SIZE_MAX` lengths, callback failures and release counts. Channel coverage is a valid topic/content pair only; malformed channels and JNI allocation failures are not fault-injected. The fixtures are rebuilt for every host probe.

## Explicit Java dispatcher adapter

`MSJavaBridge.c` now connects `ms_bridge_dispatch` to an explicitly selected
static Java backend. Start the process VM first, then call
`ms_java_bridge_install(class_name, method_name)` on a worker. No class is chosen
implicitly, and installing a backend does not grant extension trust or provide
the source API. Disable/uninstall prevents new calls; captured calls may finish.
It does not cancel Java work or destroy/restart the VM.

`ms_java_call_string2_owned` and `ms_java_bridge_dispatch_owned` invoke Java once
and return an allocation released with `ms_java_free_string`. Their returned
length excludes the trailing NUL, and output is bounded at 16 MiB. The generic
owned API preserves embedded NUL bytes; the JSON/C-string adapter rejects them.
The legacy fixed-buffer API remains available. A buffer overflow or size query
has already executed the Java action and must not be replayed to resize it.

`python3 scripts/test-java-bridge.py` exercises the actual registered callback
through JNI with project-owned Java fixtures, including large responses,
exception recovery, attachment ownership, concurrent callers and disabling an
active backend. `validation/java-bridge-host.json` records the executed inputs.
Class-resolution failure can include missing dependencies or an earlier failed
initializer, rather than only a missing target class.

The separate iPhone check passed on iOS 26.2 with source-built runtime
39818913578, including its own JAR, filesystem MIME, Arabic/emoji and JNI echo;
see `validation/ios-jvm-device-39823313828-iphone-report.json`. This subsequent
dispatcher adapter still needs iOS verification and owned-output exposure to
Swift. Native-method symbol resolution, Android compatibility, real Okio,
cookies, source execution and main-app integration remain unproven. These sources
are outside the production app build until that integration is implemented.
