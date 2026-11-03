package org.rustls.platformverifier

import java.security.cert.CertPathValidatorException
import java.security.cert.PKIXRevocationChecker.Option
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RevocationPolicyTest {
    private val ocspOid = byteArrayOf(0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x01)
    private val issuerOid = byteArrayOf(0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x02)

    private fun der(tag: Int, value: ByteArray): ByteArray {
        val length = if (value.size < 128) byteArrayOf(value.size.toByte())
            else byteArrayOf(0x81.toByte(), value.size.toByte())
        return byteArrayOf(tag.toByte()) + length + value
    }

    private fun access(oid: ByteArray, url: String) = der(0x30, der(0x06, oid) + der(0x86, url.toByteArray()))
    private fun aia(vararg descriptions: ByteArray) = der(0x04, der(0x30, descriptions.fold(byteArrayOf()) { a, b -> a + b }))

    @Test
    fun crlOnlyCertificatesDoNotFallBackToMissingOcsp() {
        val extensions = listOf(null, aia(), aia(access(issuerOid, "http://ca.example/issuer")))
        for (extension in extensions) {
            val options = RevocationPolicy.options(null, extension)
            assertTrue(options.contains(Option.PREFER_CRLS))
            assertTrue(options.contains(Option.NO_FALLBACK))
            assertTrue(options.contains(Option.SOFT_FAIL))
            assertTrue(options.contains(Option.ONLY_END_ENTITY))
        }
    }

    @Test
    fun publishedOrStapledOcspKeepsNormalVerification() {
        val extension = aia(
            access(issuerOid, "http://ca.example/issuer"),
            access(ocspOid, "http://ca.example/ocsp"),
        )
        for (options in listOf(
            RevocationPolicy.options(null, extension),
            RevocationPolicy.options(byteArrayOf(1), null),
        )) {
            assertFalse(options.contains(Option.NO_FALLBACK))
            assertFalse(options.contains(Option.PREFER_CRLS))
            assertTrue(options.contains(Option.SOFT_FAIL))
        }
    }

    @Test
    fun longFormDerDoesNotHideAnOcspResponder() {
        val extension = aia(access(ocspOid, "http://ca.example/" + "x".repeat(128)))
        assertFalse(RevocationPolicy.options(null, extension).contains(Option.NO_FALLBACK))
    }

    @Test(expected = IllegalArgumentException::class)
    fun malformedAiaFailsClosed() {
        RevocationPolicy.options(null, byteArrayOf(0x04, 0x06, 0x30, 0x04, 0x30))
    }

    @Test(expected = IllegalArgumentException::class)
    fun trailingAiaBytesFailClosed() {
        RevocationPolicy.options(null, aia() + byteArrayOf(0))
    }

    @Test
    fun revocationIsNotConfusedWithNetworkOrOtherPathFailures() {
        fun error(reason: CertPathValidatorException.Reason) =
            CertPathValidatorException("Test certificate failure", null, null, -1, reason)
        assertEquals(RevocationFailure.REVOKED, RevocationPolicy.failure(error(CertPathValidatorException.BasicReason.REVOKED)))
        assertEquals(RevocationFailure.EXPIRED, RevocationPolicy.failure(error(CertPathValidatorException.BasicReason.EXPIRED)))
        assertEquals(RevocationFailure.INVALID, RevocationPolicy.failure(error(CertPathValidatorException.BasicReason.UNDETERMINED_REVOCATION_STATUS)))
        assertEquals(RevocationFailure.INVALID, RevocationPolicy.failure(error(CertPathValidatorException.BasicReason.INVALID_SIGNATURE)))
        assertEquals(RevocationFailure.INVALID, RevocationPolicy.failure(error(CertPathValidatorException.BasicReason.UNSPECIFIED)))
    }
}
