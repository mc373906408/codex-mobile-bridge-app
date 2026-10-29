package dev.waken.bridge_mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UmengPushSessionTest {
    private class Backend : UmengPushBackend {
        val tokens = mutableListOf<(String) -> Unit>()
        val failures = mutableListOf<() -> Unit>()
        val enables = mutableListOf<(Boolean) -> Unit>()
        val disables = mutableListOf<(Boolean) -> Unit>()
        var starts = 0
        var registerError = false
        override fun register(onToken: (String) -> Unit, onFailure: () -> Unit) {
            if (registerError) error("Private SDK error")
            tokens += onToken
            failures += onFailure
        }
        override fun enable(onComplete: (Boolean) -> Unit) { enables += onComplete }
        override fun disable(onComplete: (Boolean) -> Unit) { disables += onComplete }
        override fun onAppStart() { starts++ }
    }

    @Test fun noSdkCallsBeforeCurrentConsent() {
        val backend = Backend()
        val session = UmengPushSession(backend, { false }, {})
        session.synchronize()
        session.onAppStart()
        session.withdraw()
        assertEquals("off", session.status)
        assertNull(session.deviceToken)
        assertFalse(session.canDeliverNotifications)
        assertEquals(0, backend.tokens.size + backend.enables.size + backend.disables.size + backend.starts)
    }

    @Test fun consentedColdStartCanDisplayBeforeTheTokenCallback() {
        val backend = Backend()
        val session = UmengPushSession(backend, { true }, {})
        assertFalse(session.canDeliverNotifications)
        session.synchronize()
        assertEquals("registering", session.status)
        assertNull(session.deviceToken)
        assertTrue(session.canDeliverNotifications)
        backend.tokens[0]("test-token")
        assertNull(session.deviceToken)
        assertTrue(session.canDeliverNotifications)
        backend.enables[0](true)
        assertTrue(session.canDeliverNotifications)
    }

    @Test fun withdrawalBlocksDisplayDuringShutdownEvenIfConsentIsRestored() {
        var permitted = true
        val backend = Backend()
        val session = UmengPushSession(backend, { permitted }, {})
        session.synchronize()
        assertTrue(session.canDeliverNotifications)
        permitted = false
        assertFalse(session.canDeliverNotifications)
        session.withdraw()
        permitted = true
        assertFalse(session.canDeliverNotifications)
        session.synchronize()
        assertFalse(session.canDeliverNotifications)
        backend.disables[0](false)
        assertEquals("disable_failed", session.status)
        assertFalse(session.canDeliverNotifications)
    }

    @Test fun consentIsNotRegistrationAndStartupIsIdempotent() {
        val backend = Backend()
        val session = UmengPushSession(backend, { true }, {})
        session.synchronize()
        session.synchronize()
        session.onAppStart()
        assertEquals("registering", session.status)
        assertNull(session.deviceToken)
        assertEquals(1, backend.tokens.size)
        assertEquals(0, backend.starts)
        backend.tokens[0]("test-token")
        assertNull(session.deviceToken)
        backend.enables[0](true)
        assertEquals("registered", session.status)
        assertEquals("test-token", session.deviceToken)
        session.synchronize()
        session.onAppStart()
        assertEquals(1, backend.tokens.size)
        assertEquals(2, backend.starts)
    }

    @Test fun lateRegistrationAfterWithdrawalNeverEnablesPush() {
        var permitted = true
        val backend = Backend()
        val session = UmengPushSession(backend, { permitted }, {})
        session.synchronize()
        permitted = false
        session.withdraw()
        assertNull(session.deviceToken)
        backend.disables[0](true)
        backend.tokens[0]("old-token")
        assertEquals(0, backend.enables.size)
        assertEquals(2, backend.disables.size)
        backend.disables[1](true)
        assertEquals("off", session.status)
        assertNull(session.deviceToken)
    }

    @Test fun lateEnableRequiresAnotherDisableEvenAfterFirstShutdown() {
        var permitted = true
        val backend = Backend()
        val session = UmengPushSession(backend, { permitted }, {})
        session.synchronize()
        backend.tokens[0]("old-token")
        permitted = false
        session.withdraw()
        backend.disables[0](true)
        backend.enables[0](true)
        assertEquals(2, backend.disables.size)
        assertEquals(0, backend.starts)
        backend.disables[1](true)
        assertEquals("off", session.status)
        assertNull(session.deviceToken)
    }

    @Test fun callbackDuringShutdownSchedulesCleanupAfterIt() {
        var permitted = true
        val backend = Backend()
        val session = UmengPushSession(backend, { permitted }, {})
        session.synchronize()
        permitted = false
        session.withdraw()
        backend.tokens[0]("old-token")
        assertEquals(1, backend.disables.size)
        backend.disables[0](true)
        assertEquals(2, backend.disables.size)
        backend.disables[1](true)
        assertEquals("off", session.status)
    }

    @Test fun aNewGrantWaitsForShutdownAndCannotUseAnOldToken() {
        var permitted = true
        val backend = Backend()
        val session = UmengPushSession(backend, { permitted }, {})
        session.synchronize()
        permitted = false
        session.withdraw()
        permitted = true
        session.synchronize()
        assertEquals(1, backend.tokens.size)
        backend.disables[0](true)
        assertEquals(2, backend.tokens.size)
        backend.tokens[0]("old-token")
        assertEquals(0, backend.enables.size)
        backend.tokens[1]("new-token")
        backend.enables[0](true)
        assertEquals("new-token", session.deviceToken)
    }

    @Test fun anUnconfirmedShutdownCannotRestartPushInTheSameProcess() {
        var permitted = true
        val backend = Backend()
        val session = UmengPushSession(backend, { permitted }, {})
        session.synchronize()
        backend.tokens[0]("test-token")
        backend.enables[0](true)
        permitted = false
        session.withdraw()
        assertNull(session.deviceToken)
        backend.disables[0](false)
        permitted = true
        session.synchronize()
        assertEquals("disable_failed", session.status)
        assertEquals(1, backend.tokens.size)
        assertNull(session.deviceToken)
    }

    @Test fun blankTokensAndSdkErrorsAreNotRegistrationResults() {
        for (blank in listOf("", " ")) {
            val backend = Backend()
            val session = UmengPushSession(backend, { true }, {})
            session.synchronize()
            backend.tokens[0](blank)
            assertEquals("error", session.status)
            assertNull(session.deviceToken)
            assertFalse(session.canDeliverNotifications)
            assertEquals(0, backend.enables.size)
        }
        val backend = Backend().apply { registerError = true }
        val session = UmengPushSession(backend, { true }, {})
        session.synchronize()
        assertEquals("error", session.status)
        assertFalse(session.canDeliverNotifications)
        assertFalse(session.status.contains("Private"))
    }

    @Test fun duplicateRegistrationCallbacksDoNotEnableTwice() {
        val backend = Backend()
        val session = UmengPushSession(backend, { true }, {})
        session.synchronize()
        backend.tokens[0]("test-token")
        backend.tokens[0]("other-token")
        backend.failures[0]()
        assertEquals(1, backend.enables.size)
        backend.enables[0](true)
        assertEquals("test-token", session.deviceToken)
    }
}
