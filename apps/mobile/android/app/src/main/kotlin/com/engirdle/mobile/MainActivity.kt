package com.engirdle.mobile

import com.ryanheise.audioservice.AudioServiceActivity

// Extends AudioServiceActivity so the audio_service foreground media Service
// shares the Flutter engine with the activity (design §7.2). This keeps media
// playback alive across screen-off, backgrounding and recents-dismissal.
class MainActivity : AudioServiceActivity()
