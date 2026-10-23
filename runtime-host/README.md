# Source API host implementation

Independently authored Kotlin/JVM implementations of the Source 1.6 interfaces,
factories, models and filters used by the pinned public `extensions-lib` ABI,
plus HTTP source services, persistent preferences, a verified archive loader and
source registry. The host also builds the pinned MIT Injekt library from reviewed
public Kotlin sources with a recorded compiler compatibility bridge. This module is outside the
production iOS target. Published extensions have not been executed with it.

## Build and check

```sh
python3 scripts/build-runtime-host.py
python3 scripts/test-runtime-host.py
python3 scripts/test-runtime-preferences.py
python3 scripts/test-runtime-bootstrap.py
python3 scripts/test-runtime-source-preferences.py
python3 scripts/test-runtime-network.py
python3 scripts/test-extension-loader.py
```

Use a JDK 21 or later. Kotlin 2.4.10 generates Java 17 bytecode while seeing
the current JDK collection API. This preserves the read-only `FilterList`
compatibility methods in the reference ABI; it is not a guarantee that the
module runs on a Java 17 platform. Checks run locally on Java 27 and in Actions
on Linux/macOS Java 25.

The build verifies every tool and runtime JAR against
`dependencies.lock.json` before executing the compiler. Matching files may be
reused from the local Gradle cache; missing files are fetched from Maven Central
over HTTPS with size and hash checks. Compiler dependencies stay separate from
runtime dependencies. Injekt's exact source/license set is separately checked
against `injekt-source.lock.json`; the build applies `injekt-compat.patch.json`
only to a temporary copy and includes the upstream MIT notice. No upstream build
scripts or binaries are executed. No extension JAR is placed on either classpath.

The retained ABI checks cover 45 public/protected classes and 278 members,
including member visibility, static method flags, interface kinds and inheritance,
plus 14 functional checks using
authored suspend sources and 20 registry/lifecycle checks. See
`validation/runtime-host-tests.json`. No real extension is loaded or executed.

## Source registry

`mangashelf.host.SourceRegistry` accepts an already trusted/instantiated `Source`
or `SourceFactory` and the expected metadata IDs/languages for that exact package
version. It registers all entries atomically, rejects missing/extra or duplicate
IDs and cross-package conflicts, and checks `CatalogueSource.lang` against
metadata. A plain `Source` has no language getter; its metadata language is kept.
IDs retain their signed Long value. Caller-supplied limits default to 10,000
active sources and 4096 per package.

Factory callbacks and source getters run outside the registry lock. Calls use
package coroutine scopes; caller cancellation and package removal cancel the
operation. Removal prevents new calls immediately and returns a release ticket.
The optional resource is closed once after in-flight work finishes; code that
ignores cancellation can delay this. Registry close also returns tickets for
earlier removals still draining. Await tickets to observe release failures.
Caller cancellation waits for the source task's cleanup before completing the
caller; it does not remove the package or cancel sibling requests.

Registration takes ownership of the optional resource on failure as well as
success. The archive loader passes its verified classloader resource; callers
must serialize source-owned models inside `withSource` before its operation
finishes. Factory callbacks and source coroutines use and restore the package
thread context classloader, including after suspension. The registry neither
verifies archives nor unloads JVM classes. It does not establish publisher trust.

Tests cover 61 source registrations/invocations, matching and conflicts, bounded
factory iteration, cancellation before publication, caller cancellation,
replacement during draining removal, concurrent installs, resource ownership,
release failure, and close behavior. Factories/sources in these tests are authored
fixtures, not a downloaded extension.

## Verified archive loader

`ExtensionLoader.install` requires the exact archive SHA-256, an explicitly
trusted leaf certificate DER SHA-256, package/version/entrypoint metadata, and
expected source IDs/languages. It verifies a bounded private copy, opens the
JarFile, unlinks the copy, and retains that same open handle for class/resource
loading. Changing the original path after verification cannot change these
bytes. This currently requires POSIX permissions and unlinking an open file;
unsupported filesystems fail without a mutable-path fallback.

Every physical payload is verified, including META-INF and versioned entries.
Multi-release selection uses the running JVM version. Defined classes retain
their code signers and package metadata/sealing. Resources use bound custom URLs
without reopening a path or fetching a network address. Host API namespace
shadows and external manifest Class-Path dependencies are rejected.

The signed text AndroidManifest is bounded and matched before initialization.
This host currently accepts the modern `tachiyomix.extensionLib=1.6` contract.
The entrypoint must be local to the archive, public, nonabstract, implement
Source/SourceFactory and have a public no-argument constructor. Preparation and
registration failures release their handles; package removal drains source calls
before release. Closing does not invalidate already defined classes, copied
resource bytes or arbitrary global threads created by a plugin.

`scripts/test-extension-loader.py` builds/signs only project-authored fixtures
with a generated test key. Their JARs/classes are absent from the parent classpath.
It exercises actual SourceFactory loading, typed calls, original-path replacement,
signers, multi-release/sealed packages, Unicode resources, manifest rejection,
initialization checks, cancellation and draining removal. The HTTP fixture also
performs loopback requests through a separately loaded signed source and checks
that cancellation retains its archive until asynchronous interceptor cleanup ends.
These checks prove neither publisher identity nor a published source's complete
Android bootstrap or iOS execution. Trusted
plugins share the host process; SecureClassLoader provides no sandbox.

