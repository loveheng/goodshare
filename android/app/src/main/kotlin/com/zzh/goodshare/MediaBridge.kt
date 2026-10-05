package com.zzh.goodshare

import android.content.Context
import android.graphics.Bitmap
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Composition
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * 媒体探测 MethodChannel 桥（media-native P1，替换 FFprobeKit 只读元数据）。
 *
 * 协议（channel: goodshare/media）：
 * - videoDurationMs(path) → Long?：MediaMetadataRetriever 读容器时长（毫秒，不解码）；
 * - audioCodec(path) → String?：MediaExtractor 首条音轨的 MIME（如 audio/mp4a-latm），
 *   Dart 侧经 audioCodecNameFromMime 归一为 ffmpeg 风格 codec 名选容器；
 * - decodeMonoPcm{path,out,startMs?,endMs?} → {sampleRate,frames}?（P2）：首条音轨
 *   MediaCodec 解码 → 下混单声道 s16le raw PCM 落盘（不带头，Dart 侧续接 16k
 *   重采样 + WAV 封装，见 lib/media/pcm_resample.dart）。区间毫秒裁剪。
 *
 * 探测/解码失败 / 无音轨 / 格式解不了一律回 null（不抛 PlatformException）——
 * Dart 契约「null = 非阻断降级」。全部跑单线程 executor，不占主线程。
 */
object MediaBridge {
    private val executor = Executors.newSingleThreadExecutor()

    /** Transformer 要求在带 Looper 的线程上使用；专用线程，不与主线程竞争。 */
    private val transformThread = HandlerThread("goodshare-media-transform").apply { start() }
    private val transformHandler = Handler(transformThread.looper)

    /** [Context] 由 register 传入（MainActivity 生命周期长于任何单次导出）。 */
    private var appContext: Context? = null

    fun register(channel: MethodChannel, context: Context) {
        appContext = context.applicationContext
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "videoDurationMs" -> {
                    val path = call.arguments as? String
                    if (path == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    executor.execute { runSafe(result) { videoDurationMs(path) } }
                }
                "videoCover" -> {
                    val path = call.arguments as? String
                    if (path == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    executor.execute { runSafe(result) { videoCover(path) } }
                }
                "audioCodec" -> {
                    val path = call.arguments as? String
                    if (path == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    executor.execute { runSafe(result) { audioCodec(path) } }
                }
                "decodeMonoPcm" -> {
                    val args = call.arguments as? Map<String, Any?>
                    if (args == null || args["path"] !is String || args["out"] !is String) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        runSafe(result) {
                            decodeMonoPcm(
                                args["path"] as String,
                                args["out"] as String,
                                (args["startMs"] as? Number)?.toLong(),
                                (args["endMs"] as? Number)?.toLong(),
                            )
                        }
                    }
                }
                "trimVideo" -> {
                    val args = call.arguments as? Map<String, Any?>
                    val ok = args != null &&
                        args["path"] is String && args["out"] is String &&
                        args["startMs"] is Number && args["endMs"] is Number
                    if (!ok) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        runSafe(result) {
                            trimVideo(
                                args["path"] as String,
                                args["out"] as String,
                                (args["startMs"] as Number).toLong(),
                                (args["endMs"] as Number).toLong(),
                            )
                        }
                    }
                }
                "exportAudio" -> {
                    val args = call.arguments as? Map<String, Any?>
                    val format = args?.get("format") as? String ?: ""
                    if (args == null || args["path"] !is String || args["out"] !is String ||
                        format !in setOf("copy", "m4a", "flac", "wav")
                    ) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        runSafe(result) {
                            exportAudio(
                                args["path"] as String,
                                args["out"] as String,
                                format,
                            )
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private inline fun runSafe(result: MethodChannel.Result, block: () -> Any?) {
        try {
            result.success(block())
        } catch (_: Exception) {
            // setDataSource/解码对损坏文件可能抛运行时异常；按失败降级为 null
            result.success(null)
        }
    }

    private fun videoDurationMs(path: String): Long? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            return retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
        } finally {
            retriever.release()
        }
    }

    /**
     * 视频封面帧（2026-10-03「视频加封面」）：getFrameAtTime 取首帧（SYNC 缺失
     * 回落 CLOSEST），JPEG 压缩（宽 >720 等比降采样）回字节——Dart 侧 Image.memory
     * 渲染并按 url 内存缓存；失败 null（图标占位降级，契约同探测 null 非阻断）。
     */
    private fun videoCover(path: String): ByteArray? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val frame = retriever.getFrameAtTime(
                0L,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            )
                ?: retriever.getFrameAtTime(
                    0L,
                    MediaMetadataRetriever.OPTION_CLOSEST,
                )
                ?: return null
            val scaled = if (frame.width > 720) {
                val h = (frame.height * (720.0 / frame.width)).toInt().coerceAtLeast(1)
                Bitmap.createScaledBitmap(frame, 720, h, true)
            } else {
                frame
            }
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
            return out.toByteArray()
        } finally {
            retriever.release()
        }
    }

