package com.asterlink.app

import java.io.EOFException
import java.io.InputStream

/**
 * Reads only the signal and crashing thread's symbolic stack from AOSP's
 * debuggerd/proto/tombstone.proto. Unknown fields, registers, logs, file
 * descriptors and memory dumps are skipped without materializing their data.
 * Two bounded passes make selection independent of protobuf field order.
 */
internal object NativeCrashTrace {
    private const val BYTE_LIMIT = 8 * 1024 * 1024L
    private const val FRAME_LIMIT = 32
    private const val TIME_LIMIT_NS = 2_000_000_000L

    fun extract(open: () -> InputStream?): Map<String, Any> {
        val deadline = System.nanoTime() + TIME_LIMIT_NS
        val metadata = linkedMapOf<String, Any>()
        val first = open() ?: return unavailable("系统未保留原生崩溃堆栈")
        first.use { stream ->
            val reader = Reader(stream, BYTE_LIMIT, deadline, root = true)
            reader.fields { field, wire ->
                when {
                    field == 1 && wire == 0 -> metadata["architecture"] = when (reader.number()) {
                        0L -> "arm"; 1L -> "arm64"; 2L -> "x86"; 3L -> "x86_64"; 4L -> "riscv64"; else -> "unknown"
                    }
                    field == 6 && wire == 0 -> metadata["crashTid"] = reader.number()
                    field == 20 && wire == 0 -> metadata["processUptimeSeconds"] = reader.number()
                    field == 10 && wire == 2 -> reader.message { signal ->
                        signal.fields { key, type ->
                            when {
                                key == 1 && type == 0 -> metadata["signalNumber"] = signal.number().toInt()
                                key == 2 && type == 2 -> signal.text(64)?.takeIf { it.matches(Regex("SIG[A-Z0-9]+")) }
                                    ?.let { metadata["signalName"] = it }
                                key == 3 && type == 0 -> metadata["signalCode"] = signal.number().toInt()
                                key == 4 && type == 2 -> signal.text(64)?.takeIf { it.matches(Regex("[A-Z0-9_]+")) }
                                    ?.let { metadata["signalCodeName"] = it }
                                else -> signal.skip(type)
                            }
                        }
                    }
                    else -> reader.skip(wire)
                }
            }
        }
        val tid = (metadata["crashTid"] as? Long)?.takeIf { it > 0 }
            ?: return metadata + unavailable("系统堆栈未提供崩溃线程")
        var frames = emptyList<Frame>()
        val second = open() ?: return metadata + unavailable("系统原生堆栈已被回收")
        second.use { stream ->
            val reader = Reader(stream, BYTE_LIMIT, deadline, root = true)
            reader.fields { field, wire ->
                if (field != 16 || wire != 2) {
                    reader.skip(wire)
                } else {
                    reader.message { entry ->
                        var entryTid: Long? = null
                        var threadTid: Long? = null
                        var candidate = emptyList<Frame>()
                        entry.fields { key, type ->
                            when {
                                key == 1 && type == 0 -> entryTid = entry.number()
                                key == 2 && type == 2 && (entryTid == null || entryTid == tid) -> entry.message { thread ->
                                    val stack = mutableListOf<Frame>()
                                    thread.fields { item, encoding ->
                                        when {
                                            item == 1 && encoding == 0 -> threadTid = thread.number()
                                            item == 4 && encoding == 2 && stack.size < FRAME_LIMIT -> thread.message {
                                                stack.add(readFrame(it))
                                            }
                                            else -> thread.skip(encoding)
                                        }
                                    }
                                    candidate = stack
                                }
                                else -> entry.skip(type)
                            }
                        }
                        if ((entryTid ?: threadTid) == tid) frames = candidate
                    }
                }
            }
        }
        if (frames.isEmpty()) return metadata + unavailable("系统堆栈未提供崩溃线程的调用栈")
        metadata["trace"] = frames.mapIndexed { index, frame ->
            "#${index.toString().padStart(2, '0')} pc ${frame.pc} ${frame.module}" +
                (frame.function.takeIf { it.isNotEmpty() }?.let { " ($it+${frame.offset})" } ?: "") +
                (frame.buildId.takeIf { it.isNotEmpty() }?.let { " (BuildId: $it)" } ?: "")
        }.joinToString("\n")
        metadata["faultModule"] = frames.first().module
        metadata["faultOffset"] = "0x${frames.first().pc}"
        metadata["traceFrameCount"] = frames.size
        metadata["traceNote"] = "仅提取崩溃线程的符号栈；未导出寄存器、内存转储或完整路径"
        return metadata
    }

