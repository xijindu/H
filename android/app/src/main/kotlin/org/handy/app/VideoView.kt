package org.handy.app

import android.content.Context
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.webrtc.RendererCommon
import org.webrtc.TextureViewRenderer

class VideoViewFactory(private val plugin: CallMediaPlugin) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any?>
        val role = params?.get("role") as? String ?: "remote"
        return VideoPlatformView(context, plugin, role)
    }
}

private class VideoPlatformView(
    context: Context,
    private val plugin: CallMediaPlugin,
    private val role: String,
) : PlatformView {
    private val renderer = TextureViewRenderer(context).apply {
        init(plugin.eglContext(), null)
        setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
        setEnableHardwareScaler(true)
        if (role == "local") setMirror(true)
    }

    init {
        plugin.registerRenderer(role, renderer)
    }

    override fun getView() = renderer

    override fun dispose() {
        plugin.unregisterRenderer(role, renderer)
        runCatching { renderer.release() }
    }
}
