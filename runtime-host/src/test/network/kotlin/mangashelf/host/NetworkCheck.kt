package mangashelf.host

import android.app.Application
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import com.sun.net.httpserver.HttpsConfigurator
import com.sun.net.httpserver.HttpsServer
import eu.kanade.tachiyomi.AppInfo
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.HttpException
import eu.kanade.tachiyomi.network.POST
import eu.kanade.tachiyomi.network.await
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.online.HttpSource
import java.io.IOException
import java.lang.reflect.Modifier
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.nio.file.Path
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Headers
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.Timeout
import okio.buffer

object NetworkCheck {
    private val descriptorClient = okhttp3.OkHttpClient()
    private class Server(tls: SSLContext? = null) : AutoCloseable {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val cached = AtomicInteger()
        val reached = AtomicInteger()
        private val executor = Executors.newCachedThreadPool { Thread(it, "authored-http-server").apply { isDaemon = true } }
        private val server: HttpServer = if (tls == null) HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0) else
            HttpsServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply { httpsConfigurator = HttpsConfigurator(tls) }
        val url: String get() = "${if (server is HttpsServer) "https" else "http"}://localhost:${server.address.port}"

        init {
            server.executor = executor
            server.createContext("/") { exchange ->
                reached.incrementAndGet()
                try {
                    when (exchange.requestURI.path) {
                        "/slow" -> {
                            entered.countDown()
                            if (!release.await(10, TimeUnit.SECONDS)) error("Fixture HTTP gate timed out")
                            reply(exchange, "released")
                        }
                        "/ua" -> reply(exchange, exchange.requestHeaders.getFirst("User-Agent") ?: "")
                        "/echo" -> {
                            val body = exchange.requestBody.readBytes()
                            exchange.responseHeaders.add("Content-Type", "application/octet-stream")
                            exchange.responseHeaders.add("X-Fixture-Method", exchange.requestMethod)
                            exchange.sendResponseHeaders(200, body.size.toLong())
                            exchange.responseBody.use { it.write(body) }
                        }
                        "/redirect" -> { exchange.responseHeaders.add("Location", "/utf8"); reply(exchange, "redirect", 302) }
                        "/not-found" -> reply(exchange, "authored missing", 404)
                        "/challenge" -> {
                            exchange.responseHeaders.add("cf-mitigated", "challenge")
                            reply(exchange, "authored browser challenge", 403)
                        }
                        "/cache" -> {
                            exchange.responseHeaders.add("Cache-Control", "max-age=3600")
                            reply(exchange, "cached-${cached.incrementAndGet()}")
                        }
                        "/cookies/set" -> { exchange.responseHeaders.add("Set-Cookie", "session=owned; Path=/cookies; HttpOnly"); reply(exchange, "set") }
                        "/cookies/echo", "/outside" -> reply(exchange, exchange.requestHeaders.getFirst("Cookie") ?: "")
                        else -> reply(exchange, "العربية 📚")
                    }
                } catch (_: IOException) { /* Client cancellation may close its socket. */ }
                finally { exchange.close() }
            }
            server.start()
        }
        private fun reply(exchange: HttpExchange, text: String, code: Int = 200) {
            val bytes = text.toByteArray(Charsets.UTF_8)
            exchange.responseHeaders.add("Content-Type", "text/plain; charset=utf-8")
            exchange.sendResponseHeaders(code, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        override fun close() { release.countDown(); server.stop(0); executor.shutdownNow() }
    }

    private class Body : ResponseBody() {
        val closes = AtomicInteger()
        private val closed = AtomicBoolean()
        private val source = object : ForwardingSource(Buffer().writeUtf8("authored response")) {
            override fun close() {
                if (closed.compareAndSet(false, true)) closes.incrementAndGet()
                super.close()
            }
        }.buffer()
        override fun contentType(): MediaType = "text/plain".toMediaType()
        override fun contentLength(): Long = 17
        override fun source(): BufferedSource = source
    }

    private class ControlledCall(private val request: Request = GET("https://example.invalid/owned")) : Call by descriptorClient.newCall(request) {
        private lateinit var callback: Callback
        var cancelled = false
        var enqueued = false
        var throwOnEnqueue = false
        override fun request(): Request = request
        override fun execute(): Response = error("Fixture uses asynchronous calls")
        override fun enqueue(responseCallback: Callback) {
            if (throwOnEnqueue) error("Authored enqueue failure")
            check(!enqueued)
            callback = responseCallback
            enqueued = true
        }
        override fun cancel() { cancelled = true }
        override fun isExecuted(): Boolean = enqueued
        override fun isCanceled(): Boolean = cancelled
        override fun timeout(): Timeout = Timeout.NONE
        override fun clone(): Call = ControlledCall(request)
        fun response(body: Body, code: Int = 200): Response = Response.Builder().request(request)
            .protocol(Protocol.HTTP_1_1).code(code).message("fixture").body(body).build()
        fun reply(response: Response) = callback.onResponse(this, response)
        fun fail(error: IOException) = callback.onFailure(this, error)
    }

    private open class FixtureSource(override val baseUrl: String, override val name: String = "Authored HTTP") : HttpSource() {
        override val lang = "en"
        override val supportsLatest = true
        override suspend fun getPopularManga(page: Int): MangasPage = client.newCall(GET("$baseUrl/utf8")).awaitSuccess().use {
            MangasPage(listOf(SManga.create().apply { title = it.body.string(); url = "/authored/$page" }), false)
        }
        override suspend fun getLatestUpdates(page: Int) = getPopularManga(page)
        override suspend fun getSearchManga(page: Int, query: String, filters: FilterList) = getPopularManga(page)
        override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean) =
            SMangaUpdate(manga, chapters)
        override suspend fun getPageList(chapter: SChapter) = listOf(Page(0, chapter.url, "$baseUrl/image"))
        override fun getMangaUrl(manga: SManga) = baseUrl + manga.url
        override fun getChapterUrl(chapter: SChapter) = baseUrl + chapter.url
        fun strip(url: String): Pair<String, String> {
            val manga = SManga.create().apply { setUrlWithoutDomain(url) }
            val chapter = SChapter.create().apply { setUrlWithoutDomain(url) }
            return manga.url to chapter.url
        }
        fun image(page: Page) = imageRequest(page)
    }

