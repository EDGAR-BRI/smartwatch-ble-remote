package com.edgardev.mobile_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaMetadata
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.KeyEvent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.edgardev.mobile_app/media_session"
    private var methodChannel: MethodChannel? = null
    private var mediaSession: MediaSession? = null
    private var audioTrack: AudioTrack? = null
    private var isSilentAudioRunning = false
    private var audioThread: Thread? = null

    // Debounce de 140ms para evitar saltos dobles al girar la corona/rueda rápidamente
    private var lastActionTime = 0L
    private val THROTTLE_MS = 140L

    // Control de volumen neutro (baseline) para capturar giro de corona / rueda sin saturar ni alterar volumen del teléfono
    private var originalVolume = -1
    private var baselineVolume = 7
    private var volumeReceiver: BroadcastReceiver? = null
    private var volumeObserver: ContentObserver? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startMediaSession" -> {
                    startMediaSession()
                    result.success(true)
                }
                "stopMediaSession" -> {
                    stopMediaSession()
                    result.success(true)
                }
                "isMediaSessionActive" -> {
                    result.success(mediaSession?.isActive == true)
                }
                "getCacheDir" -> {
                    result.success(cacheDir.absolutePath)
                }
                "canInstallApk" -> {
                    val canInstall = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        packageManager.canRequestPackageInstalls()
                    } else {
                        true
                    }
                    result.success(canInstall)
                }
                "requestInstallPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INTENT_ERROR", e.message, null)
                        }
                    } else {
                        result.success(true)
                    }
                }
                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath != null) {
                        try {
                            val file = File(filePath)
                            if (!file.exists()) {
                                result.error("FILE_NOT_FOUND", "Archivo no encontrado: $filePath", null)
                                return@setMethodCallHandler
                            }
                            val authority = "${applicationContext.packageName}.fileprovider"
                            val apkUri = FileProvider.getUriForFile(this, authority, file)
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(apkUri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARG", "filePath es requerido", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startMediaSession() {
        if (mediaSession != null && mediaSession!!.isActive) return

        try {
            requestAudioFocus()

            mediaSession = MediaSession(this, "SmartwatchPresenterSession").apply {
                setFlags(
                    MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
                )

                // 1. Configurar control de volumen remoto (rueda del reloj / corona digital)
                val volumeProvider = object : VolumeProvider(
                    VOLUME_CONTROL_RELATIVE,
                    100,
                    50
                ) {
                    override fun onAdjustVolume(direction: Int) {
                        if (direction > 0) {
                            // Corona gira horario / Subir volumen ➔ Siguiente
                            dispatchMediaAction("forward")
                        } else if (direction < 0) {
                            // Corona gira antihorario / Bajar volumen ➔ Anterior
                            dispatchMediaAction("back")
                        }
                    }
                }
                setPlaybackToRemote(volumeProvider)

                // 2. Estado de reproducción activo con todas las acciones posibles
                val stateBuilder = PlaybackState.Builder()
                    .setActions(
                        PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_SKIP_TO_NEXT or
                        PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                        PlaybackState.ACTION_FAST_FORWARD or
                        PlaybackState.ACTION_REWIND or
                        PlaybackState.ACTION_STOP
                    )
                    .setState(PlaybackState.STATE_PLAYING, 0L, 1.0f)

                setPlaybackState(stateBuilder.build())

                // 3. Metadatos multimedia
                val metadataBuilder = MediaMetadata.Builder()
                    .putString(MediaMetadata.METADATA_KEY_TITLE, "Control de Diapositivas")
                    .putString(MediaMetadata.METADATA_KEY_ARTIST, "Smartwatch Presenter")
                    .putString(MediaMetadata.METADATA_KEY_ALBUM, "Presentación")
                    .putLong(MediaMetadata.METADATA_KEY_DURATION, -1L)

                setMetadata(metadataBuilder.build())

                // 4. Callback para botones de transporte multimedia
                setCallback(object : MediaSession.Callback() {
                    override fun onSkipToNext() {
                        super.onSkipToNext()
                        dispatchMediaAction("forward")
                    }

                    override fun onSkipToPrevious() {
                        super.onSkipToPrevious()
                        dispatchMediaAction("back")
                    }

                    override fun onFastForward() {
                        super.onFastForward()
                        dispatchMediaAction("forward")
                    }

                    override fun onRewind() {
                        super.onRewind()
                        dispatchMediaAction("back")
                    }

                    override fun onPlay() {
                        super.onPlay()
                        dispatchMediaAction("play_pause")
                    }

                    override fun onPause() {
                        super.onPause()
                        dispatchMediaAction("play_pause")
                    }

                    override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                        val event = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                        }

                        if (event != null && event.action == KeyEvent.ACTION_DOWN) {
                            when (event.keyCode) {
                                KeyEvent.KEYCODE_VOLUME_UP -> {
                                    dispatchMediaAction("forward")
                                    return true
                                }
                                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                                    dispatchMediaAction("back")
                                    return true
                                }
                                KeyEvent.KEYCODE_MEDIA_NEXT,
                                KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                                    dispatchMediaAction("forward")
                                    return true
                                }
                                KeyEvent.KEYCODE_MEDIA_PREVIOUS,
                                KeyEvent.KEYCODE_MEDIA_REWIND -> {
                                    dispatchMediaAction("back")
                                    return true
                                }
                                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                                KeyEvent.KEYCODE_HEADSETHOOK,
                                KeyEvent.KEYCODE_MEDIA_PLAY,
                                KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                                    dispatchMediaAction("play_pause")
                                    return true
                                }
                            }
                        }
                        return super.onMediaButtonEvent(mediaButtonIntent)
                    }
                })

                isActive = true
            }

            startSilentAudio()
            showForegroundNotification()
            registerVolumeListeners()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private val NOTIFICATION_ID = 2026
    private val CHANNEL_ID = "smartwatch_presenter_bg"

    private fun showForegroundNotification() {
        try {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "Smartwatch Presenter en Segundo Plano",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Mantiene los controles multimedia y la conexión activos en segundo plano"
                    setShowBadge(false)
                }
                notificationManager.createNotificationChannel(channel)
            }

            val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
                .setContentTitle("Smartwatch Presenter Activo")
                .setContentText("Controlando diapositivas en segundo plano (Rueda + Música)")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setOngoing(true)
                .build()

            notificationManager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun cancelNotification() {
        try {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.cancel(NOTIFICATION_ID)
        } catch (_: Exception) {}
    }

    private fun requestAudioFocus() {
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .build()
                audioManager.requestAudioFocus(focusRequest)
            } else {
                @Suppress("DEPRECATION")
                audioManager.requestAudioFocus(null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun stopMediaSession() {
        unregisterVolumeListeners()
        stopSilentAudio()
        cancelNotification()
        try {
            mediaSession?.apply {
                isActive = false
                release()
            }
            mediaSession = null
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun startSilentAudio() {
        if (isSilentAudioRunning) return
        isSilentAudioRunning = true

        audioThread = thread(start = true, name = "SilentAudioLoop") {
            try {
                val sampleRate = 44100
                val minBufferSize = AudioTrack.getMinBufferSize(
                    sampleRate,
                    AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                )
                val bufferSize = if (minBufferSize > 0) minBufferSize else 4096

                val track = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(sampleRate)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .build()
                    )
                    .setBufferSizeInBytes(bufferSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()

                audioTrack = track
                val silenceBuffer = ShortArray(bufferSize / 2)

                track.play()
                while (isSilentAudioRunning) {
                    track.write(silenceBuffer, 0, silenceBuffer.size)
                    Thread.sleep(60)
                }
            } catch (_: Exception) {
            } finally {
                try {
                    audioTrack?.stop()
                    audioTrack?.release()
                } catch (_: Exception) {}
            }
        }
    }

    private fun stopSilentAudio() {
        isSilentAudioRunning = false
        try {
            audioTrack?.stop()
            audioTrack?.release()
            audioTrack = null
        } catch (_: Exception) {}
        audioThread?.interrupt()
        audioThread = null
    }

    private fun dispatchMediaAction(action: String) {
        val now = System.currentTimeMillis()
        if (now - lastActionTime < THROTTLE_MS) return
        lastActionTime = now

        runOnUiThread {
            methodChannel?.invokeMethod("onMediaAction", action)
        }
    }

    private fun registerVolumeListeners() {
        if (volumeReceiver != null && volumeObserver != null) return

        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            originalVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
            val maxVol = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            baselineVolume = if (maxVol > 2) maxVol / 2 else 1

            // Configurar volumen neutro sin emitir sonido ni mostrar interfaz
            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, baselineVolume, 0)

            // 1. BroadcastReceiver para android.media.VOLUME_CHANGED_ACTION
            if (volumeReceiver == null) {
                val receiver = object : BroadcastReceiver() {
                    override fun onReceive(context: Context?, intent: Intent?) {
                        if (intent?.action == "android.media.VOLUME_CHANGED_ACTION") {
                            val streamType = intent.getIntExtra("android.media.EXTRA_VOLUME_STREAM_TYPE", -1)
                            if (streamType == AudioManager.STREAM_MUSIC) {
                                val newVol = intent.getIntExtra("android.media.EXTRA_VOLUME_STREAM_VALUE", -1)
                                if (newVol >= 0) {
                                    handleVolumeChange(newVol)
                                }
                            }
                        }
                    }
                }
                volumeReceiver = receiver
                val filter = IntentFilter("android.media.VOLUME_CHANGED_ACTION")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
                } else {
                    registerReceiver(receiver, filter)
                }
            }

            // 2. ContentObserver como respaldo para eventos del sistema
            if (volumeObserver == null) {
                val observer = object : ContentObserver(mainHandler) {
                    override fun onChange(selfChange: Boolean) {
                        super.onChange(selfChange)
                        val curr = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                        handleVolumeChange(curr)
                    }
                }
                volumeObserver = observer
                contentResolver.registerContentObserver(
                    Settings.System.CONTENT_URI,
                    true,
                    observer
                )
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun unregisterVolumeListeners() {
        try {
            volumeReceiver?.let {
                unregisterReceiver(it)
                volumeReceiver = null
            }
        } catch (_: Exception) {}

        try {
            volumeObserver?.let {
                contentResolver.unregisterContentObserver(it)
                volumeObserver = null
            }
        } catch (_: Exception) {}

        // Restaurar el volumen original del usuario
        try {
            if (originalVolume >= 0) {
                val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, originalVolume, 0)
                originalVolume = -1
            }
        } catch (_: Exception) {}
    }

    private fun handleVolumeChange(currentVolume: Int) {
        if (currentVolume == baselineVolume) return

        val diff = currentVolume - baselineVolume
        if (diff > 0) {
            // Corona giró horario / Subir volumen ➔ Siguiente
            dispatchMediaAction("forward")
        } else if (diff < 0) {
            // Corona giró antihorario / Bajar volumen ➔ Anterior
            dispatchMediaAction("back")
        }

        // Restablecer de inmediato al punto neutro sin UI ni sonido para evitar saturar el volumen
        mainHandler.post {
            try {
                val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, baselineVolume, 0)
            } catch (_: Exception) {}
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_VOLUME_UP || event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            if (event.action == KeyEvent.ACTION_DOWN) {
                if (event.keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
                    dispatchMediaAction("forward")
                } else {
                    dispatchMediaAction("back")
                }
            }
            return true // Consume tanto ACTION_DOWN como ACTION_UP para anular el cambio de volumen en el teléfono
        }

        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_MEDIA_NEXT,
                KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                    dispatchMediaAction("forward")
                    return true
                }
                KeyEvent.KEYCODE_MEDIA_PREVIOUS,
                KeyEvent.KEYCODE_MEDIA_REWIND -> {
                    dispatchMediaAction("back")
                    return true
                }
                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                KeyEvent.KEYCODE_HEADSETHOOK,
                KeyEvent.KEYCODE_MEDIA_PLAY,
                KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                    dispatchMediaAction("play_pause")
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        unregisterVolumeListeners()
        stopMediaSession()
        super.onDestroy()
    }
}
