# Source API host implementation

Independently authored Kotlin/JVM implementations of the Source 1.6 interfaces,
factories, models and filters used by the pinned public `extensions-lib` ABI.
This module is outside the production iOS target. It does not load extensions.

## Build and check

```sh
python3 scripts/build-runtime-host.py
python3 scripts/test-runtime-host.py
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
authored suspend sources. See `validation/runtime-host-tests.json`. These are
interface/model checks, not a SourceFactory registry or real extension test.

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
OkHttp/NativeNet setup, signature trust, registry/loading and wire conversion
are still required for a complete host. The module has not run on iPhone.
