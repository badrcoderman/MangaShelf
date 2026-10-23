package mangashelf.host

import android.app.Application
import android.content.Context
import eu.kanade.tachiyomi.network.NetworkHelper
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.InjektScope
import uy.kohesive.injekt.api.addSingleton
import uy.kohesive.injekt.registry.default.DefaultRegistrar

/** One configured application host. Close source registries before closing these shared services. */
object HostServices {
    data class State(val context: Application, val network: NetworkHelper, val versionName: String, val versionCode: Int, val userAgent: String)
    @Volatile private var installed: State? = null
    private var ownedInjector: InjektScope? = null
    val current: State get() = checkNotNull(installed) { "source_host_not_configured" }
    internal val userAgent: String get() = installed?.userAgent ?: "MangaShelf-dev"

    /** Takes ownership of context on success. No source may be initialized before this returns. */
    @Synchronized
    fun configure(context: Application, versionName: String, versionCode: Int, userAgent: String): State {
        check(installed == null) { "source_host_already_configured" }
        require(versionName.isNotEmpty() && versionName.length <= 128 && versionCode >= 0)
        require(userAgent.isNotEmpty() && userAgent.length <= 512 && userAgent.all { it.code in 32..126 })
        val network = NetworkHelper(context)
        val state: State
        val injector: InjektScope
        try {
            injector = InjektScope(DefaultRegistrar()).apply {
                addSingleton<Application>(context)
                addSingleton<Context>(context)
                addSingleton<NetworkHelper>(network)
            }
            state = State(context, network, versionName, versionCode, userAgent)
            Context.installDefault(context)
        }
        catch (error: Throwable) {
            try { network.close() } catch (release: Throwable) { if (release !== error) error.addSuppressed(release) }
            throw error
        }
        Injekt = injector
        ownedInjector = injector
        installed = state
        return state
    }

    /** Blocking lifecycle operation; call from the host's IO context after package calls drain. */
    @Synchronized
    fun close() {
        val state = installed ?: return
        val empty = InjektScope(DefaultRegistrar())
        installed = null
        if (Injekt === ownedInjector) Injekt = empty
        ownedInjector = null
        var failure: Throwable? = null
        try { state.network.close() } catch (error: Throwable) { failure = error }
        try { state.context.close() }
        catch (error: Throwable) { if (failure == null) failure = error else if (failure !== error) failure.addSuppressed(error) }
        failure?.let { throw it }
    }
}
