package dev.waken.bridge_mobile

internal interface UmengPushBackend {
    fun register(onToken: (String) -> Unit, onFailure: () -> Unit)
    fun enable(onComplete: (Boolean) -> Unit)
    fun disable(onComplete: (Boolean) -> Unit)
    fun onAppStart()
}

internal object DisabledUmengPushBackend : UmengPushBackend {
    override fun register(onToken: (String) -> Unit, onFailure: () -> Unit) = onFailure()
    override fun enable(onComplete: (Boolean) -> Unit) = onComplete(false)
    override fun disable(onComplete: (Boolean) -> Unit) = onComplete(true)
    override fun onAppStart() = Unit
}

/** All calls/callbacks run on the main thread; a saved choice is not a registration result. */
internal class UmengPushSession(
    private val backend: UmengPushBackend,
    private val permitted: () -> Boolean,
    private val changed: () -> Unit,
) {
    var status = "off"
        private set
    private var token: String? = null
    val deviceToken: String?
        get() = token?.takeIf { permitted() && status == "registered" }
    val canDeliverNotifications: Boolean
        // A push can cold-start a consented process before its new token callback.
        get() = permitted() && (status == "registering" || status == "registered")
    private var generation = 0
    private var started = false
    private var registering = false
    private var stopping = false
    private var disableAgain = false
    private var stopSequence = 0

    private fun current(revision: Int) = revision == generation && permitted() && !stopping

    fun synchronize() {
        if (!permitted()) {
            if (started && status !in setOf("off", "disabling", "disable_failed")) withdraw()
            return
        }
        if (stopping || status in setOf("registering", "registered", "disable_failed")) return
        val revision = ++generation
        started = true
        registering = true
        token = null
        status = "registering"
        changed()
        try {
            backend.register({ value ->
                if (!current(revision)) {
                    enforceWithdrawal()
                } else if (registering) {
                    registering = false
                    if (value.isBlank()) {
                        failed(revision)
                    } else {
                        try {
                            backend.enable { success ->
                                if (!current(revision)) {
                                    enforceWithdrawal()
                                } else if (status == "registering") {
                                    if (success) {
                                        token = value
                                        status = "registered"
                                        onAppStart()
                                        changed()
                                    } else failed(revision)
                                }
                            }
                        } catch (_: Exception) { failed(revision) }
                    }
                }
            }, {
                if (!current(revision)) enforceWithdrawal()
                else if (registering) failed(revision)
            })
        } catch (_: Exception) { failed(revision) }
    }

    private fun failed(revision: Int) {
        if (!current(revision)) { enforceWithdrawal(); return }
        registering = false
        token = null
        status = "error"
        changed()
    }

    fun onAppStart() {
        if (permitted() && status == "registered") {
            try { backend.onAppStart() } catch (_: Exception) { /* No SDK details enter the UI. */ }
        }
    }

    fun withdraw() {
        ++generation
        registering = false
        token = null
        if (!started) { status = "off"; changed(); return }
        stop()
    }

    private fun enforceWithdrawal() {
        // An enable/register callback may arrive after the first disable completed.
        if (!permitted()) {
            if (stopping) disableAgain = true else stop()
        }
    }

    private fun stop() {
        if (stopping) return
        stopping = true
        status = "disabling"
        changed()
        val sequence = ++stopSequence
        val complete: (Boolean) -> Unit = { success ->
            if (stopping && sequence == stopSequence) {
                stopping = false
                status = if (success) "off" else "disable_failed"
                changed()
                if (disableAgain) {
                    disableAgain = false
                    stop()
                } else if (success && permitted()) synchronize()
            }
        }
        try { backend.disable(complete) } catch (_: Exception) { complete(false) }
    }
}
