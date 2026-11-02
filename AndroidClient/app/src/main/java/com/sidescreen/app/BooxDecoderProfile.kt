package com.sidescreen.app

/** Ordered experiments for this fork; unsupported vendor keys never reach other vendors. */
enum class BooxDecoderProfile(val id: String) {
    QCOM_ORDER("qcom-order"),
    QCOM_LOW_LATENCY("qcom-low-latency"),
    STANDARD("standard"),
    COMPATIBLE("compatible"),
    ;

    companion object {
        fun fromId(id: String?): BooxDecoderProfile = entries.firstOrNull { it.id == id } ?: QCOM_ORDER
    }
}
