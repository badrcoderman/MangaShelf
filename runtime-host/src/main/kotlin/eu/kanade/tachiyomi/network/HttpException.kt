package eu.kanade.tachiyomi.network

import java.time.Instant
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter

// Retain the JVM (Int) constructor used by already compiled extensions.
class HttpException @JvmOverloads constructor(val code: Int, val retryAfterSeconds: Double? = null) : IllegalStateException("HTTP $code") {
    companion object {
        fun retryAfter(value: String?, now: Instant = Instant.now()): Double? {
            if (value == null || value.length > 128) return null
            val text = value.trim()
            text.toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 && it <= 3_153_600_000 }?.let { return it }
            return try {
                val date = ZonedDateTime.parse(text, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant()
                ((date.toEpochMilli() - now.toEpochMilli()) / 1000.0).coerceAtLeast(0.0)
            } catch (_: Exception) { null }
        }
    }
}
