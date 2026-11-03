package org.rustls.platformverifier

import java.security.cert.CertPathValidatorException
import java.security.cert.PKIXRevocationChecker
import java.util.EnumSet

internal enum class RevocationFailure { REVOKED, EXPIRED, INVALID }

internal object RevocationPolicy {
    const val CONNECT_TIMEOUT_SECONDS = 3
    const val AUTHORITY_INFORMATION_ACCESS = "1.3.6.1.5.5.7.1.1"
    private val ocspAccessMethod = byteArrayOf(0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x01)

    fun options(
        stapledOcsp: ByteArray?,
        authorityInformationAccess: ByteArray?,
    ): EnumSet<PKIXRevocationChecker.Option> {
        val options = EnumSet.of(
            PKIXRevocationChecker.Option.SOFT_FAIL,
            PKIXRevocationChecker.Option.ONLY_END_ENTITY,
        )
        if ((stapledOcsp == null || stapledOcsp.isEmpty()) && !hasOcspResponder(authorityInformationAccess)) {
            // A missing OCSP URL is not a revocation. Do not fall back to it when
            // a CRL fetch soft-fails; confirmed revocations still fail in PKIX.
            options.add(PKIXRevocationChecker.Option.PREFER_CRLS)
            options.add(PKIXRevocationChecker.Option.NO_FALLBACK)
        }
        return options
    }

    fun failure(error: CertPathValidatorException): RevocationFailure = when (error.reason) {
        CertPathValidatorException.BasicReason.REVOKED -> RevocationFailure.REVOKED
        CertPathValidatorException.BasicReason.EXPIRED,
        CertPathValidatorException.BasicReason.NOT_YET_VALID -> RevocationFailure.EXPIRED
        else -> RevocationFailure.INVALID
    }

    private fun hasOcspResponder(extension: ByteArray?): Boolean {
        if (extension == null) return false
        val outer = DerReader(extension)
        val value = outer.read(0x04)
        outer.requireEnd()
        val encoded = DerReader(value)
        val descriptions = DerReader(encoded.read(0x30))
        encoded.requireEnd()
        var found = false
        while (!descriptions.finished) {
            val entry = DerReader(descriptions.read(0x30))
            val method = entry.read(0x06)
            entry.read()
            entry.requireEnd()
            if (method.contentEquals(ocspAccessMethod)) found = true
        }
        return found
    }

    private class DerReader(private val bytes: ByteArray) {
        private var offset = 0
        val finished: Boolean get() = offset == bytes.size

        fun requireEnd() = require(finished) { "Malformed authority information access" }

        fun read(expectedTag: Int? = null): ByteArray {
            require(bytes.size - offset >= 2) { "Truncated authority information access" }
            val tag = bytes[offset++].toInt() and 0xff
            require(tag and 0x1f != 0x1f) { "Unsupported authority information access tag" }
            require(expectedTag == null || tag == expectedTag) { "Invalid authority information access tag" }
            val first = bytes[offset++].toInt() and 0xff
            var length = first.toLong()
            if (first and 0x80 != 0) {
                val count = first and 0x7f
                require(count in 1..4 && count <= bytes.size - offset) { "Invalid DER length" }
                require(bytes[offset].toInt() and 0xff != 0) { "Non-canonical DER length" }
                length = 0
                repeat(count) { length = (length shl 8) or (bytes[offset++].toLong() and 0xff) }
                require(length >= 128) { "Non-canonical DER length" }
            }
            require(length <= (bytes.size - offset).toLong()) { "Truncated DER value" }
            val end = offset + length.toInt()
            return bytes.copyOfRange(offset, end).also { offset = end }
        }
    }
}
