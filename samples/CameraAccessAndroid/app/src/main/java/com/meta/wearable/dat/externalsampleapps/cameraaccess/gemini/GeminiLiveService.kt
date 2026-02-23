package com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini

import android.graphics.Bitmap
import android.util.Base64
import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.GeminiToolCall
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.GeminiToolCallCancellation
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolDeclarations
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.Timer
import java.util.TimerTask
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONArray
import org.json.JSONObject

sealed class GeminiConnectionState {
    data object Disconnected : GeminiConnectionState()
    data object Connecting : GeminiConnectionState()
    data object SettingUp : GeminiConnectionState()
    data object Ready : GeminiConnectionState()
    data class Error(val message: String) : GeminiConnectionState()
}

class GeminiLiveService {
    companion object {
        private const val TAG = "GeminiLiveService"
        
        // Protocol Constants
        private const val PROTOCOL_VERSION = 0x01
        
        // Message Types
        private const val CLIENT_FULL_REQUEST = 0x01
        private const val CLIENT_AUDIO_ONLY_REQUEST = 0x02
        private const val SERVER_FULL_RESPONSE = 0x09
        private const val SERVER_ACK = 0x0b
        private const val SERVER_ERROR_RESPONSE = 0x0f

        // Message Flags
        private const val MSG_WITH_EVENT = 0x02
        private val NO_SEQUENCE = byteArrayOf(0x00, 0x00, 0x00, 0x00)

        // Serialization Types
        private const val JSON_SERIALIZATION = 0x01

        // Compression Types
        private const val GZIP_COMPRESSION = 0x01

        fun uuid(): String = java.util.UUID.randomUUID().toString()
    }

    private val _connectionState = MutableStateFlow<GeminiConnectionState>(GeminiConnectionState.Disconnected)
    val connectionState: StateFlow<GeminiConnectionState> = _connectionState.asStateFlow()

    private val _isModelSpeaking = MutableStateFlow(false)
    val isModelSpeaking: StateFlow<Boolean> = _isModelSpeaking.asStateFlow()

    var onAudioReceived: ((ByteArray) -> Unit)? = null
    var onTurnComplete: (() -> Unit)? = null
    var onInterrupted: (() -> Unit)? = null
    var onDisconnected: ((String?) -> Unit)? = null
    var onInputTranscription: ((String) -> Unit)? = null
    var onOutputTranscription: ((String) -> Unit)? = null
    var onToolCall: ((GeminiToolCall) -> Unit)? = null
    var onToolCallCancellation: ((GeminiToolCallCancellation) -> Unit)? = null

    // Latency tracking
    private var lastUserSpeechEnd: Long = 0
    private var responseLatencyLogged = false

    private var webSocket: WebSocket? = null
    private val sendExecutor = Executors.newSingleThreadExecutor()
    private var connectCallback: ((Boolean) -> Unit)? = null
    private var timeoutTimer: Timer? = null

    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(10, TimeUnit.SECONDS)
        .build()

