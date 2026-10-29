package pk.mpl.mpl

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import java.io.ByteArrayOutputStream
import java.nio.ByteOrder

/**
 * Decodes a time window of an audio file to interleaved 16-bit little-endian
 * PCM at the source sample rate and channel count. Down-mixing and resampling
 * to the model's input format happen in Dart so both platforms share one
 * preprocessing implementation.
 */
class AudioDecoder(private val context: Context) {
    fun decode(uri: String, offsetMs: Long, durationMs: Long): Map<String, Any> {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            if (uri.startsWith("content://")) extractor.setDataSource(context, Uri.parse(uri), null)
            else extractor.setDataSource(uri.removePrefix("file://"))

            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    trackIndex = i; format = f; break
                }
            }
            require(trackIndex >= 0 && format != null) { "No audio track in source" }
            extractor.selectTrack(trackIndex)

            var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT

            val startUs = offsetMs * 1000L
            val endUs = startUs + durationMs * 1000L
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, null, null, 0)
            codec.start()

            val out = ByteArrayOutputStream()
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var firstSampleUs = -1L
            val timeoutUs = 10_000L

            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(timeoutUs)
                    if (inIndex >= 0) {
                        val buf = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buf, 0)
                        val t = extractor.sampleTime
                        if (size < 0 || t > endUs + 500_000L) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, t, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, timeoutUs)
                when {
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = codec.outputFormat
                        sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        if (f.containsKey(MediaFormat.KEY_PCM_ENCODING)) pcmEncoding = f.getInteger(MediaFormat.KEY_PCM_ENCODING)
                    }
                    outIndex >= 0 -> {
                        if (info.size > 0) {
                            val buf = codec.getOutputBuffer(outIndex)!!.order(ByteOrder.LITTLE_ENDIAN)
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            val bytesPerSample = if (pcmEncoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
                            val frameBytes = bytesPerSample * channels
                            val frames = info.size / frameBytes
                            val bufStartUs = info.presentationTimeUs
                            // Skip frames that precede the requested window.
                            var skipFrames = 0
                            if (bufStartUs < startUs) {
                                skipFrames = (((startUs - bufStartUs) * sampleRate) / 1_000_000L).toInt().coerceAtMost(frames)
                            }
                            if (skipFrames < frames) {
                                if (firstSampleUs < 0) firstSampleUs = maxOf(bufStartUs, startUs)
                                buf.position(info.offset + skipFrames * frameBytes)
                                val count = (frames - skipFrames) * channels
                                if (pcmEncoding == AudioFormat.ENCODING_PCM_FLOAT) {
                                    val fb = buf.asFloatBuffer()
                                    for (i in 0 until count) {
                                        val s = (fb.get(i).coerceIn(-1f, 1f) * 32767f).toInt()
                                        out.write(s and 0xff); out.write((s shr 8) and 0xff)
                                    }
                                } else {
                                    val arr = ByteArray(count * 2)
                                    buf.get(arr)
                                    out.write(arr)
                                }
                            }
                            val wantedBytes = (durationMs * sampleRate / 1000L) * channels * 2
                            if (out.size() >= wantedBytes) outputDone = true
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    }
                }
            }

            val wantedBytes = ((durationMs * sampleRate / 1000L) * channels * 2).toInt()
            val all = out.toByteArray()
            val pcm = if (all.size > wantedBytes) all.copyOf(wantedBytes) else all
            return mapOf(
                "sampleRate" to sampleRate,
                "channels" to channels,
                "pcm" to pcm,
                "startMs" to if (firstSampleUs < 0) offsetMs else firstSampleUs / 1000L,
            )
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            codec?.release()
            extractor.release()
        }
    }
}
