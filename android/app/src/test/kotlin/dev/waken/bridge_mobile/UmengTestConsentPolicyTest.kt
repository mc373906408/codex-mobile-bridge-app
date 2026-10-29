package dev.waken.bridge_mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UmengTestConsentPolicyTest {
    @Test fun onlyLenovoDebugBuildsAreEligible() {
        assertTrue(UmengTestConsentPolicy.eligible(true, "LENOVO", "Lenovo"))
        assertTrue(UmengTestConsentPolicy.eligible(true, "unknown", "lenovo"))
        assertFalse(UmengTestConsentPolicy.eligible(false, "LENOVO", "Lenovo"))
        assertFalse(UmengTestConsentPolicy.eligible(true, "Google", "google"))
        assertFalse(UmengTestConsentPolicy.eligible(true, "Samsung", "samsung"))
        assertFalse(UmengTestConsentPolicy.eligible(true, "", ""))
        assertFalse(UmengTestConsentPolicy.eligible(true, "LENOVO", "Lenovo", configured = false))
    }

    @Test fun noChoiceOrUnknownChoiceNeverMeansConsent() {
        for (value in listOf(null, "", "yes", "true", "unknown")) {
            assertEquals("pending", UmengTestConsentPolicy.decision(true, UmengTestConsentPolicy.NOTICE_VERSION, value))
        }
    }

    @Test fun aChangedNoticeNeedsANewDecision() {
        assertEquals("pending", UmengTestConsentPolicy.decision(true, "lenovo-upush-test-v1", "accepted"))
        assertEquals("pending", UmengTestConsentPolicy.decision(true, "older-notice", "accepted"))
        assertEquals("pending", UmengTestConsentPolicy.decision(true, null, "accepted"))
        assertEquals("pending", UmengTestConsentPolicy.decision(true, "older-notice", "declined"))
    }

    @Test fun anotherDeviceOrReleaseBuildCannotReuseATestGrant() {
        assertEquals("pending", UmengTestConsentPolicy.decision(false, UmengTestConsentPolicy.NOTICE_VERSION, "accepted"))
    }

    @Test fun explicitCurrentDecisionsSurviveRestart() {
        for (value in listOf("accepted", "declined")) {
            assertEquals(value, UmengTestConsentPolicy.decision(true, UmengTestConsentPolicy.NOTICE_VERSION, value))
        }
    }
}