    private fun unavailable(note: String) = mapOf("traceUnavailable" to true, "traceNote" to note)

    private data class Frame(
        var pc: String = "0", var module: String = "[unknown]",
        var function: String = "", var offset: Long = 0, var buildId: String = "",
    )

    private fun readFrame(reader: Reader): Frame {
        val frame = Frame()
        reader.fields { field, wire ->
            when {
                field == 1 && wire == 0 -> frame.pc = java.lang.Long.toUnsignedString(reader.number(), 16)
                field == 4 && wire == 2 -> frame.function = reader.text(1024)?.let { DiagnosticRecorder.redact(it, 240) }.orEmpty()
                field == 5 && wire == 0 -> frame.offset = reader.number()
                field == 6 && wire == 2 -> reader.text(2048)?.let { path ->
                    // A module basename retains symbolization value without an
                    // installation path or user document name.
                    val name = path.substringAfterLast('/').substringAfterLast('!').substringAfterLast('\\')
                    if (name.matches(Regex("[A-Za-z0-9_.+-]{1,160}\\.(?:so|apk|oat|odex)"))) frame.module = name
                }
                field == 8 && wire == 2 -> reader.text(128)?.takeIf { it.matches(Regex("[A-Fa-f0-9]{1,128}")) }
                    ?.let { frame.buildId = it }
                else -> reader.skip(wire)
            }
        }
        return frame
    }

    private class Reader(
        private val input: InputStream, private var remaining: Long,
        private val deadline: Long, private val root: Boolean = false,
    ) {
        fun fields(visit: (Int, Int) -> Unit) {
            while (remaining > 0) {
                check(System.nanoTime() < deadline) { "trace time limit" }
                val first = input.read()
                if (first < 0) { if (root) return else throw EOFException() }
                remaining--
                val key = varint(first)
                check(key ushr 3 > 0 && key <= Int.MAX_VALUE) { "invalid trace tag" }
                visit((key ushr 3).toInt(), (key and 7).toInt())
            }
        }

        fun number(): Long = varint(byte())

        private fun varint(first: Int): Long {
            var result = (first and 127).toLong()
            var value = first
            var shift = 7
            while (value and 128 != 0) {
                check(shift <= 63) { "invalid trace number" }
                value = byte()
                if (shift == 63) check(value <= 1) { "invalid trace number" }
                result = result or ((value and 127).toLong() shl shift)
                shift += 7
            }
            return result
        }

        private fun byte(): Int {
            check(remaining > 0) { "truncated trace" }
            val value = input.read()
            if (value < 0) throw EOFException()
            remaining--
            return value
        }

        private fun length(): Long = number().also { check(it >= 0 && it <= remaining) { "trace size limit" } }

        fun message(visit: (Reader) -> Unit) {
            val size = length()
            remaining -= size
            val child = Reader(input, size, deadline)
            visit(child)
            child.skipBytes(child.remaining)
        }

        fun text(limit: Int): String? {
            val size = length()
            if (size > limit) { skipBytes(size); return null }
            val bytes = ByteArray(size.toInt())
            var offset = 0
            while (offset < bytes.size) {
                val count = input.read(bytes, offset, bytes.size - offset)
                if (count < 0) throw EOFException()
                if (count == 0) { bytes[offset++] = byte().toByte(); continue }
                offset += count
                remaining -= count
            }
            return bytes.toString(Charsets.UTF_8)
        }

        fun skip(wire: Int) = when (wire) {
            0 -> { number(); Unit }
            1 -> skipBytes(8)
            2 -> skipBytes(length())
            5 -> skipBytes(4)
            else -> error("unsupported trace field")
        }

        private fun skipBytes(count: Long) {
            check(count in 0..remaining) { "truncated trace field" }
            var left = count
            while (left > 0) {
                check(System.nanoTime() < deadline) { "trace time limit" }
                val skipped = input.skip(minOf(left, 65536))
                if (skipped > 0) { remaining -= skipped; left -= skipped }
                else { byte(); left-- }
            }
        }
    }
}
