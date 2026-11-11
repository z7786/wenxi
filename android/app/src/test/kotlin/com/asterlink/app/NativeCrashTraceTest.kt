package com.asterlink.app

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class NativeCrashTraceTest {
    private fun varint(number: Long): ByteArray {
        val output = ByteArrayOutputStream()
        var value = number
        while (value and -128L != 0L) {
            output.write((value.toInt() and 127) or 128)
            value = value ushr 7
        }
        output.write(value.toInt())
        return output.toByteArray()
    }
    private fun number(field: Int, value: Long) = varint((field shl 3).toLong()) + varint(value)
    private fun message(field: Int, bytes: ByteArray) = varint(((field shl 3) or 2).toLong()) + varint(bytes.size.toLong()) + bytes
    private fun text(field: Int, value: String) = message(field, value.toByteArray())
    private fun frame(module: String = "/data/app/private-install/lib/arm64/libmpv.so") =
        number(1, 0x1234) + number(2, 0x7654321) + number(3, 0x8765432) +
            text(4, "decoder_process") + number(5, 12) + text(6, module) + text(8, "aabbccdd")
    private fun thread(tid: Long, frames: Int = 1): ByteArray =
        number(1, tid) + text(2, "private-thread-name") +
            message(3, text(1, "x0") + number(2, 123456)) +
            (0 until frames).fold(ByteArray(0)) { data, _ -> data + message(4, frame()) } +
            message(5, text(2, "private-memory-map") + message(4, "Cookie=private-memory-secret".toByteArray()))
    private fun entry(tid: Long, reversed: Boolean = false, frames: Int = 1) =
        if (reversed) message(2, thread(tid, frames)) + number(1, tid)
        else number(1, tid) + message(2, thread(tid, frames))
    private fun tombstone(reversed: Boolean = false, frames: Int = 1): ByteArray {
        val threads = message(16, entry(42, reversed, frames)) + message(16, entry(999))
        val metadata = number(1, 1) + number(6, 42) + number(20, 900) +
            message(10, number(1, 11) + text(2, "SIGSEGV") + number(3, 1) + text(4, "SEGV_MAPERR") +
                number(9, 0x123456789) + message(10, text(2, "private-fault-memory")))
        return (if (reversed) threads + metadata else metadata + threads) +
            text(9, "Cookie=private-command-line") + text(14, "private-abort-message") +
            message(18, text(1, "private-logcat")) + message(19, text(2, "/storage/private-file")) +
            message(1001, "private-oem-field".toByteArray())
    }

    @Test fun extractsOnlyCrashSignalAndCrashThreadSymbolsRegardlessOfFieldOrder() {
        for (reverse in listOf(false, true)) {
            val bytes = tombstone(reverse)
            val result = NativeCrashTrace.extract { ByteArrayInputStream(bytes) }
            assertEquals("arm64", result["architecture"])
            assertEquals(42L, result["crashTid"])
            assertEquals(900L, result["processUptimeSeconds"])
            assertEquals("SIGSEGV", result["signalName"])
            assertEquals(11, result["signalNumber"])
            assertEquals("libmpv.so", result["faultModule"])
            assertEquals("0x1234", result["faultOffset"])
            assertEquals(1, result["traceFrameCount"])
            assertTrue(result["trace"].toString().contains("decoder_process+12"))
            assertTrue(result["trace"].toString().contains("BuildId: aabbccdd"))
            for (secret in listOf("private-", "7654321", "8765432", "123456789", "/data/", "/storage/")) {
                assertFalse(secret, result.toString().contains(secret))
            }
        }
    }

    @Test fun frameCountIsBounded() {
        val result = NativeCrashTrace.extract { ByteArrayInputStream(tombstone(frames = 100)) }
        assertEquals(32, result["traceFrameCount"])
        assertEquals(32, result["trace"].toString().lines().size)
    }

    @Test fun unavailableTraceNeverInventsAStack() {
        assertEquals(true, NativeCrashTrace.extract { null }["traceUnavailable"])
        val result = NativeCrashTrace.extract { ByteArrayInputStream(number(6, 42)) }
        assertEquals(true, result["traceUnavailable"])
        assertFalse(result.containsKey("trace"))
    }

    @Test fun rejectsTruncatedAndOversizedProtobufs() {
        val inputs = listOf(
            byteArrayOf(0x82.toByte()),
            varint((16 shl 3 or 2).toLong()) + varint(9 * 1024 * 1024L),
            number(6, 42) + message(16, byteArrayOf(0x82.toByte())),
            byteArrayOf(0x0f),
        )
        for (bytes in inputs) {
            assertTrue(runCatching { NativeCrashTrace.extract { ByteArrayInputStream(bytes) } }.isFailure)
        }
    }

    @Test fun skipsLargeUnknownMemoryWithoutAllocatingOrReadingIt() {
        val prefix = tombstone() + varint((1002 shl 3 or 2).toLong()) + varint(1024 * 1024L)
        // End of the root stream is represented explicitly after the skipped
        // memory block; selected data is still parsed on both passes.
        fun open() = object : java.io.InputStream() {
            var position = 0L
            override fun read(): Int {
                if (position >= prefix.size + 1024 * 1024L) return -1
                if (position >= prefix.size) throw AssertionError("memory must be skipped")
                return prefix[position++.toInt()].toInt() and 255
            }
            override fun skip(count: Long): Long { position += count; return count }
        }
        assertEquals("libmpv.so", NativeCrashTrace.extract(::open)["faultModule"])
    }
}
