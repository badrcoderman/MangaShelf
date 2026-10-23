package android.net

/**
 * Encoded URI value carrier for the legacy Page.uri field.
 *
 * This deliberately implements only value construction, text, equality, and
 * ordering. It provides no Android URI parsing, Parcelable, ContentResolver,
 * or platform file permissions. Network code must use its own URL contract.
 */
abstract class Uri protected constructor() : Comparable<Uri> {
    abstract override fun toString(): String

    final override fun equals(other: Any?): Boolean =
        other is Uri && toString() == other.toString()

    final override fun hashCode(): Int = toString().hashCode()

    final override fun compareTo(other: Uri): Int = toString().compareTo(other.toString())

    companion object {
        @JvmField
        val EMPTY: Uri = EncodedUri("")

        /** Retains the encoded representation verbatim; no decoding or normalization. */
        @JvmStatic
        fun parse(uriString: String): Uri = if (uriString.isEmpty()) EMPTY else EncodedUri(uriString)
    }

    private class EncodedUri(private val encoded: String) : Uri() {
        override fun toString(): String = encoded
    }
}
