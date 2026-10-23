package mangashelf.host

import android.content.Context
import eu.kanade.tachiyomi.network.NetworkHelper

/** One configured application host. Close source registries before closing these shared services. */
object HostServices {
    data class State(val context: Context, val network: NetworkHelper, val versionName: String, val versionCode: Int, val userAgent: String)
    @Volatile private var installed: State? = null
    val current: State get() = checkNotNull(installed) { "source_host_not_configured" }
    internal val userAgent: String get() = installed?.userAgent ?: "MangaShelf-dev"

    /** Takes ownership of context on success. No source may be initialized before this returns. */
    @Synchronized
    fun configure(context: Context, versionName: String, versionCode: Int, userAgent: String): State {
        check(installed == null) { "source_host_already_configured" }
        require(versionName.isNotEmpty() && versionName.length <= 128 && versionCode >= 0)
        require(userAgent.isNotEmpty() && userAgent.length <= 512 && userAgent.all { it.code in 32..126 })
        val network = NetworkHelper(context)
        try { Context.installDefault(context) }
        catch (error: Throwable) {
            try { network.close() } catch (release: Throwable) { if (release !== error) error.addSuppressed(release) }
            throw error
        }
        return State(context, network, versionName, versionCode, userAgent).also { installed = it }
    }

    /** Blocking lifecycle operation; call from the host's IO context after package calls drain. */
    fun close() {
        val state = synchronized(this) { val previous = installed; installed = null; previous } ?: return
        var failure: Throwable? = null
        try { state.network.close() } catch (error: Throwable) { failure = error }
        try { state.context.close() }
        catch (error: Throwable) { if (failure == null) failure = error else if (failure !== error) failure.addSuppressed(error) }
        failure?.let { throw it }
    }
}
