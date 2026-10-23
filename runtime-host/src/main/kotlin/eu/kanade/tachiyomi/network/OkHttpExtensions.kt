package eu.kanade.tachiyomi.network

import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Response

/** Ownership of a successful response passes to the caller, including its body. */
suspend fun Call.await(): Response {
    currentCoroutineContext().ensureActive()
    val callbackFinished = CompletableDeferred<Unit>()
    try {
        return suspendCancellableCoroutine { continuation ->
            val completed = AtomicBoolean()
            continuation.invokeOnCancellation { cancel() }
            try {
                enqueue(object : Callback {
                    override fun onFailure(call: Call, e: IOException) {
                        try { if (completed.compareAndSet(false, true)) continuation.resumeWithException(e) }
                        finally { callbackFinished.complete(Unit) }
                    }
                    override fun onResponse(call: Call, response: Response) {
                        try {
                            if (!completed.compareAndSet(false, true)) { response.close(); return }
                            // A cancelled caller may never receive a resumed response.
                            continuation.resume(response) { _, resource, _ -> resource.close() }
                        } finally { callbackFinished.complete(Unit) }
                    }
                })
            } catch (error: Throwable) {
                callbackFinished.complete(Unit)
                throw error
            }
        }
    } catch (error: CancellationException) {
        cancel()
        // Keep the source lease alive until asynchronous interceptors finish.
        // A noncooperative interceptor can delay removal, just like source code.
        withContext(NonCancellable) { callbackFinished.await() }
        throw error
    }
}

suspend fun Call.awaitSuccess(): Response {
    val response = await()
    if (response.isSuccessful) return response
    val code = response.code
    response.close()
    throw HttpException(code)
}
