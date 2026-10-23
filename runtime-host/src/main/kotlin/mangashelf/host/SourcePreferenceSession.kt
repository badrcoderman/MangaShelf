package mangashelf.host

import androidx.preference.CheckBoxPreference
import androidx.preference.DialogPreference
import androidx.preference.EditTextPreference
import androidx.preference.ListPreference
import androidx.preference.MultiSelectListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceScreen
import androidx.preference.SwitchPreferenceCompat
import androidx.preference.TwoStatePreference
import eu.kanade.tachiyomi.source.ConfigurableSource
import java.util.Collections
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Keeps all plugin rows/callbacks inside one source lease. Only host value snapshots escape. */
class SourcePreferenceSession private constructor(private val registry: SourceRegistry, private val sourceId: Long) {
    class Failure(val code: String) : IllegalStateException(code)
    enum class Kind { SWITCH, CHECKBOX, TOGGLE, LIST, MULTISELECT, TEXT, ACTION }
    sealed interface Value {
        data class Text(val text: String) : Value
        data class Toggle(val checked: Boolean) : Value
        data class Multiple(val values: Set<String>) : Value
    }
    data class Choice(val label: String, val value: String)
    data class Row(val id: Int, val key: String?, val kind: Kind, val title: String?, val summary: String?,
                   val enabled: Boolean, val visible: Boolean, val value: Value?, val choices: List<Choice>,
                   val dialogTitle: String?, val dialogMessage: String?)
    data class Snapshot(val sourceId: Long, val rows: List<Row>)
    data class Change(val accepted: Boolean, val screen: Snapshot)
    data class Validation(val allowed: Boolean, val error: String?, val text: String?, val screen: Snapshot)

    private sealed interface Action {
        data object Read : Action
        data class Set(val row: Int, val value: Value) : Action
        data class Validate(val row: Int, val text: String) : Action
        data class Click(val row: Int) : Action
    }
    private data class Reply(val screen: Snapshot, val accepted: Boolean = false, val error: String? = null, val text: String? = null)
    private data class Command(val action: Action, val result: CompletableDeferred<Reply>)
    private class InvalidRequest(val code: String) : IllegalArgumentException(code)
    private val owner = SupervisorJob()
    private val ready = CompletableDeferred<Unit>()
    @Volatile private var failureCode = "source_preferences_closed"
    private val commands = Channel<Command>(16, onUndeliveredElement = { it.result.completeExceptionally(Failure(failureCode)) })

    private fun start() {
        val context = HostServices.current.context
        CoroutineScope(Dispatchers.IO + owner).launch {
            try {
                registry.withSource(sourceId) { source ->
                    val configurable = source as? ConfigurableSource ?: throw Failure("source_not_configurable")
                    val preferences = context.getSharedPreferences("source_$sourceId", 0)
                    val screen = PreferenceScreen(context, preferences)
                    try {
                        configurable.setupPreferenceScreen(screen)
                        currentCoroutineContext().ensureActive()
                        snapshotOf(screen) // Validate the initial model before publishing the session.
                        ready.complete(Unit)
                        for (command in commands) {
                            if (!command.result.isActive) continue
                            try {
                                currentCoroutineContext().ensureActive()
                                val reply = process(screen, command.action)
                                currentCoroutineContext().ensureActive()
                                command.result.complete(reply)
                            } catch (error: InvalidRequest) {
                                command.result.completeExceptionally(Failure(error.code))
                            } catch (error: Throwable) {
                                command.result.completeExceptionally(Failure(codeFor(error)))
                                throw error
                            }
                        }
                    } finally { screen.close() }
                }
            } catch (error: Throwable) {
                failureCode = codeFor(error)
                ready.completeExceptionally(Failure(failureCode))
                if (error is VirtualMachineError) throw error
            } finally {
                commands.cancel(CancellationException("Source preference session ended"))
                owner.complete()
            }
        }
    }

    suspend fun snapshot(): Snapshot = exchange(Action.Read).screen
    suspend fun change(row: Int, value: Value): Change {
        val reply = exchange(Action.Set(row, freeze(value)))
        return Change(reply.accepted, reply.screen)
    }
    suspend fun validateText(row: Int, text: String): Validation {
        validateString(text)
        val reply = exchange(Action.Validate(row, text))
        return Validation(reply.accepted, reply.error, reply.text, reply.screen)
    }
    suspend fun click(row: Int): Change {
        val reply = exchange(Action.Click(row))
        return Change(reply.accepted, reply.screen)
    }
    fun close() { owner.cancel(CancellationException("Source preferences closed")) }
    suspend fun closeAndJoin() {
        close()
        withContext(NonCancellable) { owner.join() }
    }
    val isClosed: Boolean get() = owner.isCompleted

    private suspend fun exchange(action: Action): Reply {
        currentCoroutineContext().ensureActive()
        val result = CompletableDeferred<Reply>()
        try {
            commands.send(Command(action, result))
            return result.await()
        } catch (error: CancellationException) {
            currentCoroutineContext().ensureActive()
            throw Failure(failureCode)
        } finally { if (!result.isCompleted) result.cancel() }
    }