    private fun audioCodec(path: String): String? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
                if (mime != null && mime.startsWith("audio/")) return mime
            }
            return null
        } finally {
            extractor.release()
        }
    }

    /** 首条音轨的 trackIndex + 格式；无音轨返回 null。 */
    private fun firstAudioTrack(extractor: MediaExtractor): Pair<Int, MediaFormat>? {
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            val mime = f.getString(MediaFormat.KEY_MIME)
            if (mime != null && mime.startsWith("audio/")) return i to f
        }
        return null
    }

    /**
     * 区间 trim 导出 mp4（media-native P3，替代 libx264 精确重编码）。
     * media3 Transformer：MediaCodec 硬解硬编，H264 输出（兼容性优先），
     * 音视频同走默认转码。同步语义：executor 线程 latch 等待，transformer
     * 在专用 Looper 线程上跑。失败返回 null（Dart 侧降级），产物不存在即失败。
     */
    private fun trimVideo(path: String, outPath: String, startMs: Long, endMs: Long): Map<String, Any>? {
        val context = appContext ?: return null
        if (endMs <= startMs) return null
        val latch = CountDownLatch(1)
        var error: String? = null
        transformHandler.post {
            try {
                val mediaItem = MediaItem.Builder()
                    .setUri(Uri.fromFile(File(path)))
                    .setClippingConfiguration(
                        MediaItem.ClippingConfiguration.Builder()
                            .setStartPositionMs(startMs)
                            .setEndPositionMs(endMs)
                            .build(),
                    )
                    .build()
                val transformer = Transformer.Builder(context)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(
                            composition: Composition,
                            exportResult: ExportResult,
                        ) {
                            latch.countDown()
                        }

                        override fun onError(
                            composition: Composition,
                            exportResult: ExportResult,
                            exportException: ExportException,
                        ) {
                            error = exportException.message ?: "transform failed"
                            latch.countDown()
                        }
                    })
                    .build()
                transformer.start(EditedMediaItem.Builder(mediaItem).build(), outPath)
            } catch (e: Exception) {
                error = e.message ?: "transform start failed"
                latch.countDown()
            }
        }
        // 队列任务 180s 超时的量级；给足余量由 Dart 侧兜底
        if (!latch.await(5, TimeUnit.MINUTES)) {
            error = "transform timeout"
        }
        val out = File(outPath)
        if (error != null || !out.exists() || out.length() <= 0L) return null
        return mapOf("bytes" to out.length())
    }

    /**
     * 流式解码首条音轨 → 单声道 s16le raw PCM。
     * 内存有界（逐 buffer 写盘）；[startMs]/[endMs] 按 pts 毫秒裁剪（seek 到
     * 前一个同步帧起解，样本级丢弃首尾越界部分）。异常向上抛，由 runSafe 降级。
     */
    private fun decodeMonoPcm(
        path: String,
        outPath: String,
        startMs: Long?,
        endMs: Long?,
    ): Map<String, Any>? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            val (trackIndex, trackFormat) = firstAudioTrack(extractor) ?: return null
            extractor.selectTrack(trackIndex)
            val mime = trackFormat.getString(MediaFormat.KEY_MIME)!!

            val startUs = (startMs ?: 0L) * 1000L
            val endUs = endMs?.let { it * 1000L }
            if (startUs > 0) {
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            }

            val codec = MediaCodec.createDecoderByType(mime)
            val out = BufferedOutputStream(FileOutputStream(outPath))
            try {
                codec.configure(trackFormat, null, null, 0)
                codec.start()
                var srcRate = trackFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                var channels = trackFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT
                val info = MediaCodec.BufferInfo()
                var writtenFrames = 0L
                var sawEos = false

                while (!sawEos) {
                    if (!sawEos) {
                        val inIdx = codec.dequeueInputBuffer(10_000)
                        if (inIdx >= 0) {
                            val ib = codec.getInputBuffer(inIdx)!!
                            val size = extractor.readSampleData(ib, 0)
                            if (size < 0 || (endUs != null && extractor.sampleTime > endUs)) {
                                codec.queueInputBuffer(
                                    inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                            } else {
                                codec.queueInputBuffer(
                                    inIdx, 0, size, extractor.sampleTime, 0,
                                )
                                extractor.advance()
                            }
                        }
                    }

                    val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                    when {
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val f = codec.outputFormat
                            srcRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            pcmEncoding = f.getInteger(MediaFormat.KEY_PCM_ENCODING)
                        }
                        outIdx >= 0 -> {
                            if (info.size > 0) {
                                writtenFrames += writeDownmixed(
                                    codec.getOutputBuffer(outIdx)!!, info, out,
                                    channels, pcmEncoding, srcRate, startUs, endUs,
                                )
                            }
                            codec.releaseOutputBuffer(outIdx, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                                sawEos = true
                            }
                        }
                        // INFO_TRY_AGAIN_LATER / INFO_OUTPUT_BUFFERS_CHANGED：继续循环
                    }
                }
                if (writtenFrames <= 0L) return null
                return mapOf("sampleRate" to srcRate, "frames" to writtenFrames)
            } finally {
                try {
                    codec.stop()
                } finally {
                    codec.release()
                }
                out.close()
            }
        } finally {
            extractor.release()
        }
    }

    /**
     * 一个输出 buffer 的下混落盘；返回实际写出的帧数。首尾按 pts 越界的
     * 样本级裁剪（区间端点毫秒精度，对 ASR 足够）。
     */
    private fun writeDownmixed(
        buffer: ByteBuffer,
        info: MediaCodec.BufferInfo,
        out: BufferedOutputStream,
        channels: Int,
        pcmEncoding: Int,
        srcRate: Int,
        startUs: Long,
        endUs: Long?,
    ): Long {
        if (channels <= 0) return 0L
        val bytesPerSample = if (pcmEncoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
        val bytesPerFrame = bytesPerSample * channels
        // 只看有效数据区（info.offset/size 圈定）
        buffer.position(info.offset)
        buffer.limit(info.offset + info.size)
        val totalFramesInBuf: Long = (info.size.toLong()) / bytesPerFrame
        if (totalFramesInBuf <= 0L) return 0L
        val pts = info.presentationTimeUs
        val framesPerUs = srcRate / 1_000_000.0

        // 首裁：pts 早于 startUs 的样本丢弃
        var skip = 0L
        if (pts < startUs) {
            skip = ((startUs - pts) * framesPerUs).toLong()
            if (skip > totalFramesInBuf) return 0L // 整个 buffer 都在区间前
        }
        // 尾裁：pts + k/srcRate <= endUs
        var keep = totalFramesInBuf - skip
        if (endUs != null) {
            val allowed = ((endUs - pts) * framesPerUs).toLong() - skip
            if (allowed <= 0L) return 0L
            keep = minOf(keep, allowed)
        }
        if (keep <= 0L) return 0L

        val shorts: ShortBufferView = if (pcmEncoding == AudioFormat.ENCODING_PCM_FLOAT) {
            FloatShorts(buffer, channels)
        } else {
            RawShorts(buffer, channels)
        }

        val pair = ByteArray(2)
        for (f in 0 until keep) {
            val s = shorts.frameAt((skip + f).toInt()).toInt()
            pair[0] = (s and 0xFF).toByte()
            pair[1] = ((s shr 8) and 0xFF).toByte()
            out.write(pair)
        }
        return keep
    }

    /** 解码输出 buffer 的逐帧单声道视图（下混 = 前两声道均值，多声道忽略其余）。 */
    private interface ShortBufferView {
        fun frameAt(frame: Int): Short
    }

    private class RawShorts(val buffer: ByteBuffer, val channels: Int) : ShortBufferView {
        val shorts: java.nio.ShortBuffer =
            buffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()

        override fun frameAt(frame: Int): Short {
            val base = frame * channels
            val s0 = shorts.get(base)
            if (channels == 1) return s0
            val s1 = shorts.get(base + 1)
            return ((s0 + s1) / 2).toShort()
        }
    }

    private class FloatShorts(val buffer: ByteBuffer, val channels: Int) : ShortBufferView {
        val floats: java.nio.FloatBuffer =
            buffer.order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()

        override fun frameAt(frame: Int): Short {
            val base = frame * channels
            val v0 = floats.get(base)
            val mixed = if (channels == 1) v0 else (v0 + floats.get(base + 1)) / 2f
            return (mixed.coerceIn(-1f, 1f) * 32767f).toInt().toShort()
        }
    }

    // -----------------------------------------------------------------------
    // 音轨导出（media-native P4，替代 ffmpeg -c:a copy / 内置编码器重编码）
    // -----------------------------------------------------------------------

    /**
     * 音轨导出（channel 协议：exportAudio{path,out,format} → bytes?）。
     *
     * - **copy**（流复制，无损秒出）：容器按源编码选——aac/alac→MPEG_4(.m4a)、
     *   opus/vorbis→OGG(.ogg) 走 MediaMuxer 逐样本搬移；mp3→原始流拼接(.mp3)；
     *   flac→「fLaC」+ csd(STREAMINFO) + 帧拼接(.flac)；pcm→WAV 头封装(.wav)；
     *   其余编码尝试 MPEG_4（失败回 null，Dart 侧回落重编码 m4a，与旧 ffmpeg 行为一致）。
     * - **m4a/wav/flac**：解码 → 重编码（AAC-LC / FLAC 系统编码器；wav 直写 PCM）。
     *   WAV 保留源采样率与声道；AAC 码率 64k/声道（clamp 96k~256k）。
     *
     * 失败返回 null（文件不存在或 0 字节），R1 文案由 Dart 侧给出。
     */
    private fun exportAudio(path: String, outPath: String, format: String): Long? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            val (trackIndex, trackFormat) = firstAudioTrack(extractor) ?: return null
            extractor.selectTrack(trackIndex)
            val mime = trackFormat.getString(MediaFormat.KEY_MIME)!!
            extractor.seekTo(0, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            val bytes = if (format == "copy") {
                copyAudioTrack(extractor, outPath, mime, trackFormat)
            } else {
                transcodeAudio(extractor, outPath, mime, trackFormat, format)
            }
            if (bytes == null || bytes <= 0L) {
                File(outPath).delete() // 空壳/半截文件不留现场
                return null
            }
            val out = File(outPath)
            if (!out.exists() || out.length() <= 0L) return null
            return out.length()
        } finally {
            extractor.release()
        }
    }

    /** copy 容器分派；各封装内部失败返回 null。 */
    private fun copyAudioTrack(
        extractor: MediaExtractor,
        outPath: String,
        mime: String,
        trackFormat: MediaFormat,
    ): Long? = when (mime) {
        MediaFormat.MIMETYPE_AUDIO_AAC, "audio/alac" ->
            muxerCopyAudio(extractor, outPath, MediaMuxerOutputFormat.MPEG_4, trackFormat)
        "audio/opus", "audio/vorbis" ->
            muxerCopyAudio(extractor, outPath, MediaMuxerOutputFormat.OGG, trackFormat)
        MediaFormat.MIMETYPE_AUDIO_MPEG -> rawSampleDump(extractor, outPath)
        "audio/flac" -> flacRawDump(extractor, outPath, trackFormat)
            ?: transcodeAudio(extractor, outPath, mime, trackFormat, "flac")
        MediaFormat.MIMETYPE_AUDIO_RAW -> pcmToWav(extractor, outPath, trackFormat)
        else -> muxerCopyAudio(extractor, outPath, MediaMuxerOutputFormat.MPEG_4, trackFormat)
    }

    private enum class MediaMuxerOutputFormat { MPEG_4, OGG }

    /** MediaMuxer 逐样本搬移（编码样本原样进新容器，无损秒出）。 */
    private fun muxerCopyAudio(
        extractor: MediaExtractor,
        outPath: String,
        container: MediaMuxerOutputFormat,
        trackFormat: MediaFormat,
    ): Long? {
        val muxer = android.media.MediaMuxer(
            outPath,
            if (container == MediaMuxerOutputFormat.MPEG_4)
                android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            else
                android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_OGG,
        )
        try {
            val track = muxer.addTrack(trackFormat)
            muxer.start()
            val buf = ByteBuffer.allocate(1 shl 20)
            val info = MediaCodec.BufferInfo()
            var bytes = 0L
            while (true) {
                val size = extractor.readSampleData(buf, 0)
                if (size < 0) break
                info.offset = 0
                info.size = size
                info.presentationTimeUs = extractor.sampleTime
                info.flags =
                    if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0)
                        MediaCodec.BUFFER_FLAG_KEY_FRAME
                    else 0
                muxer.writeSampleData(track, buf, info)
                bytes += size
                extractor.advance()
            }
            muxer.stop()
            return bytes
        } catch (_: Exception) {
            // 容器装不下该编码（如 amr→mp4 失败）：回 null，Dart 侧回落 m4a
            File(outPath).delete()
            return null
        } finally {
            muxer.release()
        }
    }

    /** mp3：原始帧拼接即合法流（mp3 自同步容器）。 */
    private fun rawSampleDump(extractor: MediaExtractor, outPath: String): Long? {
        val out = BufferedOutputStream(FileOutputStream(outPath))
        try {
            val buf = ByteBuffer.allocate(1 shl 20)
            var bytes = 0L
            while (true) {
                val size = extractor.readSampleData(buf, 0)
                if (size < 0) break
                val arr = ByteArray(size)
                buf.position(0)
                buf.get(arr)
                out.write(arr)
                bytes += size
                extractor.advance()
            }
            return if (bytes > 0) bytes else null
        } finally {
            out.close()
        }
    }

    /** flac 源流复制：「fLaC」魔数 + csd-0(STREAMINFO) + 帧拼接；无 csd 走重编码。 */
    private fun flacRawDump(
        extractor: MediaExtractor,
        outPath: String,
        trackFormat: MediaFormat,
    ): Long? {
        val csd = trackFormat.getByteBuffer("csd-0") ?: return null
        if (csd.remaining() <= 0) return null
        val out = BufferedOutputStream(FileOutputStream(outPath))
        try {
            out.write(byteArrayOf('f'.code.toByte(), 'L'.code.toByte(), 'a'.code.toByte(), 'C'.code.toByte()))
            val size = csd.remaining()
            out.write(byteArrayOf(0x80.toByte(), (size shr 16).toByte(), (size shr 8).toByte(), size.toByte()))
            val csdBytes = ByteArray(size)
            csd.get(csdBytes)
            out.write(csdBytes)
            val buf = ByteBuffer.allocate(1 shl 20)
            var bytes = 4L + 4L + size
            while (true) {
                val s = extractor.readSampleData(buf, 0)
                if (s < 0) break
                val arr = ByteArray(s)
                buf.position(0)
                buf.get(arr)
                out.write(arr)
                bytes += s
                extractor.advance()
            }
            return bytes
        } catch (_: Exception) {
            File(outPath).delete()
            return null
        } finally {
            out.close()
        }
    }

    /** pcm 源（wav 容器）流复制：按源参数重写 WAV 头 + 数据拼接。float 源回 null 走重编码。 */
    private fun pcmToWav(
        extractor: MediaExtractor,
        outPath: String,
        trackFormat: MediaFormat,
    ): Long? {
        val encoding = if (trackFormat.containsKey(MediaFormat.KEY_PCM_ENCODING))
            trackFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
        else AudioFormat.ENCODING_PCM_16BIT
        if (encoding == AudioFormat.ENCODING_PCM_FLOAT) return null
        val rate = trackFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channels = trackFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val out = BufferedOutputStream(FileOutputStream(outPath))
        try {
            out.write(wavHeader(rate, channels, 16, 0)) // dataSize 末尾回填
            val buf = ByteBuffer.allocate(1 shl 20)
            var bytes = 0L
            while (true) {
                val s = extractor.readSampleData(buf, 0)
                if (s < 0) break
                val arr = ByteArray(s)
                buf.position(0)
                buf.get(arr)
                out.write(arr)
                bytes += s
                extractor.advance()
            }
            if (bytes <= 0) return null
            RandomAccessPatch.patchDataSize(outPath, bytes)
            return bytes + 44L
        } finally {
            out.close()
        }
    }

    /** 解码→重编码统一管线（target = m4a|flac|wav；copy 落此处的编码含 flac/未知）。 */
    private fun transcodeAudio(
        extractor: MediaExtractor,
        outPath: String,
        mime: String,
        trackFormat: MediaFormat,
        target: String,
    ): Long? {
        val srcRate = trackFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val srcChannels = trackFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

        val encoder = if (target == "wav") null else run {
            val encMime = if (target == "m4a") MediaFormat.MIMETYPE_AUDIO_AAC else "audio/flac"
            val f = MediaFormat.createAudioFormat(encMime, srcRate, srcChannels)
            if (target == "m4a") {
                f.setInteger(
                    MediaFormat.KEY_AAC_PROFILE,
                    android.media.MediaCodecInfo.CodecProfileLevel.AACObjectLC,
                )
                f.setInteger(
                    MediaFormat.KEY_BIT_RATE,
                    (64000 * srcChannels).coerceIn(96000, 256000),
                )
            } else {
                f.setInteger(MediaFormat.KEY_FLAC_COMPRESSION_LEVEL, 5)
            }
            val e = MediaCodec.createEncoderByType(encMime)
            e.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            e.start()
            e
        }
        if (target == "flac" && encoder == null) return null

        val muxer = if (target == "m4a") {
            android.media.MediaMuxer(outPath, android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        } else null
        val flacOut = if (target == "flac") BufferedOutputStream(FileOutputStream(outPath)) else null
        val wavOut = if (target == "wav") BufferedOutputStream(FileOutputStream(outPath)) else null
        if (wavOut != null) wavOut.write(wavHeader(srcRate, srcChannels, 16, 0))

        val decoder = MediaCodec.createDecoderByType(mime)
        var bytes = 0L
        try {
            decoder.configure(trackFormat, null, null, 0)
            decoder.start()
            var muxerTrack = -1
            var flacHeaderWritten = false
            val info = MediaCodec.BufferInfo()
            val encInfo = MediaCodec.BufferInfo()
            var sawDecEos = false
            var sawEncEos = target == "wav"

            fun drainEncoder(eos: Boolean) {
                val enc = encoder ?: return
                if (eos) {
                    val idx = enc.dequeueInputBuffer(10_000)
                    if (idx >= 0) enc.queueInputBuffer(idx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                }
                while (true) {
                    val o = enc.dequeueOutputBuffer(encInfo, 10_000)
                    when {
                        o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            if (muxer != null && muxerTrack < 0) {
                                muxerTrack = muxer.addTrack(enc.outputFormat)
                                muxer.start()
                            }
                        }
                        o >= 0 -> {
                            val ob = enc.getOutputBuffer(o)!!
                            if (encInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                                // FLAC：csd = STREAMINFO，写文件头（last-block 标记）
                                if (flacOut != null && !flacHeaderWritten && encInfo.size > 0) {
                                    ob.position(encInfo.offset)
                                    ob.limit(encInfo.offset + encInfo.size)
                                    val csd = ByteArray(encInfo.size)
                                    ob.get(csd)
                                    flacOut.write(byteArrayOf('f'.code.toByte(), 'L'.code.toByte(), 'a'.code.toByte(), 'C'.code.toByte()))
                                    flacOut.write(
                                        byteArrayOf(
                                            0x80.toByte(), (csd.size shr 16).toByte(),
                                            (csd.size shr 8).toByte(), csd.size.toByte(),
                                        ),
                                    )
                                    flacOut.write(csd)
                                    bytes += 8L + csd.size
                                    flacHeaderWritten = true
                                }
                            } else if (encInfo.size > 0) {
                                ob.position(encInfo.offset)
                                ob.limit(encInfo.offset + encInfo.size)
                                if (muxer != null && muxerTrack >= 0) {
                                    muxer.writeSampleData(muxerTrack, ob, encInfo)
                                    bytes += encInfo.size
                                } else if (flacOut != null && flacHeaderWritten) {
                                    val arr = ByteArray(encInfo.size)
                                    ob.get(arr)
                                    flacOut.write(arr)
                                    bytes += encInfo.size
                                }
                                // m4a 且 muxer 未就绪：丢弃（muxerTrack<0 时最终判失败）
                            }
                            enc.releaseOutputBuffer(o, false)
                            if (encInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                                sawEncEos = true
                                return
                            }
                        }
                        else -> if (o == MediaCodec.INFO_TRY_AGAIN_LATER && !eos) return
                    }
                }
            }

            fun writePcm(buffer: ByteBuffer, offset: Int, size: Int) {
                when {
                    wavOut != null -> {
                        // 统一转 s16le（float 源转换，其余原样）
                        val encoding = try {
                            decoder.outputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                        } catch (_: Exception) {
                            AudioFormat.ENCODING_PCM_16BIT
                        }
                        if (encoding == AudioFormat.ENCODING_PCM_FLOAT) {
                            buffer.position(offset)
                            buffer.limit(offset + size)
                            val floats = buffer.order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                            val b = ByteArray(size / 2)
                            for (i in 0 until size / 4) {
                                val v = (floats.get(i).coerceIn(-1f, 1f) * 32767f).toInt()
                                b[2 * i] = (v and 0xFF).toByte()
                                b[2 * i + 1] = ((v shr 8) and 0xFF).toByte()
                            }
                            wavOut.write(b)
                            bytes += size / 2
                        } else {
                            val arr = ByteArray(size)
                            buffer.limit(offset + size)
                            buffer.position(offset)
                            buffer.get(arr)
                            wavOut.write(arr)
                            bytes += size
                        }
                    }
                    encoder != null -> {
                        // 喂编码器：大块按输入缓冲容量拆分
                        var remaining = size
                        var pos = offset
                        while (remaining > 0) {
                            val idx = encoder.dequeueInputBuffer(10_000)
                            if (idx < 0) {
                                drainEncoder(false)
                                continue
                            }
                            val ib = encoder.getInputBuffer(idx)!!
                            val chunk = minOf(remaining, ib.capacity())
                            ib.clear()
                            buffer.limit(pos + chunk)
                            buffer.position(pos)
                            ib.put(buffer)
                            encoder.queueInputBuffer(idx, 0, chunk, 0, 0)
                            pos += chunk
                            remaining -= chunk
                            drainEncoder(false)
                        }
                    }
                }
            }

            while (!sawDecEos && !sawEncEos) {
                val inIdx = decoder.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    val ib = decoder.getInputBuffer(inIdx)!!
                    val size = extractor.readSampleData(ib, 0)
                    if (size < 0) {
                        decoder.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    } else {
                        decoder.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
                val outIdx = decoder.dequeueOutputBuffer(info, 10_000)
                when {
                    outIdx >= 0 -> {
                        if (info.size > 0) writePcm(decoder.getOutputBuffer(outIdx)!!, info.offset, info.size)
                        decoder.releaseOutputBuffer(outIdx, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) sawDecEos = true
                    }
                }
            }
            if (encoder != null && !sawEncEos) drainEncoder(true)

            // m4a：编码器从未给出 outputFormat/muxer 未启动 → 半截文件判失败
            if (target == "m4a" && muxerTrack < 0) return null
            // flac：从未收到 STREAMINFO csd → 头没写，判失败
            if (target == "flac" && !flacHeaderWritten) return null
            if (target == "wav" && bytes > 0) {
                wavOut!!.flush()
                RandomAccessPatch.patchDataSize(outPath, bytes)
                bytes += 44L
            }
            return if (bytes > 0) bytes else null
        } catch (_: Exception) {
            File(outPath).delete()
            return null
        } finally {
            try {
                decoder.stop()
            } finally {
                decoder.release()
            }
            encoder?.stop()
            encoder?.release()
            try {
                muxer?.stop()
            } catch (_: Exception) {
            }
            muxer?.release()
            flacOut?.close()
            wavOut?.close()
        }
    }

    /** 44 字节 WAV 头（s16le；[dataSize] 由调用方回填）。 */
    private fun wavHeader(rate: Int, channels: Int, bits: Int, dataSize: Long): ByteArray {
        val h = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        fun ascii(s: String) {
            for (c in s) h.put(c.code.toByte())
        }
        ascii("RIFF")
        h.putInt((36 + dataSize).toInt())
        ascii("WAVE")
        ascii("fmt ")
        h.putInt(16)
        h.putShort(1)
        h.putShort(channels.toShort())
        h.putInt(rate)
        h.putInt(rate * channels * bits / 8)
        h.putShort((channels * bits / 8).toShort())
        h.putShort(bits.toShort())
        ascii("data")
        h.putInt(dataSize.toInt())
        return h.array()
    }

    /** WAV 头两处 size 字段回填（流式写盘后补）。 */
    private object RandomAccessPatch {
        fun patchDataSize(path: String, dataBytes: Long) {
            java.io.RandomAccessFile(path, "rw").use { f ->
                val d = dataBytes.toInt()
                f.seek(4)
                f.writeInt(Integer.reverseBytes(36 + d))
                f.seek(40)
                f.writeInt(Integer.reverseBytes(d))
            }
        }
    }
}
