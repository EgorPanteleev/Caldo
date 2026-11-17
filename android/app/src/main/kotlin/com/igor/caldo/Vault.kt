package com.igor.caldo

import android.app.Activity
import android.app.KeyguardManager
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.PersistableBundle
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * What the vault (`services/vault_device.dart`) needs of the phone itself.
 *
 * Unlocking by fingerprint: the vault's key, which Dart otherwise opens
 * with the master password, is sealed a second time with a key of the
 * Keystore's that cannot be used without a fingerprint — or, from Android
 * 11, the phone's own PIN — shown to [BiometricPrompt] for that one use.
 * The Keystore key never leaves the secure hardware, and a fingerprint
 * added to the phone afterwards ends it ([KeyPermanentlyInvalidatedException],
 * answered as "gone"), so someone who learns the phone's PIN cannot enrol
 * their own finger and walk in. The master password always still works.
 *
 * Android's own BiometricPrompt rather than AndroidX's: that one needs a
 * FragmentActivity, and Flutter's activity is not one. It is there from
 * Android 9; before that the vault opens by password alone.
 *
 * Also: keeping the vault out of screenshots and the recent apps while it
 * is open, and the clipboard for a copied password.
 */
class Vault(private val activity: Activity) {
    /** The prompt waiting on the user, answered once. */
    private var answer: MethodChannel.Result? = null
    private var cancel: CancellationSignal? = null

