@file:Suppress("FunctionName")

package eu.kanade.tachiyomi.network

import okhttp3.CacheControl
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody

private val emptyHeaders = Headers.Builder().build()
private val defaultCache = CacheControl.Builder().build()
private val emptyBody = ByteArray(0).toRequestBody()

fun GET(url: String, headers: Headers = emptyHeaders, cache: CacheControl = defaultCache): Request =
    Request.Builder().url(url).headers(headers).cacheControl(cache).get().build()

fun GET(url: HttpUrl, headers: Headers = emptyHeaders, cache: CacheControl = defaultCache): Request =
    Request.Builder().url(url).headers(headers).cacheControl(cache).get().build()

fun POST(url: String, headers: Headers = emptyHeaders, body: RequestBody = emptyBody, cache: CacheControl = defaultCache): Request =
    Request.Builder().url(url).headers(headers).cacheControl(cache).post(body).build()
