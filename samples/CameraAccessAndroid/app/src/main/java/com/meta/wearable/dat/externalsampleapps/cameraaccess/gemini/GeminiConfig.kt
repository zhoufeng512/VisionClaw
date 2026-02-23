package com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini

import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager

object GeminiConfig {
    const val WEBSOCKET_BASE_URL = "wss://openspeech.bytedance.com/api/v3/realtime/dialogue"
    const val MODEL = "doubao-realtime"

    const val INPUT_AUDIO_SAMPLE_RATE = 16000
    const val OUTPUT_AUDIO_SAMPLE_RATE = 24000
    const val AUDIO_CHANNELS = 1
    const val AUDIO_BITS_PER_SAMPLE = 16

    const val VIDEO_FRAME_INTERVAL_MS = 1000L
    const val VIDEO_JPEG_QUALITY = 50

    val systemInstruction: String
        get() = SettingsManager.geminiSystemPrompt

    val doubaoAppId: String
        get() = SettingsManager.doubaoAppId

    val doubaoAccessKey: String
        get() = SettingsManager.doubaoAccessKey

    val doubaoAppKey: String
        get() = SettingsManager.doubaoAppKey

    val doubaoResourceId: String
        get() = SettingsManager.doubaoResourceId

    val openClawHost: String
        get() = SettingsManager.openClawHost

    val openClawPort: Int
        get() = SettingsManager.openClawPort

    val openClawHookToken: String
        get() = SettingsManager.openClawHookToken

    val openClawGatewayToken: String
        get() = SettingsManager.openClawGatewayToken

    fun websocketURL(): String? {
        if (doubaoAppId == "YOUR_DOUBAO_APP_ID" || doubaoAppId.isEmpty()) return null
        return WEBSOCKET_BASE_URL
    }

    val isConfigured: Boolean
        get() = doubaoAppId != "YOUR_DOUBAO_APP_ID" && doubaoAppId.isNotEmpty()

    val isOpenClawConfigured: Boolean
        get() = openClawGatewayToken != "YOUR_OPENCLAW_GATEWAY_TOKEN"
                && openClawGatewayToken.isNotEmpty()
                && openClawHost != "http://YOUR_MAC_HOSTNAME.local"
}