    fun call(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> result.success(available())
            "seal" -> seal(
                call.argument<ByteArray>("key")!!,
                call.argument<Map<String, String>>("words")!!,
                result,
            )
            "open" -> open(
                call.argument<ByteArray>("box")!!,
                call.argument<Map<String, String>>("words")!!,
                result,
            )
            "forget" -> {
                forget()
                result.success(null)
            }
            "secure" -> {
                secure(call.argument<Boolean>("on")!!)
                result.success(null)
            }
            "copy" -> {
                copy(call.argument<String>("text")!!)
                result.success(null)
            }
            "clearIf" -> result.success(clearIf(call.argument<String>("text")!!))
            else -> result.notImplemented()
        }
    }

    /**
     * Whether there is anything to unlock with: a fingerprint enrolled or,
     * from Android 11, at least a screen lock.
     */
    private fun available(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        val keyguard = activity.getSystemService(KeyguardManager::class.java)
        if (keyguard?.isDeviceSecure != true) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val manager = activity.getSystemService(BiometricManager::class.java)
            return manager?.canAuthenticate(AUTHENTICATORS) == BiometricManager.BIOMETRIC_SUCCESS
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val manager = activity.getSystemService(BiometricManager::class.java)
            @Suppress("DEPRECATION")
            return manager?.canAuthenticate() == BiometricManager.BIOMETRIC_SUCCESS
        }
        return activity.packageManager.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT)
    }

    /**
     * Makes a new Keystore key and, once the user has shown a finger, seals
     * [key] with it: answered with the nonce and the box, which Dart keeps.
     */
    private fun seal(key: ByteArray, words: Map<String, String>, result: MethodChannel.Result) {
        val cipher = try {
            Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, newKey()) }
        } catch (e: Exception) {
            // No fingerprint enrolled after all, or no screen lock.
            result.error("unavailable", e.message, null)
            return
        }
        prompt(cipher, words, result) { done ->
            val box = done.doFinal(key)
            done.iv + box
        }
    }

    /** Opens what [seal] answered with, once the user has shown a finger. */
    private fun open(box: ByteArray, words: Map<String, String>, result: MethodChannel.Result) {
        val key = storedKey()
        if (key == null || box.size <= NONCE) {
            result.error("gone", null, null)
            return
        }
        val cipher = try {
            Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, box, 0, NONCE))
            }
        } catch (_: KeyPermanentlyInvalidatedException) {
            forget()
            result.error("gone", null, null)
            return
        } catch (e: Exception) {
            result.error("unavailable", e.message, null)
            return
        }
        prompt(cipher, words, result) { done -> done.doFinal(box, NONCE, box.size - NONCE) }
    }

    private fun prompt(
        cipher: Cipher,
        words: Map<String, String>,
        result: MethodChannel.Result,
        use: (Cipher) -> ByteArray,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            result.error("unavailable", null, null)
            return
        }
        // One at a time: a second ask cancels the first, which answers
        // as cancelled.
        cancel?.cancel()
        answer?.error("cancelled", null, null)
        answer = result
        val executor = activity.mainExecutor
        val builder = BiometricPrompt.Builder(activity)
            .setTitle(words["title"] ?: "Caldo")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Fingerprint or the phone's PIN; with the PIN on offer there is
            // no button of ours, the prompt has its own way out.
            builder.setAllowedAuthenticators(AUTHENTICATORS)
        } else {
            builder.setNegativeButton(words["cancel"] ?: "Cancel", executor) { _, _ ->
                finish { it.error("cancelled", null, null) }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setConfirmationRequired(false)
        val signal = CancellationSignal()
        cancel = signal
        builder.build().authenticate(
            BiometricPrompt.CryptoObject(cipher),
            signal,
            executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(done: BiometricPrompt.AuthenticationResult) {
                    finish {
                        try {
                            // The cipher the prompt was given, now unlocked
                            // for this one use.
                            it.success(use(done.cryptoObject?.cipher ?: cipher))
                        } catch (e: Exception) {
                            it.error("failed", e.message, null)
                        }
                    }
                }

                override fun onAuthenticationError(code: Int, message: CharSequence?) {
                    val why = when (code) {
                        BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED,
                        BiometricPrompt.BIOMETRIC_ERROR_CANCELED,
                        BiometricPrompt.BIOMETRIC_ERROR_TIMEOUT -> "cancelled"
                        else -> "failed"
                    }
                    finish { it.error(why, message?.toString(), null) }
                }
            },
        )
    }

    private fun finish(with: (MethodChannel.Result) -> Unit) {
        val waiting = answer ?: return
        answer = null
        cancel = null
        with(waiting)
    }

    private fun newKey(): SecretKey {
        forget()
        val spec = KeyGenParameterSpec.Builder(
            ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
            .apply {
                // Before Android 11 a key used once per authentication can
                // only be unlocked by a fingerprint, which is the default.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    setUserAuthenticationParameters(
                        0,
                        KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL,
                    )
                }
            }
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
            .apply { init(spec) }
            .generateKey()
    }

    private fun storedKey(): SecretKey? =
        KeyStore.getInstance(KEYSTORE).apply { load(null) }.getKey(ALIAS, null) as SecretKey?

    private fun forget() {
        KeyStore.getInstance(KEYSTORE).apply { load(null) }.deleteEntry(ALIAS)
    }

    /**
     * Keeps the window out of screenshots, screen recordings and the recent
     * apps' thumbnails — while the vault is open on screen, not otherwise.
     */
    private fun secure(on: Boolean) {
        val flag = WindowManager.LayoutParams.FLAG_SECURE
        if (on) activity.window.addFlags(flag) else activity.window.clearFlags(flag)
    }

    private val clipboard: ClipboardManager
        get() = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    /**
     * Copies [text] marked as sensitive, which Android 13 and later honour
     * by not showing it in the preview that pops up after a copy, nor in
     * the keyboard's clipboard suggestions.
     */
    private fun copy(text: String) {
        val clip = ClipData.newPlainText(LABEL, text)
        clip.description.extras = PersistableBundle().apply {
            putBoolean(
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    ClipDescription.EXTRA_IS_SENSITIVE
                } else {
                    "android.content.extra.IS_SENSITIVE"
                },
                true,
            )
        }
        clipboard.setPrimaryClip(clip)
    }

    /**
     * Empties the clipboard if it still holds [text] — not if something else
     * has been copied since, which is the user's. Android hides the
     * clipboard from an app in the background, so this can only be told
     * while Caldo is in front; Dart asks again when it comes back.
     */
    private fun clearIf(text: String): Boolean {
        val clip = clipboard.primaryClip ?: return false
        if (clip.itemCount == 0) return true
        if (clip.getItemAt(0).text?.toString() != text) return true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            clipboard.clearPrimaryClip()
        } else {
            clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
        }
        return true
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "caldo_vault"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val NONCE = 12
        const val LABEL = "Caldo"

        /** A fingerprint (or face, where it is strong enough), or the PIN. */
        const val AUTHENTICATORS = BiometricManager.Authenticators.BIOMETRIC_STRONG or
            BiometricManager.Authenticators.DEVICE_CREDENTIAL
    }
}
