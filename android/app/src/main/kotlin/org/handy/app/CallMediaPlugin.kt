package org.handy.app

import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.github.pytgcalls.NTgCalls
import io.github.pytgcalls.media.AudioDescription
import io.github.pytgcalls.media.Frame
import io.github.pytgcalls.media.FrameData
import io.github.pytgcalls.media.MediaDescription
import io.github.pytgcalls.media.MediaSource
import io.github.pytgcalls.media.StreamDevice
import io.github.pytgcalls.media.StreamMode
import io.github.pytgcalls.media.SsrcGroup
import io.github.pytgcalls.media.VideoDescription
import io.github.pytgcalls.p2p.RTCServer
import org.json.JSONObject
import org.webrtc.ContextUtils
import org.webrtc.EglBase
import org.webrtc.JavaI420Buffer
import org.webrtc.TextureViewRenderer
import org.webrtc.VideoFrame
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors

class CallMediaPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val methods = MethodChannel(messenger, "handy/call_media")
    private val events = EventChannel(messenger, "handy/call_media/events")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var ntg: NTgCalls? = null
    private var chatId: Long = 0L
    private var isGroupCall = false
    private var eventSink: EventChannel.EventSink? = null
    private var prevAudioMode = AudioManager.MODE_NORMAL

    private var egl: EglBase? = null
    private val renderers = ConcurrentHashMap<String, TextureViewRenderer>()
    private val groupVideoEndpointBySsrc = ConcurrentHashMap<Long, String>()
    private val groupVideoSourcesByEndpoint = ConcurrentHashMap<String, String>()

    private val framePools = ConcurrentHashMap<String, ConcurrentLinkedQueue<ByteBuffer>>()

    private var camera: CameraCapture? = null

    @Volatile
    private var sawRemoteFrame = false

    @Volatile
    private var useFrontCamera = true

    companion object {
        private const val MIC_META = "{\"is_microphone\":true}"
        private const val SPK_META = "{\"is_microphone\":false}"

        private const val FRAME_POOL_DEPTH = 4

        @Volatile
        private var webrtcContextReady = false

        @Synchronized
        private fun ensureWebRtcContext(context: Context) {
            if (webrtcContextReady) return
            ContextUtils.initialize(context.applicationContext)
            webrtcContextReady = true
        }
    }

    init {
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                eventSink = sink
            }

            override fun onCancel(args: Any?) {
                eventSink = null
            }
        })
        methods.setMethodCallHandler { call, result ->
            if (call.method == "getProtocol") {
                worker.execute {
                    runCatching {
                        val p = NTgCalls.getProtocol()
                        android.util.Log.i(
                            "CallMedia",
                            "ntgcalls protocol min=${p.minLayer} max=${p.maxLayer} versions=${p.libraryVersions}",
                        )
                        mapOf(
                            "min" to p.minLayer,
                            "max" to p.maxLayer,
                            "versions" to p.libraryVersions,
                        )
                    }.onSuccess { v -> main.post { result.success(v) } }
                        .onFailure { e -> main.post { result.error("call_media", e.message, null) } }
                }
                return@setMethodCallHandler
            }
            when (call.method) {
                "isSupported" -> result.success(true)
                "start" -> worker.execute { runCatching { start(call.argument("config")!!) }
                    .onSuccess { reply(result, null) }
                    .onFailure { reply(result, it) } }
                "createGroup" -> worker.execute {
                    runCatching {
                        @Suppress("UNCHECKED_CAST")
                        createGroup(call.arguments as Map<String, Any?>)
                    }.onSuccess { value -> main.post { result.success(value) } }
                        .onFailure { reply(result, it) }
                }
                "connectGroup" -> worker.execute {
                    runCatching {
                        @Suppress("UNCHECKED_CAST")
                        val args = call.arguments as Map<String, Any?>
                        connectGroup(args["responsePayload"] as String)
                    }.onSuccess { reply(result, null) }.onFailure { reply(result, it) }
                }
                "addGroupVideo" -> worker.execute {
                    runCatching {
                        @Suppress("UNCHECKED_CAST")
                        addGroupVideo(call.arguments as Map<String, Any?>)
                    }.onSuccess { reply(result, null) }.onFailure { reply(result, it) }
                }
                "removeGroupVideo" -> worker.execute {
                    runCatching {
                        @Suppress("UNCHECKED_CAST")
                        val args = call.arguments as Map<String, Any?>
                        removeGroupVideo(args["endpointId"] as String)
                    }.onSuccess { reply(result, null) }.onFailure { reply(result, it) }
                }
                "setRequestedVideoChannels" -> worker.execute {
                    runCatching {
                        @Suppress("UNCHECKED_CAST")
                        setRequestedVideoChannels(call.arguments as? List<Map<String, Any?>> ?: emptyList())
                    }.onSuccess { reply(result, null) }.onFailure { reply(result, it) }
                }
                "setMediaChannelDescriptions" -> result.success(null)
                "stop" -> worker.execute { runCatching { stop() }
                    .onSuccess { reply(result, null) }.onFailure { reply(result, it) } }
                "setMuted" -> worker.execute { runCatching { setMuted(call.arguments as Boolean) }
                    .onSuccess { reply(result, null) }.onFailure { reply(result, it) } }
                "setSpeaker" -> { setSpeaker(call.arguments as Boolean); result.success(null) }
                "setVideoEnabled" -> worker.execute {
                    runCatching {
                        @Suppress("UNCHECKED_CAST")
                        val args = call.arguments as Map<String, Any?>
                        (args["front"] as? Boolean)?.let { useFrontCamera = it }
                        setVideoEnabled(args["enabled"] as Boolean)
                    }.onSuccess { reply(result, null) }.onFailure { reply(result, it) } }
                "switchCamera" -> worker.execute {
                    runCatching { switchCamera() }
                        .onSuccess { reply(result, null) }.onFailure { reply(result, it) } }
                "receiveSignaling" -> worker.execute {
                    runCatching {
                        val data = call.arguments as ByteArray
                        ntg?.sendSignalingData(chatId, data)
                    }.onSuccess { reply(result, null) }.onFailure { reply(result, it) } }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        runCatching { stop() }
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        main.post {
            runCatching { egl?.release() }
            egl = null
            renderers.clear()
        }
        worker.shutdownNow()
    }

    private fun reply(result: MethodChannel.Result, error: Throwable?) {
        main.post {
            if (error == null) result.success(null)
            else result.error("call_media", error.message, null)
        }
    }

    private fun emit(event: Map<String, Any?>) = main.post { eventSink?.success(event) }


    @Synchronized
    fun eglContext(): EglBase.Context {
        val existing = egl ?: EglBase.create().also { egl = it }
        return existing.eglBaseContext
    }

    fun registerRenderer(role: String, renderer: TextureViewRenderer) {
        android.util.Log.i("CallMediaVid", "registerRenderer role=$role")
        renderers[role] = renderer
    }

    fun unregisterRenderer(role: String, renderer: TextureViewRenderer) {
        if (renderers.remove(role, renderer)) framePools.remove(role)
    }


    @Suppress("UNCHECKED_CAST")
    private fun start(config: Map<String, Any?>) {
        val isVideo = config["isVideo"] as Boolean
        stop(keepCamera = isVideo && camera != null)
        sawRemoteFrame = false
        isGroupCall = false

        chatId = (config["callId"] as Number).toLong()
        val isOutgoing = config["isOutgoing"] as Boolean
        android.util.Log.i("CallMediaVid", "start isVideo=$isVideo isOutgoing=$isOutgoing")
        val p2pAllowed = config["p2pAllowed"] as? Boolean ?: true
        val key = config["encryptionKey"] as ByteArray
        val versions = (config["libraryVersions"] as? List<String>) ?: emptyList()
        val servers = (config["servers"] as? List<Map<String, Any?>>) ?: emptyList()

        val instance = NTgCalls()
        ntg = instance

        instance.setSignalingDataCallback { _, data ->
            emit(mapOf("type" to "signaling", "data" to data))
        }
        instance.setConnectionChangeCallback { _, info ->
            emit(mapOf("type" to "state", "state" to info.state.name))
        }

        instance.createP2PCall(chatId)
        instance.setStreamSources(chatId, StreamMode.CAPTURE, captureMedia(isVideo))
        instance.setStreamSources(chatId, StreamMode.PLAYBACK, playbackMedia(isVideo))
        instance.setFrameCallback { _, mode, device, frames ->
            if (mode != StreamMode.PLAYBACK || device != StreamDevice.CAMERA) {
                return@setFrameCallback
            }
            if (!sawRemoteFrame) {
                sawRemoteFrame = true
                android.util.Log.i(
                    "CallMediaVid",
                    "first remote CAMERA frames=${frames.size} renderer=${renderers["remote"] != null}",
                )
            }
            val renderer = renderers["remote"] ?: return@setFrameCallback
            for (f in frames) renderFrame("remote", renderer, f)
        }
        instance.skipExchange(chatId, key, isOutgoing)
        instance.connectP2P(chatId, servers.mapNotNull(::toRtcServer), versions, p2pAllowed)

        beginAudioSession()
        if (isVideo) startCameraCapture(useFrontCamera)
    }

    private fun stop(keepCamera: Boolean = false) {
        if (!keepCamera) {
            runCatching { camera?.stop() }
            camera = null
        }
        groupVideoEndpointBySsrc.clear()
        groupVideoSourcesByEndpoint.clear()
        framePools.clear()
        isGroupCall = false
        val instance = ntg ?: return
        runCatching { instance.stop(chatId) }
        ntg = null
        endAudioSession()
    }

    private fun setMuted(muted: Boolean) {
        val instance = ntg ?: return
        if (muted) instance.mute(chatId) else instance.unmute(chatId)
    }

    private fun setVideoEnabled(enabled: Boolean) {
        if (enabled) {
            startCameraCapture(useFrontCamera)
        } else {
            camera?.stop()
            camera = null
        }
        val instance = ntg ?: return
        instance.setStreamSources(chatId, StreamMode.CAPTURE, captureMedia(enabled))
        if (!isGroupCall) {
            instance.setStreamSources(chatId, StreamMode.PLAYBACK, playbackMedia(enabled))
        }
    }

    private fun switchCamera() {
        camera?.switch()
    }

    private fun startCameraCapture(front: Boolean) {
        ensureWebRtcContext(context)
        val cam = camera ?: CameraCapture(
            context = context,
            eglContext = eglContext(),
            onLocalFrame = { frame ->
                val role = if (isGroupCall) "group:local" else "local"
                renderers[role]?.onFrame(frame)
            },
            onEncodedFrame = { bytes, w, h, rot, tsMs ->
                runCatching {
                    ntg?.sendExternalFrame(
                        chatId,
                        StreamDevice.CAMERA,
                        bytes,
                        FrameData(tsMs, w, h, rot),
                    )
                }
            },
            onSwitched = { isFront ->
                useFrontCamera = isFront
                main.post { renderers["local"]?.setMirror(isFront) }
            },
        ).also { camera = it }
        cam.start(front)
    }


    private fun createGroup(args: Map<String, Any?>): Map<String, Any?> {
        stop()
        sawRemoteFrame = false
        useFrontCamera = true
        isGroupCall = true
        chatId = (args["groupCallId"] as Number).toLong()
        val isVideo = args["isVideo"] as? Boolean ?: false

        val instance = NTgCalls()
        ntg = instance
        instance.setConnectionChangeCallback { _, info ->
            emit(mapOf("type" to "groupState", "state" to info.state.name))
        }
        instance.setFrameCallback { _, mode, device, frames ->
            if (mode != StreamMode.PLAYBACK || device != StreamDevice.CAMERA) {
                return@setFrameCallback
            }
            for (frame in frames) {
                val endpoint = groupVideoEndpointBySsrc[frame.ssrc]
                    ?: groupVideoEndpointBySsrc[frame.ssrc.toInt().toLong()]
                    ?: continue
                val role = "group:$endpoint"
                val renderer = renderers[role] ?: continue
                renderFrame(role, renderer, frame)
            }
        }

        val payload = instance.createCall(chatId)
        instance.setStreamSources(chatId, StreamMode.CAPTURE, captureMedia(isVideo))
        instance.setStreamSources(chatId, StreamMode.PLAYBACK, playbackMedia(true))
        beginAudioSession()
        setSpeaker(true)
        if (isVideo) startCameraCapture(useFrontCamera)

        val audioSourceId = JSONObject(payload).optLong("ssrc", 0L)
        check(audioSourceId != 0L) { "ntgcalls join payload has no SSRC" }
        return mapOf("audioSourceId" to audioSourceId, "payload" to payload)
    }

    private fun connectGroup(responsePayload: String) {
        check(isGroupCall) { "no pending group call" }
        ntg?.connect(chatId, responsePayload, false)
    }

    @Suppress("UNCHECKED_CAST")
    private fun addGroupVideo(args: Map<String, Any?>) {
        if (!isGroupCall) return
        val endpoint = args["endpointId"] as String
        val rawGroups = args["sourceGroups"] as? List<Map<String, Any?>> ?: emptyList()
        val groups = rawGroups.mapNotNull { raw ->
            val semantics = raw["semantics"] as? String ?: return@mapNotNull null
            val sources = (raw["sourceIds"] as? List<Number>)?.map { it.toInt() }
                ?: return@mapNotNull null
            sources.forEach { source ->
                groupVideoEndpointBySsrc[source.toLong() and 0xffffffffL] = endpoint
                groupVideoEndpointBySsrc[source.toLong()] = endpoint
            }
            SsrcGroup(semantics, sources)
        }
        if (groups.isNotEmpty()) {
            ntg?.addIncomingVideo(chatId, endpoint, groups)
            groupVideoSourcesByEndpoint[endpoint] = rawGroups.toString()
        }
    }

    private fun removeGroupVideo(endpoint: String) {
        if (!isGroupCall) return
        groupVideoEndpointBySsrc.entries.removeIf { it.value == endpoint }
        groupVideoSourcesByEndpoint.remove(endpoint)
        ntg?.removeIncomingVideo(chatId, endpoint)
    }

    private fun setRequestedVideoChannels(channels: List<Map<String, Any?>>) {
        if (!isGroupCall) return
        val requested = channels.mapNotNull { channel ->
            val endpoint = channel["endpointId"] as? String ?: return@mapNotNull null
            endpoint to channel
        }.toMap()

        groupVideoSourcesByEndpoint.keys
            .filter { endpoint -> !requested.containsKey(endpoint) }
            .forEach(::removeGroupVideo)

        for ((endpoint, channel) in requested) {
            @Suppress("UNCHECKED_CAST")
            val groups = channel["sourceGroups"] as? List<Map<String, Any?>> ?: emptyList()
            val signature = groups.toString()
            if (groupVideoSourcesByEndpoint[endpoint] == signature) continue
            if (groupVideoSourcesByEndpoint.containsKey(endpoint)) removeGroupVideo(endpoint)
            addGroupVideo(mapOf("endpointId" to endpoint, "sourceGroups" to groups))
        }
    }

    private fun captureMedia(video: Boolean): MediaDescription {
        val mic = AudioDescription(MediaSource.DEVICE, MIC_META, true, 48000, 2)
        val camera = if (video) {
            VideoDescription(MediaSource.EXTERNAL, "", false, 720, 1280, 30)
        } else {
            null
        }
        return MediaDescription(mic, null, camera, null)
    }

    private fun playbackMedia(video: Boolean): MediaDescription {
        val speaker = AudioDescription(MediaSource.DEVICE, SPK_META, true, 48000, 2)
        val camera = if (video) VideoDescription(MediaSource.EXTERNAL, "", false, 0, 0, 0) else null
        return MediaDescription(null, speaker, camera, null)
    }

    private fun renderFrame(role: String, renderer: TextureViewRenderer, f: Frame) {
        val fd = f.frameData ?: return
        val data = f.data
        val w = fd.width
        val h = fd.height
        if (w <= 0 || h <= 0) return
        val ySize = w * h
        val cSize = ySize / 4
        if (data.size < ySize + 2 * cSize) return
        val pool = framePools.computeIfAbsent(role) { ConcurrentLinkedQueue<ByteBuffer>() }
        val pooled = pool.poll()?.takeIf { it.capacity() >= data.size }
        val buf = pooled?.apply { clear() } ?: ByteBuffer.allocateDirect(data.size)
        buf.put(data)
        buf.rewind()
        val y = buf.duplicate().apply { position(0); limit(ySize) }.slice()
        val u = buf.duplicate().apply { position(ySize); limit(ySize + cSize) }.slice()
        val v = buf.duplicate().apply { position(ySize + cSize); limit(ySize + 2 * cSize) }.slice()
        val i420 = JavaI420Buffer.wrap(w, h, y, w, u, w / 2, v, w / 2) {
            if (pool.size < FRAME_POOL_DEPTH) pool.offer(buf)
        }
        val frame = VideoFrame(i420, fd.rotation, fd.absoluteCaptureTimestampMs * 1_000_000L)
        renderer.onFrame(frame)
        frame.release()
    }


    @Suppress("UNCHECKED_CAST")
    private fun toRtcServer(s: Map<String, Any?>): RTCServer? {
        val id = (s["id"] as? Number)?.toLong() ?: return null
        return RTCServer(
            id,
            s["ipv4"] as? String ?: "",
            s["ipv6"] as? String ?: "",
            (s["port"] as? Number)?.toInt() ?: 0,
            s["username"] as? String ?: "",
            s["password"] as? String ?: "",
            s["turn"] as? Boolean ?: false,
            s["stun"] as? Boolean ?: false,
            s["tcp"] as? Boolean ?: false,
            s["peerTag"] as? ByteArray,
        )
    }


    private fun beginAudioSession() {
        prevAudioMode = audio.mode
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        setSpeaker(false)
    }

    private fun endAudioSession() {
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) audio.clearCommunicationDevice()
            @Suppress("DEPRECATION")
            audio.isSpeakerphoneOn = false
            audio.mode = prevAudioMode
        }
    }

    private fun setSpeaker(on: Boolean) {
        runCatching {
            @Suppress("DEPRECATION")
            audio.isSpeakerphoneOn = on
        }
    }
}
