package org.handy.app

import android.content.Context
import android.util.Log
import org.webrtc.Camera2Enumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.CapturerObserver
import org.webrtc.EglBase
import org.webrtc.JavaI420Buffer
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoFrame
import org.webrtc.YuvHelper
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentLinkedQueue

class CameraCapture(
    private val context: Context,
    private val eglContext: EglBase.Context,
    private val onLocalFrame: (VideoFrame) -> Unit,
    private val onEncodedFrame: (ByteArray, Int, Int, Int, Long) -> Unit,
    private val onSwitched: (Boolean) -> Unit,
) {
    private var capturer: CameraVideoCapturer? = null
    private var helper: SurfaceTextureHelper? = null

    @Volatile
    var isFront = true
        private set

    @Volatile
    private var sawFrame = false

    @Volatile
    private var sentOnce = false

    private val dstPool = ConcurrentLinkedQueue<ByteBuffer>()

    companion object {
        private const val TARGET_W = 1280
        private const val TARGET_H = 720
        private const val FRAME_SIZE = TARGET_W * TARGET_H * 3 / 2

        private const val SCRATCH_DEPTH = 3
    }

    fun start(front: Boolean) {
        stop()
        isFront = front
        sawFrame = false
        sentOnce = false
        val enumerator = Camera2Enumerator(context)
        val names = enumerator.deviceNames
        val name = names.firstOrNull { enumerator.isFrontFacing(it) == front }
            ?: names.firstOrNull()
        if (name == null) {
            Log.e("CallMediaVid", "CameraCapture: no camera devices")
            return
        }
        val cap = enumerator.createCapturer(name, null)
        val h = SurfaceTextureHelper.create("CallCapture", eglContext)
        capturer = cap
        helper = h
        cap.initialize(h, context, object : CapturerObserver {
            override fun onCapturerStarted(success: Boolean) {
                Log.i("CallMediaVid", "CameraCapture started=$success front=$front")
            }

            override fun onCapturerStopped() {}

            override fun onFrameCaptured(frame: VideoFrame) {
                if (!sawFrame) {
                    sawFrame = true
                    Log.i(
                        "CallMediaVid",
                        "CameraCapture first frame ${frame.rotatedWidth}x${frame.rotatedHeight} rot=${frame.rotation}",
                    )
                }
                encodeAndSend(frame)
            }
        })
        cap.startCapture(1280, 720, 30)
    }

    fun switch() {
        val cap = capturer ?: return
        cap.switchCamera(object : CameraVideoCapturer.CameraSwitchHandler {
            override fun onCameraSwitchDone(front: Boolean) {
                isFront = front
                onSwitched(front)
            }

            override fun onCameraSwitchError(error: String) {
                Log.e("CallMediaVid", "switchCamera failed: $error")
            }
        })
    }

    fun stop() {
        runCatching { capturer?.stopCapture() }
        runCatching { capturer?.dispose() }
        runCatching { helper?.dispose() }
        capturer = null
        helper = null
        dstPool.clear()
    }

    private fun encodeAndSend(frame: VideoFrame) {
        val src = frame.buffer
        val sw = src.width
        val sh = src.height
        if (sw <= 0 || sh <= 0) return
        var cw = sw
        var ch = sh
        if (sw * TARGET_H > sh * TARGET_W) {
            cw = sh * TARGET_W / TARGET_H
        } else {
            ch = sw * TARGET_H / TARGET_W
        }
        cw = cw and 1.inv()
        ch = ch and 1.inv()
        val cx = (sw - cw) / 2
        val cy = (sh - ch) / 2
        val scaled = runCatching {
            src.cropAndScale(cx, cy, cw, ch, TARGET_W, TARGET_H)
        }.getOrNull() ?: return
        val i420 = runCatching { scaled.toI420() }.getOrNull()
        if (i420 == null) {
            scaled.release()
            return
        }
        try {
            val rot = frame.rotation
            val dst = dstPool.poll()?.apply { clear() }
                ?: ByteBuffer.allocateDirect(FRAME_SIZE)
            YuvHelper.I420Rotate(
                i420.dataY, i420.strideY,
                i420.dataU, i420.strideU,
                i420.dataV, i420.strideV,
                dst, TARGET_W, TARGET_H, rot,
            )
            val swap = rot == 90 || rot == 270
            val outW = if (swap) TARGET_H else TARGET_W
            val outH = if (swap) TARGET_W else TARGET_H

            val ySize = outW * outH
            val cSize = ySize / 4
            val yb = dst.duplicate().apply { position(0); limit(ySize) }.slice()
            val ub = dst.duplicate().apply { position(ySize); limit(ySize + cSize) }.slice()
            val vb = dst.duplicate().apply {
                position(ySize + cSize); limit(ySize + 2 * cSize)
            }.slice()
            val localBuf = JavaI420Buffer.wrap(outW, outH, yb, outW, ub, outW / 2, vb, outW / 2) {
                if (dstPool.size < SCRATCH_DEPTH) dstPool.offer(dst)
            }
            val localFrame = VideoFrame(localBuf, 0, frame.timestampNs)
            onLocalFrame(localFrame)
            localFrame.release()

            val bytes = ByteArray(FRAME_SIZE)
            dst.rewind()
            dst.get(bytes)
            if (!sentOnce) {
                sentOnce = true
                Log.i(
                    "CallMediaVid",
                    "send upright ${outW}x$outH (baked rot=$rot) bytes=$FRAME_SIZE src ${sw}x$sh",
                )
            }
            onEncodedFrame(bytes, outW, outH, 0, frame.timestampNs / 1_000_000L)
        } catch (e: Throwable) {
            Log.e("CallMediaVid", "encodeAndSend failed", e)
        } finally {
            i420.release()
            scaled.release()
        }
    }
}
