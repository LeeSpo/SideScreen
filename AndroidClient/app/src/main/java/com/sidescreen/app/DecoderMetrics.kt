package com.sidescreen.app

import java.util.concurrent.ConcurrentHashMap

/** All stage timestamps are Android monotonic time; Mac clocks are never subtracted. */
class DecoderMetrics(
    private val label: String,
    private val clockNs: () -> Long = System::nanoTime,
    private val emit: (String) -> Unit = { DiagLog.log("BOOXMETRICS", it) },
) {
    private data class Timing(val receivedNs: Long, val queuedNs: Long, var outputNs: Long = 0)
    private val pending = ConcurrentHashMap<Long, Timing>()
    private var received = 0L
    private var queued = 0L
    private var output = 0L
    private var submitted = 0L
    private var presented = 0L
    private var stale = 0L
    private var waiting = 0L
    private var exhausted = 0L
    private var invalid = 0L
    private var startedNs = clockNs()
    private var lastLogNs = startedNs
    private val receiveToOutput = ArrayList<Double>()
    private val queueToOutput = ArrayList<Double>()
    private val outputToSurface = ArrayList<Double>()

    @Synchronized fun received() { received++ }

    @Synchronized fun queued(ptsUs: Long, receivedNs: Long, queuedNs: Long) {
        queued++
        pending[ptsUs] = Timing(receivedNs, queuedNs)
        if (pending.size > 256) {
            pending.keys.minOrNull()?.let { pending.remove(it) }
        }
    }

    @Synchronized fun output(ptsUs: Long, nowNs: Long, render: Boolean) {
        output++
        val t = pending[ptsUs]
        if (t != null) {
            t.outputNs = nowNs
            addSample(receiveToOutput, nowNs - t.receivedNs)
            addSample(queueToOutput, nowNs - t.queuedNs)
        } else invalid++
        if (render) submitted++ else {
            stale++
            pending.remove(ptsUs)
        }
        maybeLog(nowNs)
    }

    @Synchronized fun presented(ptsUs: Long, surfaceNs: Long) {
        presented++
        val t = pending.remove(ptsUs)
        if (t != null && t.outputNs > 0) addSample(outputToSurface, surfaceNs - t.outputNs) else invalid++
        maybeLog(clockNs())
    }

    @Synchronized fun droppedForKeyframe() { waiting++ }
    @Synchronized fun droppedForInput() { exhausted++ }

    private fun addSample(samples: MutableList<Double>, ns: Long) {
        if (ns >= 0 && ns <= 10_000_000_000L) samples.add(ns / 1_000_000.0) else invalid++
    }

    private fun maybeLog(nowNs: Long) {
        if (nowNs - lastLogNs >= 2_000_000_000L) log()
    }

    @Synchronized fun log() {
        fun array(values: List<Double>) = values.joinToString(prefix = "[", postfix = "]") {
            java.lang.String.format(java.util.Locale.US, "%.3f", it)
        }
        val nowNs = clockNs()
        emit("{\"profile\":\"$label\",\"elapsedMs\":${(nowNs - startedNs) / 1_000_000}," +
            "\"received\":$received,\"queued\":$queued,\"output\":$output,\"submitted\":$submitted," +
            "\"presented\":$presented,\"stale\":$stale,\"waiting\":$waiting,\"exhausted\":$exhausted," +
            "\"invalid\":$invalid,\"receiveToOutputMs\":${array(receiveToOutput)}," +
            "\"queueToOutputMs\":${array(queueToOutput)},\"outputToSurfaceMs\":${array(outputToSurface)}}")
        receiveToOutput.clear()
        queueToOutput.clear()
        outputToSurface.clear()
        lastLogNs = nowNs
    }
}