    private fun tls(path: Path): Triple<SSLContext, SSLContext, X509TrustManager> {
        val password = "mangashelf-authored-network-test".toCharArray()
        val keyStore = KeyStore.getInstance("JKS").apply { Files.newInputStream(path).use { load(it, password) } }
        val keyManagers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(keyStore, password) }
        val server = SSLContext.getInstance("TLS").apply { init(keyManagers.keyManagers, null, SecureRandom()) }
        val trusted = KeyStore.getInstance("PKCS12").apply { load(null, null); setCertificateEntry("fixture", keyStore.getCertificate("fixture")) }
        val managers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trusted) }
        val manager = managers.trustManagers.filterIsInstance<X509TrustManager>().single()
        val client = SSLContext.getInstance("TLS").apply { init(null, arrayOf(manager), SecureRandom()) }
        return Triple(server, client, manager)
    }

    @JvmStatic
    fun main(args: Array<String>) = runBlocking {
        val root = Path.of(args[0])
        val checks = linkedMapOf<String, Boolean>()
        suspend fun case(name: String, body: suspend () -> Unit) {
            System.err.println("START $name")
            try { withTimeout(15000) { body() } }
            catch (error: Throwable) {
                System.err.println("FAIL $name: ${error.javaClass.name}: ${error.message}")
                throw error
            }
            checks[name] = true
            System.err.println("PASS $name")
        }
        case("request_defaults_overloads_headers_cache_and_binary_upload") {
            val headers = Headers.Builder().add("X-Fixture", "owned").build()
            val control = okhttp3.CacheControl.FORCE_NETWORK
            val request = GET("https://example.invalid/a?q=%2F", headers, control)
            check(request.method == "GET" && request.header("X-Fixture") == "owned" && request.header("Cache-Control") == "no-cache")
            check(GET(request.url).url == request.url)
            val empty = POST("https://example.invalid/a")
            check(empty.method == "POST" && empty.body?.contentLength() == 0L)
            val bytes = byteArrayOf(0, 1, -1, 0, 42)
            Server().use { server ->
                HostServices.configure(Application(root.resolve("upload"), "app.mangashelf.test"), "test", 7, "MangaShelf-Test/7")
                try {
                    val call = HostServices.current.network.client.newCall(POST(server.url + "/echo", body = bytes.toRequestBody()))
                    call.awaitSuccess().use { response ->
                        check(response.body.bytes().contentEquals(bytes) && response.header("X-Fixture-Method") == "POST")
                    }
                } finally { HostServices.close() }
            }
        }
        case("configured_http_source_fetches_unicode_and_exposes_required_client_interceptors") {
            Server().use { server ->
                HostServices.configure(Application(root.resolve("source"), "app.mangashelf.test"), "0.5-test", 7, "MangaShelf-Test/7")
                try {
                    val source = FixtureSource(server.url)
                    check(source.getPopularManga(1).mangas.single().title == "العربية 📚")
                    check(source.id == 8642382357855233528L && source.getHomeUrl() == server.url && source.toString() == source.name)
                    val names = source.client.interceptors.map { it.javaClass.simpleName }
                    check(names.containsAll(listOf("UncaughtExceptionInterceptor", "UserAgentInterceptor", "CloudflareInterceptor")))
                    check(AppInfo.getVersionCode() == 7 && AppInfo.getVersionName() == "0.5-test")
                    source.client.newCall(GET(server.url + "/ua")).awaitSuccess().use { check(it.body.string() == "MangaShelf-Test/7") }
                    source.client.newCall(GET(server.url + "/ua", Headers.Builder().add("User-Agent", "Source-Own/1").build()))
                        .awaitSuccess().use { check(it.body.string() == "Source-Own/1") }
                } finally { HostServices.close() }
            }
        }
        case("http_source_id_is_lazy_and_independent_of_turkish_default_locale") {
            HostServices.configure(Application(root.resolve("identity"), "app.mangashelf.test"), "test", 7, "MangaShelf-Test/7")
            val original = Locale.getDefault()
            try {
                Locale.setDefault(Locale.forLanguageTag("tr-TR"))
                val source = FixtureSource("https://example.invalid", "I Site")
                check(source.id == 2410074385137836807L && source.id >= 0)
            } finally { Locale.setDefault(original); HostServices.close() }
        }
        case("headers_delegate_can_be_replaced_without_mutating_a_final_field") {
            HostServices.configure(Application(root.resolve("headers"), "app.mangashelf.test"), "test", 7, "MangaShelf-Test/7")
            try {
                val source = FixtureSource("https://example.invalid")
                val field = HttpSource::class.java.getDeclaredField("headers\$delegate")
                check(!Modifier.isFinal(field.modifiers))
                field.isAccessible = true
                field.set(source, lazyOf(Headers.Builder().add("X-Replaced", "owned").build()))
                check(source.headers["X-Replaced"] == "owned")
            } finally { HostServices.close() }
        }
        case("relative_urls_queries_fragments_and_image_requests_are_preserved") {
            HostServices.configure(Application(root.resolve("urls"), "app.mangashelf.test"), "test", 7, "MangaShelf-Test/7")
            try {
                val source = FixtureSource("https://example.invalid")
                val expected = "/a%2Fb?q=%23#page%202"
                check(source.strip("https://example.invalid$expected") == expected to expected)
                check(source.strip(expected) == expected to expected)
                val page = Page(3, "", "https://example.invalid/image%20one.png")
                check(source.getImageUrl(page) == page.imageUrl && source.image(page).url.toString() == page.imageUrl)
                try { source.getImageUrl(Page(0, "/html", null)); error("Invented unresolved image URL") }
                catch (_: UnsupportedOperationException) { }
            } finally { HostServices.close() }
        }
        case("image_urls_use_source_request_builder_and_preserve_opaque_page_metadata") {
            HostServices.configure(Application(root.resolve("image-resolver"), "app.mangashelf.test"), "test", 7, "MangaShelf-Test/7")
            try {
                var calls = 0
                val caller = Thread.currentThread()
                val source = object : FixtureSource("https://example.invalid") {
                    override fun imageRequest(page: Page): Request {
                        check(Thread.currentThread() !== caller)
                        check(page.url == "https://images.example.invalid,token,0")
                        calls++
                        return GET("https://images.example.invalid" + page.imageUrl,
                            Headers.Builder().add("X-Image-Token", "source-owned").build())
                    }
                }
                val page = Page(4, "https://images.example.invalid,token,0", "/data/hash/image%20one.jpg")
                check(source.getImageUrl(page) == "https://images.example.invalid/data/hash/image%20one.jpg")
                check(calls == 1 && page.imageUrl == "/data/hash/image%20one.jpg" && page.url == "https://images.example.invalid,token,0")
            } finally { HostServices.close() }
        }
        case("redirects_error_status_challenges_and_http_cache_use_real_http") {
            Server().use { server ->
                HostServices.configure(Application(root.resolve("http"), "app.mangashelf.test"), "test", 7, "MangaShelf-Test/7")
                try {
                    val client = HostServices.current.network.client
                    client.newCall(GET(server.url + "/redirect")).awaitSuccess().use { check(it.body.string() == "العربية 📚" && it.priorResponse?.code == 302) }
                    client.newCall(GET(server.url + "/not-found")).await().use { check(it.code == 404) }
                    try { client.newCall(GET(server.url + "/not-found")).awaitSuccess(); error("Accepted error HTTP status") }
                    catch (error: HttpException) { check(error.code == 404) }
                    try { client.newCall(GET(server.url + "/challenge")).awaitSuccess(); error("Accepted browser challenge") }
                    catch (error: IOException) { check(error.message == "Source requires browser verification") }
                    repeat(2) { client.newCall(GET(server.url + "/cache")).awaitSuccess().use { check(it.body.string() == "cached-1") } }
                    check(server.cached.get() == 1)
                    HostServices.current.network.clearCaches()
                    client.newCall(GET(server.url + "/cache")).awaitSuccess().use { check(it.body.string() == "cached-2") }
                    check(server.cached.get() == 2)
                } finally { HostServices.close() }
            }
        }
        case("response_cookies_are_sent_only_to_matching_paths") {
            Server().use { server ->
                HostServices.configure(Application(root.resolve("cookies"), "app.mangashelf.test"), "test", 7, "MangaShelf-Test/7")
                try {
                    val client = HostServices.current.network.client
                    client.newCall(GET(server.url + "/cookies/set")).awaitSuccess().close()
                    client.newCall(GET(server.url + "/cookies/echo")).awaitSuccess().use { check(it.body.string() == "session=owned") }
                    client.newCall(GET(server.url + "/outside")).awaitSuccess().use { check(it.body.string().isEmpty()) }
                    HostServices.current.network.clearCookies()
                    // Previously created source clients share the same jar and lose the cookie too.
                    client.newCall(GET(server.url + "/cookies/echo")).awaitSuccess().use { check(it.body.string().isEmpty()) }
                } finally { HostServices.close() }
            }
        }
        case("jvm_tls_checks_certificates_and_hostnames_with_fixture_only_trust") {
            val started = System.nanoTime()
            fun stage(name: String) = System.err.println("TLS $name after ${(System.nanoTime() - started) / 1_000_000} ms")
            stage("loading fixture keystore")
            val (serverTls, clientTls, manager) = tls(Path.of(args[1]))
            stage("keystore loaded")
            Server(serverTls).use { server ->
                HostServices.configure(Application(root.resolve("tls"), "app.mangashelf.test"), "test", 7, "MangaShelf-Test/7")
                try {
                    // Bind DNS to this fixture's IPv4 listener. Otherwise an
                    // unrelated IPv6 refusal may mask the certificate rejection.
                    val base = HostServices.current.network.client.newBuilder().dns(object : okhttp3.Dns {
                        override fun lookup(hostname: String): List<InetAddress> {
                            check(hostname == "localhost")
                            return listOf(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
                        }
                    }).build()
                    try { base.newCall(GET(server.url + "/utf8")).awaitSuccess(); error("Trusted an unprovisioned fixture certificate") }
                    catch (_: SSLHandshakeException) { }
                    stage("untrusted certificate rejected")
                    check(server.reached.get() == 0)
                    val trusted = base.newBuilder().sslSocketFactory(clientTls.socketFactory, manager).build()
                    trusted.newCall(GET(server.url + "/utf8")).awaitSuccess().use { check(it.body.string() == "العربية 📚") }
                    stage("trusted fixture fetched")
                    val reached = server.reached.get()
                    try { trusted.newCall(GET(server.url.replace("localhost", "127.0.0.1") + "/utf8")).awaitSuccess(); error("Skipped hostname verification") }
                    catch (_: SSLPeerUnverifiedException) { }
                    stage("wrong hostname rejected")
                    check(server.reached.get() == reached)
                } finally { HostServices.close() }
            }
        }
        case("cancellation_closes_real_inflight_http_and_finishes_callback") {
            Server().use { server ->
                HostServices.configure(Application(root.resolve("cancel-http"), "app.mangashelf.test"), "test", 7, "MangaShelf-Test/7")
                try {
                    coroutineScope {
                        val call = HostServices.current.network.client.newCall(GET(server.url + "/slow"))
                        val task = async(start = CoroutineStart.UNDISPATCHED) { call.awaitSuccess().close() }
                        try {
                            check(server.entered.await(5, TimeUnit.SECONDS))
                            task.cancel()
                            task.join()
                            check(call.isCanceled() && task.isCancelled)
                        } finally { server.release.countDown(); task.cancel() }
                    }
                } finally { HostServices.close() }
            }
        }
        case("successful_response_ownership_is_transferred_to_caller") {
            coroutineScope {
                val call = ControlledCall(); val body = Body(); val response = call.response(body)
                val task = async(start = CoroutineStart.UNDISPATCHED) { call.await() }
                call.reply(response)
                check(task.await() === response && body.closes.get() == 0)
                response.close(); check(body.closes.get() == 1)
            }
        }
        case("retry_after_header_and_http_date_are_typed_before_body_closes") {
            check(HttpException.retryAfter("120") == 120.0)
            check(HttpException.retryAfter("Tue, 14 Nov 2023 22:15:20 GMT", java.time.Instant.ofEpochSecond(1_700_000_000)) == 120.0)
            check(HttpException.retryAfter("NaN") == null && HttpException.retryAfter("-1") == null)
            coroutineScope {
                val call = ControlledCall(); val body = Body()
                val task = async(start = CoroutineStart.UNDISPATCHED) {
                    try { call.awaitSuccess(); error("Accepted fixture rate limit") }
                    catch (error: HttpException) { check(error.code == 429 && error.retryAfterSeconds == 120.0) }
                }
                call.reply(call.response(body, 429).newBuilder().header("Retry-After", "120").build())
                task.await(); check(body.closes.get() == 1)
            }
        }
        case("error_response_is_closed_before_http_exception") {
            coroutineScope {
                val call = ControlledCall(); val body = Body()
                val task = async(start = CoroutineStart.UNDISPATCHED) {
                    try { call.awaitSuccess(); error("Accepted fixture error status") }
                    catch (error: HttpException) { check(error.code == 503) }
                }
                call.reply(call.response(body, 503)); task.await(); check(body.closes.get() == 1)
            }
        }
        case("cancelled_request_waits_for_callback_and_closes_late_response") {
            coroutineScope {
                val call = ControlledCall(); val body = Body()
                val task = launch(start = CoroutineStart.UNDISPATCHED) { call.await().close() }
                task.cancel(); check(call.cancelled && !task.isCompleted)
                call.reply(call.response(body)); task.join()
                check(task.isCancelled && body.closes.get() == 1)
            }
        }
        case("response_lost_to_prompt_cancellation_is_closed") {
            coroutineScope {
                val call = ControlledCall(); val body = Body()
                val task = launch(start = CoroutineStart.UNDISPATCHED) { call.await().close() }
                call.reply(call.response(body)); task.cancel(); task.join()
                check(task.isCancelled && body.closes.get() == 1)
            }
        }
        case("precancelled_caller_does_not_enqueue_or_cancel_an_unowned_call") {
            coroutineScope {
                val call = ControlledCall()
                val task = launch(start = CoroutineStart.UNDISPATCHED) {
                    currentCoroutineContext().cancel()
                    try { call.await(); error("Ran a precancelled call") } catch (_: CancellationException) { }
                }
                task.join(); check(!call.enqueued && !call.cancelled)
            }
        }
        case("enqueue_failure_does_not_leave_cancellation_drain_waiting") {
            val call = ControlledCall().apply { throwOnEnqueue = true }
            try { call.await(); error("Accepted failed enqueue") }
            catch (error: IllegalStateException) { check(error.message == "Authored enqueue failure") }
        }
        case("duplicate_callback_does_not_leak_second_response") {
            coroutineScope {
                val call = ControlledCall(); val first = Body(); val duplicate = Body()
                val task = async(start = CoroutineStart.UNDISPATCHED) { call.await() }
                call.reply(call.response(first)); call.reply(call.response(duplicate))
                task.await().close(); check(first.closes.get() == 1 && duplicate.closes.get() == 1)
            }
        }
        println(buildJsonObject {
            put("passed", true)
            put("checks", JsonObject(checks.mapValues { JsonPrimitive(it.value) }))
            put("scope", "Authored source and call fixtures, real loopback HTTP/HTTPS on host JVM; no NativeNet, real extension or iOS execution")
        })
    }
}