    private fun process(screen: PreferenceScreen, action: Action): Reply {
        if (action is Action.Read) return Reply(snapshotOf(screen))
        val id = when (action) {
            is Action.Set -> action.row
            is Action.Validate -> action.row
            is Action.Click -> action.row
            Action.Read -> error("Read handled above")
        }
        val row = screen.mslRows().getOrNull(id - 1) ?: throw InvalidRequest("preference_not_found")
        val accepted: Boolean
        var error: String? = null
        var text: String? = null
        when (action) {
            is Action.Set -> {
                val raw: Any = when (val value = action.value) {
                    is Value.Toggle -> if (row is TwoStatePreference) value.checked else throw InvalidRequest("invalid_preference_value")
                    is Value.Text -> if (row is EditTextPreference || row is ListPreference) value.text else throw InvalidRequest("invalid_preference_value")
                    is Value.Multiple -> if (row is MultiSelectListPreference) LinkedHashSet(value.values) else throw InvalidRequest("invalid_preference_value")
                }
                accepted = row.mslChange(raw)
            }
            is Action.Validate -> {
                if (row !is EditTextPreference) throw InvalidRequest("preference_not_text")
                if (!row.isEnabled || !row.isVisible) accepted = false else {
                    val validation = row.mslValidateText(action.text)
                    accepted = validation.allowed(); error = validation.error(); text = validation.text()
                    validateString(checkNotNull(text))
                }
            }
            is Action.Click -> accepted = row.mslClick()
            Action.Read -> error("Read handled above")
        }
        return Reply(snapshotOf(screen), accepted, error, text)
    }

    private fun snapshotOf(screen: PreferenceScreen): Snapshot {
        var characters = 0L
        fun text(value: CharSequence?): String? {
            val result = value?.toString() ?: return null
            characters += result.length
            if (characters > 1024 * 1024) throw Failure("preference_snapshot_limit")
            return result
        }
        fun choices(entries: Array<out CharSequence>?, values: Array<out CharSequence>?): List<Choice> {
            if (entries == null && values == null) return emptyList()
            if (entries == null || values == null || entries.size != values.size || entries.size > 2048) {
                throw Failure("invalid_preference_choices")
            }
            return Collections.unmodifiableList(entries.indices.map { Choice(checkNotNull(text(entries[it])), checkNotNull(text(values[it]))) })
        }
        val rows = screen.mslRows().mapIndexed { index, preference ->
            val kind: Kind
            val value: Value?
            val options: List<Choice>
            when (preference) {
                is TwoStatePreference -> {
                    kind = when (preference) {
                        is SwitchPreferenceCompat -> Kind.SWITCH
                        is CheckBoxPreference -> Kind.CHECKBOX
                        else -> Kind.TOGGLE
                    }
                    value = Value.Toggle(preference.isChecked); options = emptyList()
                }
                is EditTextPreference -> { kind = Kind.TEXT; value = text(preference.text)?.let(Value::Text); options = emptyList() }
                is ListPreference -> { kind = Kind.LIST; value = text(preference.value)?.let(Value::Text); options = choices(preference.entries, preference.entryValues) }
                is MultiSelectListPreference -> {
                    kind = Kind.MULTISELECT
                    val values = preference.values.map { checkNotNull(text(it)) }
                    value = Value.Multiple(Collections.unmodifiableSet(LinkedHashSet(values)))
                    options = choices(preference.entries, preference.entryValues)
                }
                else -> { kind = Kind.ACTION; value = null; options = emptyList() }
            }
            val summary = if (preference is TwoStatePreference) {
                (if (preference.isChecked) preference.summaryOn else preference.summaryOff) ?: preference.summary
            } else preference.summary
            Row(index + 1, text(preference.key), kind, text(preference.title), text(summary), preference.isEnabled, preference.isVisible,
                value, options, text((preference as? DialogPreference)?.dialogTitle), text((preference as? DialogPreference)?.dialogMessage))
        }
        return Snapshot(sourceId, Collections.unmodifiableList(rows))
    }

    private fun codeFor(error: Throwable): String = when (error) {
        is Failure -> error.code
        is SourceRegistry.RegistrationException -> "source_unavailable"
        is CancellationException -> "source_preferences_closed"
        else -> "source_preference_callback_failed"
    }

    companion object {
        suspend fun open(registry: SourceRegistry, sourceId: Long): SourcePreferenceSession {
            val session = SourcePreferenceSession(registry, sourceId)
            try { session.start(); session.ready.await(); return session }
            catch (error: Throwable) { session.closeAndJoin(); throw error }
        }
        private fun validateString(value: String) {
            if (value.length > 1024 * 1024 || value.toByteArray(Charsets.UTF_8).size > 1024 * 1024) throw Failure("preference_input_limit")
            var index = 0
            while (index < value.length) {
                val c = value[index++]
                if (c.isHighSurrogate()) {
                    if (index >= value.length || !value[index++].isLowSurrogate()) throw Failure("invalid_preference_unicode")
                } else if (c.isLowSurrogate()) throw Failure("invalid_preference_unicode")
            }
        }
        private fun freeze(value: Value): Value = when (value) {
            is Value.Text -> value.also { validateString(it.text) }
            is Value.Toggle -> value
            is Value.Multiple -> {
                if (value.values.size > 4096) throw Failure("preference_input_limit")
                val result = LinkedHashSet<String>()
                var bytes = 0L
                for (item in value.values) {
                    validateString(item); bytes += item.toByteArray(Charsets.UTF_8).size + 4L
                    if (bytes > 4 * 1024 * 1024) throw Failure("preference_input_limit")
                    result.add(item)
                }
                Value.Multiple(Collections.unmodifiableSet(result))
            }
        }
    }
}