Actions run [39934045293](https://github.com/badrcoderman/MangaShelf/actions/runs/39934045293)
passed on both platforms: 14 model checks, 19 registry checks, 17 loader checks
and 46 authored signature checks each. Both artifacts passed digest/CRC/source
fingerprint inspection and contain the same host JAR. The local 47th signature
case is an optional data-only check of the separately rebuilt public candidate;
that file is absent from CI. See `validation/runtime-host-39934045293.json`.

The expanded checks passed on Linux and macOS Java 25 in
[39988642098](https://github.com/badrcoderman/MangaShelf/actions/runs/39988642098)
at `95e9b11`: 32 API classes / 222 members, 14 model, 20 registry, 19 signed
loader, 16 preference, 16 HTTP/TLS and 46 signature checks per platform.
Artifact digests/CRC and source fingerprints match; both contain the same host
JAR. The earlier run `39987683915` exposed a cancellation race: the caller could
finish before source cleanup. The fix joins that source task, and a gated test
checks the ordering. Actions remove old reports first so skipped checks cannot
upload stale passes. See `validation/runtime-host-39988642098.json`.

The source-built Injekt/bootstrap changes passed in
[39992873306](https://github.com/badrcoderman/MangaShelf/actions/runs/39992873306)
at `e2c87d0` on both platforms, adding 6 startup/lifecycle checks and extending
the signed HTTP fixture with constructor injection and preference persistence
across reinstall. Both 8-file artifacts passed digest/CRC/source inspection,
including the pinned upstream files and compatibility edit; the same host JAR
contains the MIT notice and separate Injekt module metadata, without codec native
libraries. See `validation/runtime-host-39992873306.json`. No IPA is produced.

## Source settings

`ConfigurableSource` and the pinned `androidx.preference` types maintain source
settings, choices, defaults, persistence and change/click/bind listeners. A small
headless text/dialog model supports `TextWatcher`, `EditText.error` and the
positive-button gate used by source validators. It does not implement Android
rendering, spans or a Looper.

`SourcePreferenceSession` keeps the screen and all source callbacks inside one
long-lived registry lease. Only immutable host snapshots leave it. Use its
snapshot/change/validateText/click operations and await `closeAndJoin` when the
native settings view closes. Package removal cancels the session and waits for
callback detachment before releasing its archive. Queue cancellation skips work
that has not started; it cannot roll back an already executing plugin callback.
Callback failures return host codes without retaining a plugin exception.

Seventeen authored checks cover persistence, validation, immutable values, input
bounds, cancellation and cleanup. The signed fixture also exercises these
callbacks from its verified child classloader, applies a saved setting to a real
loopback HTTP result, restores it after reinstall and gates archive release on
cleanup. Swift rendering and iOS execution remain pending. See
[the contract, evidence and limits](../docs/SOURCE-PREFERENCES-AR.md).

## HTTP and application services

`HostServices.configure` takes one Application, installs its Context, version
identity, user agent and NetworkHelper, and registers the same Application,
Context and NetworkHelper instances with a fresh Injekt scope before initializing
a source. Close clears that owned scope and serializes against startup.
Six lifecycle checks cover identity, cross-module inline access, persistence,
failed/duplicate startup and failing shutdown. The signed HTTP fixture also uses
the injector in its constructor and preserves preferences across reinstall.
See [source provenance and limits](../docs/SOURCE-INJEKT-BOOTSTRAP-AR.md).
`HttpSource` implements
the pinned default source ID, lazy replaceable `headers$delegate`, headers,
request helpers and relative URL handling. It leaves unresolved image extraction
to the source implementation.

NetworkHelper uses the locked OkHttp 5.4.0 / Okio 3.18.1 JVM artifacts, actual
HTTP sockets, the JVM's certificate/hostname checks, a 50 MiB disk cache and
bounded in-memory cookies. It applies a configured user agent and reports
Cloudflare browser challenges explicitly; it has no browser verification flow.
This is **not** the NativeNet/URLSession transport, and sockets/TLS have not been
proven inside the iOS VM. Cookies do not survive host restart.

`Call.await` transfers a successful response to its caller, closes responses lost
to cancellation, cancels the underlying call, and waits for its callback before
releasing the source operation. Thus package resources remain available during
asynchronous interceptor cleanup. An interceptor that never returns can delay
package removal. Close registries and await release tickets before calling the
blocking `HostServices.close` from a worker.

Context/Application expose app-owned files, cache and SharedPreferences; they do
not emulate Android UI, system services or a main Looper. Preferences support
typed values, reusable editors, clear/remove, weak listeners, immediate `apply`
visibility and ordered atomic disk replacement. Corrupt data is rejected without
a silent reset; asynchronous failures surface at flush/close. The bounded binary
file format belongs to MSL and is not Android XML or Tachimanga backup support.
Queued/active disk snapshots are limited to 32 MiB and 4096 writes; exceeding
either fails before publishing new values. Use one owner per directory.
Preferences must be flushed at lifecycle boundaries.

See [implementation and remaining gates](../docs/RUNTIME-HTTP-PREFERENCES-AR.md),
`validation/runtime-preferences-host.json` and
`validation/runtime-network-host.json` for the exact current results and inputs.

## Reference and limits

`reference/library.api` is public text data from `keiyoushi/extensions-lib` at
`42255ee5fa96d9425697b7c143587483207308d1`. Its Apache 2.0 license and provenance
are included beside it. No upstream throwing stub implementation is used.

Model factories are functional. Chapter upload dates remain milliseconds here;
the future Swift wire adapter must explicitly convert them to seconds. Returned
page order must be preserved independently of each Page's index.

The authored `android.net.Uri` currently supplies the encoded value, parsing
entrypoint, equality and ordering needed for the Page descriptor. Android
Parcelable, URI component parsing, additional source dependencies,
ConfigurableSource and Android preference forms, iOS codec/network setup, publisher trust
provisioning and Swift wire conversion
are still required for a complete host. The module has not run on iPhone.
