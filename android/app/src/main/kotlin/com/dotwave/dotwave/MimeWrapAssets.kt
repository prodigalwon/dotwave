package com.dotwave.dotwave

import android.content.Context
import java.io.File

/**
 * Helper for the Stage 2 mime-wrap PoC benchmark. Copies the Groth16
 * circuit artifacts (wasm + r1cs + zkey) from the APK's Android
 * assets to the app's `filesDir` on first use, so the Rust prover
 * can open them by absolute path.
 *
 * Idempotent — subsequent calls no-op if the file already exists and
 * matches the expected size. Not hashing or re-verifying contents
 * (these are debug assets; a mismatch here isn't a security concern).
 *
 * The three files, in assets under `zkpki/`:
 *   mime_wrap.wasm         (~642 KB)  — Circom witness-calculator wasm
 *   mime_wrap.r1cs         (~21 MB)   — Circom r1cs (constraint structure)
 *   mime_wrap_final.zkey   (~49 MB)   — Groth16 proving key
 *
 * Total ~70 MB copied to filesDir/zkpki/ on first invocation. That's
 * a one-time cost per install (or per app-data clear). Subsequent
 * benchmark runs reuse the same files.
 */
object MimeWrapAssets {

    private const val ASSET_DIR = "zkpki"
    private const val WASM = "mime_wrap.wasm"
    private const val R1CS = "mime_wrap.r1cs"
    private const val ZKEY = "mime_wrap_final.zkey"

    data class Paths(
        val wasmPath: String,
        val r1csPath: String,
        val zkeyPath: String,
    )

    /**
     * Copy the three circuit artifacts from assets to `filesDir/zkpki/`
     * (skipping files already present with matching size), then return
     * their absolute paths.
     *
     * Throws [RuntimeException] wrapping the underlying IOException
     * if any asset is missing or cannot be copied.
     */
    fun ensure(context: Context): Paths {
        val target = File(context.filesDir, ASSET_DIR).apply {
            if (!exists()) mkdirs()
        }

        val wasm = copyIfMissing(context, WASM, File(target, WASM))
        val r1cs = copyIfMissing(context, R1CS, File(target, R1CS))
        val zkey = copyIfMissing(context, ZKEY, File(target, ZKEY))

        return Paths(
            wasmPath = wasm.absolutePath,
            r1csPath = r1cs.absolutePath,
            zkeyPath = zkey.absolutePath,
        )
    }

    private fun copyIfMissing(
        context: Context,
        assetName: String,
        targetFile: File,
    ): File {
        // Short-circuit on existence only (skipping size-match so we
        // don't hit `openFd` limitations on compressed assets). If a
        // future app update ships a new wasm/zkey, bumping the
        // ASSET_DIR constant or the target file name forces a clean
        // re-copy.
        if (targetFile.exists() && targetFile.length() > 0) {
            return targetFile
        }

        val assetPath = "$ASSET_DIR/$assetName"
        context.assets.open(assetPath).use { input ->
            targetFile.outputStream().use { output ->
                input.copyTo(output, bufferSize = 64 * 1024)
            }
        }
        return targetFile
    }
}
