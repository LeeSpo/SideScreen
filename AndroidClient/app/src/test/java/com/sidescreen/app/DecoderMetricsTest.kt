package com.sidescreen.app

import org.junit.Assert.*
import org.junit.Test

class DecoderMetricsTest {
    @Test fun delayedOutputIsMeasuredFromReceiveSeparatelyFromQueueAndSurface() {
        val logs = mutableListOf<String>()
        val metrics = DecoderMetrics("test", { 1_000_000_000L }, logs::add)
        metrics.received()
        metrics.queued(7, 100_000_000, 120_000_000)
        metrics.output(7, 160_000_000, true)
        metrics.presented(7, 170_000_000)
        metrics.log()
        val result = logs.last()
        assertTrue(result.contains("\"receiveToOutputMs\":[60.000]"))
        assertTrue(result.contains("\"queueToOutputMs\":[40.000]"))
        assertTrue(result.contains("\"outputToSurfaceMs\":[10.000]"))
        assertTrue(result.contains("\"presented\":1"))
        assertTrue(result.contains("\"invalid\":0"))
    }

    @Test fun frameReorderingAndDropsCannotInventPresentedFramesOrLoseCumulativeCounts() {
        val logs = mutableListOf<String>()
        val metrics = DecoderMetrics("test", { 1_000_000_000L }, logs::add)
        for (id in 1L..3L) {
            metrics.received()
            metrics.queued(id, 100_000_000, 110_000_000)
        }
        metrics.output(2, 120_000_000, true)
        metrics.output(1, 130_000_000, false)
        metrics.output(3, 140_000_000, true)
        metrics.presented(3, 150_000_000)
        metrics.presented(2, 160_000_000)
        metrics.log()
        assertTrue(logs.last().contains("\"output\":3,\"submitted\":2,\"presented\":2,\"stale\":1"))
        metrics.log()
        assertTrue(logs.last().contains("\"presented\":2"))
        assertTrue(logs.last().contains("\"receiveToOutputMs\":[]"))
    }

    @Test fun unknownOrInvalidTimestampsAreReportedInsteadOfSilentlyPassingLatencyChecks() {
        val logs = mutableListOf<String>()
        val metrics = DecoderMetrics("test", { 1_000_000_000L }, logs::add)
        metrics.queued(1, 500_000_000, 600_000_000)
        metrics.output(1, 100_000_000, true)
        metrics.presented(9, 700_000_000)
        metrics.log()
        assertTrue(logs.last().contains("\"invalid\":3"))
        assertTrue(logs.last().contains("\"receiveToOutputMs\":[]"))
    }
}
