package dev.waken.bridge_mobile

import org.junit.Assert.*
import org.junit.Test

class CloudReceiptPolicyTest {
    private val id = "00000000-0000-4000-8000-000000000001"
    @Test fun identitiesAndRoutesAreCanonicalAndBounded() {
        assertTrue(CloudReceiptPolicy.id(id))
        assertFalse(CloudReceiptPolicy.id("0-0-4-8-1"))
        assertTrue(CloudReceiptPolicy.route("a".repeat(64), "cloud:$id", id))
        assertFalse(CloudReceiptPolicy.route("A".repeat(64), "cloud:$id", id))
        assertFalse(CloudReceiptPolicy.route("a".repeat(64), "file:///private", id))
    }
    @Test fun expiryAndDedupRetentionDoNotReviveExpiredNotifications() {
        assertTrue(CloudReceiptPolicy.live(1060, 1000))
        assertFalse(CloudReceiptPolicy.live(1000, 1000))
        assertFalse(CloudReceiptPolicy.live(4601, 1000))
        assertTrue(CloudReceiptPolicy.retained(1000, 2000))
        assertFalse(CloudReceiptPolicy.retained(1000, 4600))
        assertEquals(4096, CloudReceiptPolicy.LIMIT)
    }
}