    fun connect(callback: (Boolean) -> Unit) {
        val url = GeminiConfig.websocketURL()
        if (url == null) {
            _connectionState.value = GeminiConnectionState.Error("No API key configured")
            callback(false)
            return
        }

        _connectionState.value = GeminiConnectionState.Connecting
        connectCallback = callback

        val request = Request.Builder().url(url).build()
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.d(TAG, "WebSocket opened")
                _connectionState.value = GeminiConnectionState.SettingUp
                sendSetupMessage()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleMessage(text)
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                handleMessage(bytes.utf8())
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                val msg = t.message ?: "Unknown error"
                Log.e(TAG, "WebSocket failure: $msg")
                _connectionState.value = GeminiConnectionState.Error(msg)
                _isModelSpeaking.value = false
                resolveConnect(false)
                onDisconnected?.invoke(msg)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "WebSocket closing: $code $reason")
                _connectionState.value = GeminiConnectionState.Disconnected
                _isModelSpeaking.value = false
                resolveConnect(false)
                onDisconnected?.invoke("Connection closed (code $code: $reason)")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "WebSocket closed: $code $reason")
                _connectionState.value = GeminiConnectionState.Disconnected
                _isModelSpeaking.value = false
            }
        })

        // Timeout after 15 seconds (use Timer so we don't block sendExecutor)
        timeoutTimer = Timer().apply {
            schedule(object : TimerTask() {
                override fun run() {
                    if (_connectionState.value == GeminiConnectionState.Connecting
                        || _connectionState.value == GeminiConnectionState.SettingUp) {
                        Log.e(TAG, "Connection timed out")
                        _connectionState.value = GeminiConnectionState.Error("Connection timed out")
                        resolveConnect(false)
                    }
                }
            }, 15000)
        }
    }

    fun disconnect() {
        timeoutTimer?.cancel()
        timeoutTimer = null
        webSocket?.close(1000, null)
        webSocket = null
        onToolCall = null
        onToolCallCancellation = null
        _connectionState.value = GeminiConnectionState.Disconnected
        _isModelSpeaking.value = false
        resolveConnect(false)
    }

    fun sendAudio(data: ByteArray) {
        if (_connectionState.value != GeminiConnectionState.Ready) return
        sendExecutor.execute {
            val payloadObj = JSONObject().apply {
                put("type", "input_audio")
            }
            val payloadBytes = gzip(payloadObj.toString().toByteArray())
            val header = generateHeader(
                messageType = CLIENT_AUDIO_ONLY_REQUEST,
                messageFlags = MSG_WITH_EVENT,
                compression = GZIP_COMPRESSION
            )

            val buffer = ByteArrayOutputStream()
            buffer.write(header)
            
            // Write payload size (int32 default byteorder big-endian)
            val pSize = payloadBytes.size
            buffer.write(pSize shr 24)
            buffer.write(pSize shr 16)
            buffer.write(pSize shr 8)
            buffer.write(pSize)
            
            // payload
            buffer.write(payloadBytes)
            
            // Write audio padding size and audio data
            // Audio padding size = len(data), encoded as Int32? Actually Python code writes audio immediately after payload bytes.
            // Let's adapt exactly: `payload` contains header, sequence (0s), payload size, payload bytes, audio bytes
            
            val finalBuffer = ByteArrayOutputStream()
            finalBuffer.write(header)
            finalBuffer.write(NO_SEQUENCE)
            finalBuffer.write(pSize shr 24)
            finalBuffer.write(pSize shr 16)
            finalBuffer.write(pSize shr 8)
            finalBuffer.write(pSize)
            finalBuffer.write(payloadBytes)
            finalBuffer.write(data)
            
            webSocket?.send(finalBuffer.toByteArray().toByteString())
        }
    }

    fun sendVideoFrame(bitmap: Bitmap) {
        if (_connectionState.value != GeminiConnectionState.Ready) return
        sendExecutor.execute {
            // Placeholder: Doubao multimodal WebSocket video framing is not yet available.
        }
    }

    fun sendToolResponse(response: JSONObject) {
        sendTextQuery(response.toString())
    }

    private fun sendTextQuery(text: String) {
        sendExecutor.execute {
            val payloadObj = JSONObject().apply {
                put("type", "input_text")
                put("text", text)
            }
            val payloadBytes = gzip(payloadObj.toString().toByteArray())
            val header = generateHeader(
                messageType = CLIENT_FULL_REQUEST,
                messageFlags = MSG_WITH_EVENT,
                compression = GZIP_COMPRESSION
            )

            val pSize = payloadBytes.size
            val finalBuffer = ByteArrayOutputStream()
            finalBuffer.write(header)
            finalBuffer.write(NO_SEQUENCE)
            finalBuffer.write(pSize shr 24)
            finalBuffer.write(pSize shr 16)
            finalBuffer.write(pSize shr 8)
            finalBuffer.write(pSize)
            finalBuffer.write(payloadBytes)
            
            webSocket?.send(finalBuffer.toByteArray().toByteString())
        }
    }

    // Private

    private fun resolveConnect(success: Boolean) {
        val cb = connectCallback
        connectCallback = null  // null out BEFORE invoking to prevent re-entrancy
        timeoutTimer?.cancel()
        timeoutTimer = null
        cb?.invoke(success)
    }

    private fun generateHeader(
        version: Int = PROTOCOL_VERSION,
        messageType: Int = CLIENT_FULL_REQUEST,
        messageFlags: Int = MSG_WITH_EVENT,
        serialization: Int = JSON_SERIALIZATION,
        compression: Int = GZIP_COMPRESSION
    ): ByteArray {
        val header = ByteArray(4)
        header[0] = ((version and 0x0F) shl 4 or (header[0].toInt() and 0x0F)).toByte()
        header[0] = ((header[0].toInt() and 0xF0) or ((messageType shr 8) and 0x0F)).toByte()
        header[1] = (messageType and 0xFF).toByte()
        header[2] = ((messageFlags and 0x03) shl 6 or (header[2].toInt() and 0x3F)).toByte()
        header[2] = ((header[2].toInt() and 0xC0) or ((serialization and 0x0F) shl 2)).toByte()
        header[2] = ((header[2].toInt() and 0xFC) or (compression and 0x03)).toByte()
        header[3] = 0x00 // Reserved
        return header
    }

    private fun gzip(data: ByteArray): ByteArray {
        val baos = ByteArrayOutputStream()
        val gzos = GZIPOutputStream(baos)
        gzos.write(data)
        gzos.close()
        return baos.toByteArray()
    }

    private fun ungzip(data: ByteArray): ByteArray {
        val bais = ByteArrayInputStream(data)
        val gzis = GZIPInputStream(bais)
        return gzis.readBytes()
    }

    private fun sendSetupMessage() {
        // First msg is Start Connection
        val connectionRequest = JSONObject().apply {
            put("app", JSONObject().apply {
                put("appid", GeminiConfig.doubaoAppId)
                put("token", GeminiConfig.doubaoAccessKey) // Doubao SDK expects token, we map access_key here
                put("cluster", GeminiConfig.doubaoResourceId)
            })
            put("user", JSONObject().apply {
                put("uid", "openclaw_user")
            })
            put("audio", JSONObject().apply {
                put("format", "pcm")
                put("sample_rate", 16000)
                put("channels", 1)
                put("bits", 16)
            })
        }
        
        val connectionPayload = gzip(connectionRequest.toString().toByteArray())
        val connHeader = generateHeader(
            messageType = CLIENT_FULL_REQUEST,
            messageFlags = MSG_WITH_EVENT,
            compression = GZIP_COMPRESSION
        )
        
        var buffer = ByteArrayOutputStream()
        buffer.write(connHeader)
        buffer.write(NO_SEQUENCE)
        var pSize = connectionPayload.size
        buffer.write(pSize shr 24)
        buffer.write(pSize shr 16)
        buffer.write(pSize shr 8)
        buffer.write(pSize)
        buffer.write(connectionPayload)
        
        webSocket?.send(buffer.toByteArray().toByteString())

        // Immediately follow up with Start Session to configure instructions & tools
        val sessionRequest = JSONObject().apply {
            put("type", "update_session")
            put("instructions", GeminiConfig.systemInstruction)
            put("tools", ToolDeclarations.allDeclarationsJSON())
        }
        
        val sessionPayload = gzip(sessionRequest.toString().toByteArray())
        val sessionHeader = generateHeader(
            messageType = CLIENT_FULL_REQUEST,
            messageFlags = MSG_WITH_EVENT,
            compression = GZIP_COMPRESSION
        )
        
        buffer = ByteArrayOutputStream()
        buffer.write(sessionHeader)
        buffer.write(NO_SEQUENCE)
        pSize = sessionPayload.size
        buffer.write(pSize shr 24)
        buffer.write(pSize shr 16)
        buffer.write(pSize shr 8)
        buffer.write(pSize)
        buffer.write(sessionPayload)
        
        webSocket?.send(buffer.toByteArray().toByteString())
    }

    private fun handleMessage(text: String) {
        // Pure text means text fallback. Real Doubao sends binary WebSocket streams.
        Log.d(TAG, "Unhandled text message -> $text")
    }

    private fun handleData(data: ByteArray) {
        if (data.size < 4) return
        val header = data.copyOfRange(0, 4)
        
        val messageType = ((header[0].toInt() and 0x0F) shl 8) or (header[1].toInt() and 0xFF)
        val compression = header[2].toInt() and 0x03
        
        if (messageType == SERVER_ERROR_RESPONSE) {
            Log.e(TAG, "Received Doubao error response")
            return
        }

        // Header (4) + Sequence (4) = 8 bytes before Payload Size
        if (data.size < 12) return
        var cursor = 8

        val payloadSize = ((data[cursor].toInt() and 0xFF) shl 24) or
                          ((data[cursor + 1].toInt() and 0xFF) shl 16) or
                          ((data[cursor + 2].toInt() and 0xFF) shl 8) or
                          (data[cursor + 3].toInt() and 0xFF)
        cursor += 4

        if (data.size < cursor + payloadSize) return

        val payloadBytes = data.copyOfRange(cursor, cursor + payloadSize)
        val audioBytes = data.copyOfRange(cursor + payloadSize, data.size)
        
        val jsonBytes = if (compression == GZIP_COMPRESSION) {
            ungzip(payloadBytes)
        } else {
            payloadBytes
        }
        
        val payloadStr = String(jsonBytes, Charsets.UTF_8)
        try {
            val json = JSONObject(payloadStr)
            handleJsonEvent(json, audioBytes)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse Doubao event JSON: ${e.message}")
        }
    }

    private fun handleJsonEvent(json: JSONObject, audioData: ByteArray) {
        // Doubao Setup Complete logic
        if (json.has("code") && json.optInt("code") == 1000) {
            if (_connectionState.value != GeminiConnectionState.Ready) {
                _connectionState.value = GeminiConnectionState.Ready
                resolveConnect(true)
            }
        }
        
        val eventType = json.optString("event_type", "")
        
        if (eventType == "asrResponse") {
            val isFinal = json.optBoolean("is_final", false)
            val text = json.optString("text", "")
            if (isFinal && text.isNotEmpty()) {
                Log.d(TAG, "You: $text")
                lastUserSpeechEnd = System.currentTimeMillis()
                responseLatencyLogged = false
                onInputTranscription?.invoke(text)
            }
        } else if (eventType == "chatResponse" || eventType == "taskRequest") {
            val isFinal = json.optBoolean("is_final", false)
            val text = json.optString("text", "")
            
            if (isFinal && text.isNotEmpty()) {
                 Log.d(TAG, "AI: $text")
                 onOutputTranscription?.invoke(text)
            }
            
            if (audioData.isNotEmpty()) {
                if (!_isModelSpeaking.value) {
                    _isModelSpeaking.value = true
                    if (lastUserSpeechEnd > 0 && !responseLatencyLogged) {
                        val latency = System.currentTimeMillis() - lastUserSpeechEnd
                        Log.d(TAG, "[Latency] ${latency}ms (user speech end -> first audio)")
                        responseLatencyLogged = false // Reset per new response cycle? No, just keep tracking.
                    }
                }
                onAudioReceived?.invoke(audioData)
            }
            
            // Check for tool calls
            val toolCalls = GeminiToolCall.fromJSON(json)
            if (toolCalls != null) {
                Log.d(TAG, "Tool call received: ${toolCalls.functionCalls.size} function(s)")
                onToolCall?.invoke(toolCalls)
            }
            
        } else if (eventType == "ttsEnded") {
            _isModelSpeaking.value = false
            responseLatencyLogged = false
            onTurnComplete?.invoke()
        }
    }
}
