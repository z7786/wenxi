package com.asterlink.app

import android.util.AtomicFile
import android.util.Log
import java.io.File
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements

/** Android rename replaces existing files; Windows File.renameTo does not. */
@Implements(AtomicFile::class)
class HostAtomicFile {
    companion object {
        @JvmStatic
        @Implementation(minSdk = 29)
        fun rename(source: File, destination: File) {
            if (destination.isDirectory && !destination.delete()) {
                Log.e("AtomicFile", "Cannot replace a nonempty directory")
                return
            }
            try {
                try {
                    Files.move(source.toPath(), destination.toPath(),
                        StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
                } catch (_: AtomicMoveNotSupportedException) {
                    Files.move(source.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
                }
            } catch (_: IOException) {
                Log.e("AtomicFile", "Atomic file replacement failed")
            }
        }
    }
}
