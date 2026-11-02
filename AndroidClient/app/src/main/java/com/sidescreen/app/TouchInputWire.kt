package com.sidescreen.app

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** A copied touch sample: never retain a recycled MotionEvent in the network queue. */
internal data class TouchInputContact(
    val id: Int,
    val x: Float,
    val y: Float,
    val tool: Int,
)

internal data class TouchInputFrame(
    val eventTimeMs: Long,
    val phase: Int,
    val changedPointerId: Int,
    val viewportWidthDp: Float,
    val viewportHeightDp: Float,
    val contacts: List<TouchInputContact>,
) {
    fun encode(sessionToken: Long, sequence: Long): ByteArray {
        val payloadLength = 38 + contacts.size * 13
        return ByteBuffer.allocate(3 + payloadLength).order(ByteOrder.LITTLE_ENDIAN).apply {
            put(MESSAGE_FRAME.toByte())
            putShort(payloadLength.toShort())
            putLong(sessionToken)
            putLong(sequence)
            putLong(eventTimeMs)
            put(phase.toByte())
            putInt(changedPointerId)
            putFloat(viewportWidthDp)
            putFloat(viewportHeightDp)
            put(contacts.size.toByte())
            contacts.forEach {
                putInt(it.id)
                putFloat(it.x)
                putFloat(it.y)
                put(it.tool.toByte())
            }
        }.array()
    }

    companion object {
        const val DOWN = 0
        const val MOVE = 1
        const val UP = 2
        const val CANCEL = 3
        const val POINTER_DOWN = 4
        const val POINTER_UP = 5
        const val MESSAGE_CAPABILITY = 19
        const val MESSAGE_ACCEPTED = 20
        const val MESSAGE_FRAME = 21
    }
}
