package dev.waken.bridge_mobile

import org.junit.Assert.*
import org.junit.Test

class CloudNotificationConsentPolicyTest {
    @Test fun productionCannotReuseTrialOrSdkFreeConsent() {
        assertFalse(CloudNotificationConsentPolicy.accepted(true, "lenovo-upush-test-v2", "accepted"))
        assertFalse(CloudNotificationConsentPolicy.accepted(true, "cloud-notifications-v1", "accepted"))
        assertTrue(CloudNotificationConsentPolicy.accepted(true, "cloud-umeng-push-v1", "accepted"))
        assertFalse(CloudNotificationConsentPolicy.accepted(false, "cloud-umeng-push-v1", "accepted"))
    }
    @Test fun onlyCurrentExplicitAcceptanceEnablesNotifications() {
        assertFalse(CloudNotificationConsentPolicy.accepted(false, null, "accepted"))
        assertFalse(CloudNotificationConsentPolicy.accepted(false, "cloud-notifications-v1", "declined"))
        assertTrue(CloudNotificationConsentPolicy.accepted(false, "cloud-notifications-v1", "accepted"))
    }
}
