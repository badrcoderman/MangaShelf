# Source API host implementation

Independently authored Kotlin/JVM implementations of the Source 1.6 interfaces,
factories, models and filters used by the pinned public `extensions-lib` ABI,
plus a verified archive loader and source registry. This module is outside the
production iOS target. Published extensions have not been executed with it.

## Build and check

```sh
python3 scripts/build-runtime-host.py
python3 scripts/test-runtime-host.py
python3 scripts/test-extension-loader.py
```

Use a JDK 21 or later. Kotlin 2.4.10 generates Java 17 bytecode while seeing
the current JDK collection API. This preserves the read-only `FilterList`
compatibility methods in the reference ABI; it is not a guarantee that the
module runs on a Java 17 platform. Checks currently run on host Java 27.

The build verifies every tool and runtime JAR against
`dependencies.lock.json` before executing the compiler. Matching files may be
reused from the local Gradle cache; missing files are fetched from Maven Central
over HTTPS with size and hash checks. Compiler dependencies stay separate from
runtime dependencies. No extension JAR is placed on either classpath.

The retained checks cover 25 public classes and 185 members, including static
method flags, interface kinds and inheritance, plus 14 functional checks using
authored suspend sources and 19 registry/lifecycle checks. See
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
initialization checks, cancellation and draining removal. This proves neither
publisher identity nor Android/network bootstrap or iOS execution. Trusted
plugins share the host process; SecureClassLoader provides no sandbox.

## Reference and limits

`reference/library.api` is public text data from `keiyoushi/extensions-lib` at
`42255ee5fa96d9425697b7c143587483207308d1`. Its Apache 2.0 license and provenance
are included beside it. No upstream throwing stub implementation is used.

Model factories are functional. Chapter upload dates remain milliseconds here;
the future Swift wire adapter must explicitly convert them to seconds. Returned
page order must be preserved independently of each Page's index.

The authored `android.net.Uri` currently supplies the encoded value, parsing
entrypoint, equality and ordering needed for the Page descriptor. Android
Parcelable, URI component parsing, preferences, Context, Injekt, HttpSource,
OkHttp/NativeNet setup, publisher trust provisioning and wire conversion
are still required for a complete host. The module has not run on iPhone.
