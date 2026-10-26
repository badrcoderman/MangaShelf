package eu.kanade.tachiyomi.network

import android.content.Context
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import mangashelf.host.HostServices
import okhttp3.Cache
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.Dispatcher
import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Response

/** JVM HTTP implementation. NativeNet/URLSession and iOS execution remain separate gates. */
class NetworkHelper(context: Context) : AutoCloseable {
    private val executor = Executors.newCachedThreadPool { action ->
        Thread(null, action, "msl-http-worker", 0, false).apply {
            isDaemon = true
            contextClassLoader = NetworkHelper::class.java.classLoader
        }
    }
    private val cookies = MemoryCookieJar()
    private val baseClient = OkHttpClient.Builder()
        .dispatcher(Dispatcher(executor))
        .cookieJar(cookies)
        .cache(Cache(context.cacheDir.resolve("http"), 50L * 1024 * 1024))
        .connectTimeout(30, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS).callTimeout(65, TimeUnit.SECONDS)
        .addInterceptor(UncaughtExceptionInterceptor())
        .addInterceptor(UserAgentInterceptor())
        .addInterceptor(CloudflareInterceptor())
        .build()

    /** Source-owned clones capture their loader without retaining it in the shared base client. */
    val client: OkHttpClient get() {
        val loader = Thread.currentThread().contextClassLoader
        if (loader == null || loader === NetworkHelper::class.java.classLoader) return baseClient
        return baseClient.newBuilder().apply { interceptors().add(0, PackageContextInterceptor(loader)) }.build()
    }

    fun clearCookies() { cookies.clear() }
    fun clearCaches() { baseClient.cache?.evictAll() }

    override fun close() {
        try {
            baseClient.dispatcher.cancelAll()
            baseClient.connectionPool.evictAll()
            baseClient.cache?.close()
        } finally { executor.shutdown() }
    }
}

private class PackageContextInterceptor(private val loader: ClassLoader) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val thread = Thread.currentThread()
        val previous = thread.contextClassLoader
        try { thread.contextClassLoader = loader; return chain.proceed(chain.request()) }
        finally { thread.contextClassLoader = previous }
    }
}

private class UncaughtExceptionInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response = try { chain.proceed(chain.request()) }
    catch (error: RuntimeException) { throw IOException("Source HTTP interceptor failed", error) }
}

private class UserAgentInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        return chain.proceed(if (request.header("User-Agent") != null) request else
            request.newBuilder().header("User-Agent", HostServices.userAgent).build())
    }
}

class BrowserVerificationRequiredException : IOException("Source requires browser verification")

/** Detects a browser challenge; no browser verification is implemented here. */
private class CloudflareInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val response = chain.proceed(chain.request())
        if (response.header("cf-mitigated").equals("challenge", ignoreCase = true)) {
            response.close()
            throw BrowserVerificationRequiredException()
        }
        return response
    }
}

internal class MemoryCookieJar : CookieJar {
    private data class Key(val name: String, val domain: String, val path: String)
    private val cookies = LinkedHashMap<Key, Cookie>()
    @Synchronized fun clear() { cookies.clear() }
    @Synchronized override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        val now = System.currentTimeMillis()
        this.cookies.entries.removeIf { it.value.expiresAt <= now }
        for (cookie in cookies) {
            val key = Key(cookie.name, cookie.domain, cookie.path)
            if (cookie.toString().length > 4096) continue
            if (cookie.expiresAt <= now) this.cookies.remove(key) else this.cookies[key] = cookie
        }
        while (this.cookies.size > 4096) this.cookies.remove(this.cookies.keys.first())
    }
    @Synchronized override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val now = System.currentTimeMillis()
        cookies.entries.removeIf { it.value.expiresAt <= now }
        return cookies.values.filter { it.matches(url) }
    }
}
