package com.edgardev.mobile_app

import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.edgardev.mobile_app/media_session"
    private var methodChannel: MethodChannel? = null
    private var mediaSession: MediaSession? = null
    private var audioTrack: AudioTrack? = null
    private var isSilentAudioRunning = false
    private var audioThread: Thread? = null

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
                else -> result.notImplemented()
            }
        }
    }

    private fun startMediaSession() {
        if (mediaSession != null && mediaSession!!.isActive) return

        try {
            mediaSession = MediaSession(this, "SmartwatchPresenterSession").apply {
                setFlags(
                    MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
                )

                val stateBuilder = PlaybackState.Builder()
                    .setActions(
                        PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_SKIP_TO_NEXT or
                        PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                        PlaybackState.ACTION_STOP
                    )
                    .setState(PlaybackState.STATE_PLAYING, 0L, 1.0f)

                setPlaybackState(stateBuilder.build())

                val metadataBuilder = MediaMetadata.Builder()
                    .putString(MediaMetadata.METADATA_KEY_TITLE, "Control de Diapositivas")
                    .putString(MediaMetadata.METADATA_KEY_ARTIST, "Smartwatch Presenter")
                    .putString(MediaMetadata.METADATA_KEY_ALBUM, "Presentación")
                    .putLong(MediaMetadata.METADATA_KEY_DURATION, -1L)

                setMetadata(metadataBuilder.build())

                setCallback(object : MediaSession.Callback() {
                    override fun onSkipToNext() {
                        super.onSkipToNext()
                        dispatchMediaAction("forward")
                    }

                    override fun onSkipToPrevious() {
                        super.onSkipToPrevious()
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
                                KeyEvent.KEYCODE_MEDIA_NEXT -> {
                                    dispatchMediaAction("forward")
                                    return true
                                }
                                KeyEvent.KEYCODE_MEDIA_PREVIOUS -> {
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
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun stopMediaSession() {
        stopSilentAudio()
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
        runOnUiThread {
            methodChannel?.invokeMethod("onMediaAction", action)
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_MEDIA_NEXT -> {
                    dispatchMediaAction("forward")
                    return true
                }
                KeyEvent.KEYCODE_MEDIA_PREVIOUS -> {
                    dispatchMediaAction("back")
                    return true
                }
                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                KeyEvent.KEYCODE_HEADSETHOOK -> {
                    dispatchMediaAction("play_pause")
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        stopMediaSession()
        super.onDestroy()
    }
}
