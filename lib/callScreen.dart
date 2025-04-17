import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';

class VoiceAssistant extends StatefulWidget {
  const VoiceAssistant({super.key});

  @override
  _VoiceAssistantState createState() => _VoiceAssistantState();
}

class _VoiceAssistantState extends State<VoiceAssistant> with TickerProviderStateMixin {
  late stt.SpeechToText speech;
  late FlutterTts flutterTts;
  bool isListening = false;
  bool isActivelyListening = false;
  String recognizedText = '';
  late DateTime lastSpeechTime;
  late AnimationController _ringingController;
  late Animation<double> _ringingAnimation;
  bool _isSpeaking = false;
  bool isTtsPaused = false;
  String _currentText = '';
  bool _hasSpoken = false;
  String _errorMessage = '';
  String _currentTtsText = '';
  double _soundLevel = 0.0;
  Timer? _checkPauseTimer; // تایمر برای بررسی مکث
  Timer? _silenceTimer; // تایمر برای بررسی ۲ دقیقه سکوت
  DateTime lastActivityTime = DateTime.now(); // زمان آخرین فعالیت (برای ۲ دقیقه سکوت)

  @override
  void initState() {
    super.initState();
    print('[VoiceAssistant] initState: Initializing VoiceAssistant...');
    _ringingController = AnimationController(
      vsync: this,
      duration: Duration(seconds: 1),
    )..repeat(reverse: true);
    _ringingAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _ringingController, curve: Curves.easeInOut),
    );
    print('[VoiceAssistant] initState: AnimationController and Animation set up');

    initSpeechToText();
    initTTS();
  }

  void initSpeechToText() async {
    print('[SpeechToText] initSpeechToText: Initializing...');
    speech = stt.SpeechToText();

    bool hasPermission = await speech.hasPermission;
    print('[SpeechToText] initSpeechToText: Microphone permission: $hasPermission');
    if (!hasPermission) {
      setState(() {
        _errorMessage = 'لطفاً دسترسی میکروفون را فعال کنید.';
        print('[SpeechToText] initSpeechToText: No microphone permission');
      });
      return;
    }

    List<stt.LocaleName> locales = await speech.locales();
    print('[SpeechToText] initSpeechToText: Available locales: ${locales.map((locale) => locale.localeId).toList()}');
    String selectedLocale = 'en-US';
    bool isEnUsAvailable = locales.any((locale) => locale.localeId == 'en-US' || locale.localeId == 'en_US');
    bool isFaIrAvailable = locales.any((locale) => locale.localeId == 'fa-IR' || locale.localeId == 'fa_IR');
    if (!isEnUsAvailable && !isFaIrAvailable) {
      print('[SpeechToText] initSpeechToText: Neither en-US/en_US nor fa-IR/fa_IR available, using default locale');
      selectedLocale = locales.isNotEmpty ? locales[0].localeId : 'en-US';
    } else if (isFaIrAvailable) {
      selectedLocale = locales.firstWhere((locale) => locale.localeId == 'fa-IR' || locale.localeId == 'fa_IR').localeId;
      print('[SpeechToText] initSpeechToText: fa-IR/fa_IR available, using Persian');
    } else {
      selectedLocale = locales.firstWhere((locale) => locale.localeId == 'en-US' || locale.localeId == 'en_US').localeId;
      print('[SpeechToText] initSpeechToText: en-US/en_US available, using English');
    }
    print('[SpeechToText] initSpeechToText: Selected locale: $selectedLocale');

    bool available = await speech.initialize(
      onStatus: (status) {
        print('[SpeechToText] onStatus: Status: $status');
        if (status == 'done' || status == 'notListening') {
          if (!_isSpeaking) {
            print('[SpeechToText] onStatus: Speech stopped, restarting listening...');
            startListening();
          } else {
            print('[SpeechToText] onStatus: TTS is speaking, will restart after TTS finishes.');
          }
        }
      },
      onError: (error) {
        print('[SpeechToText] onError: Error: $error');
        setState(() {
          _errorMessage = 'خطا در تشخیص صدا: $error';
          isListening = false;
        });
        if (!_isSpeaking) {
          print('[SpeechToText] onError: Not speaking, restarting listening...');
          Future.delayed(Duration(milliseconds: 500), () {
            startListening();
          });
        }
      },
    );

    if (available) {
      print('[SpeechToText] initSpeechToText: Initialized successfully.');
      lastSpeechTime = DateTime.now();
      lastActivityTime = DateTime.now();
      startListening();
    } else {
      print('[SpeechToText] initSpeechToText: Not available.');
      setState(() {
        _errorMessage = 'تشخیص صدا در دسترس نیست.';
      });
    }
  }

  void initTTS() {
    print('[TTS] initTTS: Initializing...');
    flutterTts = FlutterTts();
    flutterTts.setLanguage("en-US");
    print('[TTS] initTTS: Language set to en-US');
    flutterTts.setSpeechRate(0.5);
    print('[TTS] initTTS: Speech rate set to 0.5');
    flutterTts.setVolume(1.0);
    print('[TTS] initTTS: Volume set to 1.0');
    flutterTts.setStartHandler(() {
      setState(() {
        _isSpeaking = true;
        isTtsPaused = false;
      });
      print('[TTS] setStartHandler: TTS started speaking, _isSpeaking: $_isSpeaking');
    });
    flutterTts.setCompletionHandler(() {
      setState(() {
        _isSpeaking = false;
        isTtsPaused = false;
        _currentTtsText = '';
      });
      print('[TTS] setCompletionHandler: TTS completed, _isSpeaking: $_isSpeaking');
      startListening();
    });
    flutterTts.setErrorHandler((msg) {
      setState(() {
        _errorMessage = 'خطا در TTS: $msg';
        _isSpeaking = false;
        isTtsPaused = false;
        _currentTtsText = '';
      });
      print('[TTS] setErrorHandler: TTS error: $msg, _isSpeaking: $_isSpeaking');
      startListening();
    });
  }

  void startListening() async {
    print('[SpeechToText] startListening: Attempting to start listening...');
    if (!await speech.hasPermission) {
      print('[SpeechToText] startListening: No permission.');
      setState(() {
        _errorMessage = 'لطفاً دسترسی میکروفون را فعال کنید.';
      });
      return;
    }

    if (speech.isListening) {
      print('[SpeechToText] startListening: Already listening, skipping...');
      return;
    }

    if (_isSpeaking) {
      print('[SpeechToText] startListening: TTS is speaking, cannot listen.');
      return;
    }

    print('[SpeechToText] startListening: Starting to listen...');
    setState(() {
      isListening = true;
      isActivelyListening = false;
      recognizedText = '';
      _currentText = '';
      _hasSpoken = false;
      _errorMessage = '';
    });
    _ringingController.forward();
    print('[SpeechToText] startListening: Animation started');
    lastSpeechTime = DateTime.now();
    lastActivityTime = DateTime.now();
    print('[SpeechToText] startListening: Set lastSpeechTime to $lastSpeechTime, lastActivityTime to $lastActivityTime');

    speech.listen(
      onResult: (result) {
        setState(() {
          _currentText = result.recognizedWords;
          recognizedText = _currentText;
          print('[SpeechToText] onResult: Recognized Text: $_currentText');
          _hasSpoken = true;
          lastSpeechTime = DateTime.now();
          lastActivityTime = DateTime.now();
          print('[SpeechToText] onResult: Updated lastSpeechTime to $lastSpeechTime, lastActivityTime to $lastActivityTime');

          if (!isActivelyListening) {
            print('[SpeechToText] onResult: Voice detected, switching to active listening mode');
            isActivelyListening = true;
          }
        });
        _startPauseCheck();
      },
      onSoundLevelChange: (level) {
        setState(() {
          _soundLevel = level;
          lastActivityTime = DateTime.now();
          print('[SpeechToText] onSoundLevelChange: Sound level: $level, lastActivityTime: $lastActivityTime');
          if (level > 5.0) {
            print('[SpeechToText] onSoundLevelChange: Significant sound detected');
          }
        });
      },
      localeId: "en-US",
      listenMode: stt.ListenMode.dictation,
      cancelOnError: false,
      onDevice: false,
    );

    // تایمر برای بررسی ۲ دقیقه سکوت
    _silenceTimer?.cancel();
    _silenceTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      final timeSinceLastActivity = DateTime.now().difference(lastActivityTime).inSeconds;
      print('[SpeechToText] SilenceTimer: Time since last activity: $timeSinceLastActivity seconds');
      if (timeSinceLastActivity >= 120) { // ۲ دقیقه = ۱۲۰ ثانیه
        print('[SpeechToText] SilenceTimer: 2 minutes of silence detected, stopping listening...');
        stopListening();
        timer.cancel();
      }
    });
  }

  void _startPauseCheck() {
    print('[SpeechToText] startPauseCheck: Starting pause check...');
    _checkPauseTimer?.cancel();
    _checkPauseTimer = Timer.periodic(Duration(milliseconds: 500), (timer) {
      if (_isSpeaking) {
        print('[SpeechToText] startPauseCheck: TTS is speaking, stopping pause check.');
        timer.cancel();
        return;
      }

      if (!isListening) {
        print('[SpeechToText] startPauseCheck: Not listening, stopping pause check.');
        timer.cancel();
        return;
      }

      if (isActivelyListening && _hasSpoken && _currentText.isNotEmpty) {
        final timeSinceLastSpeech = DateTime.now().difference(lastSpeechTime).inMilliseconds;
        print('[SpeechToText] startPauseCheck: Time since last speech: $timeSinceLastSpeech ms');
        if (timeSinceLastSpeech >= 3000) { // ۳ ثانیه مکث
          print('[SpeechToText] startPauseCheck: 3 seconds pause detected, sending text: $_currentText');
          speech.stop();
          setState(() {
            isListening = false;
            isActivelyListening = false;
          });
          timer.cancel();
          sendToGemini(_currentText);
        }
      } else {
        print('[SpeechToText] startPauseCheck: Waiting for speech...');
      }
    });
  }

  Future<void> sendToGemini(String prompt) async {
    print('[Gemini] sendToGemini: Sending to Gemini: $prompt');
    final url = Uri.parse(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=AIzaSyCkHefKxNsnIlW7-N17w1_kS8NLQGUXl1A");

    final response = await http.post(
      url,
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "contents": [
          {
            "parts": [
              {"text": prompt}
            ]
          }
        ]
      }),
    );

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      final text = json["candidates"][0]["content"]["parts"][0]["text"];
      print('[Gemini] sendToGemini: Gemini Response: $text');
      speak(text);
    } else {
      print('[Gemini] sendToGemini: Failed to get response from Gemini: ${response.body}');
      setState(() {
        _errorMessage = 'خطا در دریافت پاسخ از Gemini: ${response.statusCode}';
      });
      startListening();
    }
  }

  Future<void> speak(String text) async {
    print('[TTS] speak: Speaking: $text');
    setState(() {
      _isSpeaking = true;
      isTtsPaused = false;
      _currentTtsText = text;
    });
    await flutterTts.stop();
    print('[TTS] speak: TTS stopped before speaking');
    await flutterTts.speak(text);
    print('[TTS] speak: TTS started speaking');
  }

  void toggleTts() async {
    if (_isSpeaking) {
      if (isTtsPaused) {
        print('[TTS] toggleTts: Resuming TTS...');
        if (_currentTtsText.isNotEmpty) {
          await flutterTts.speak(_currentTtsText);
          setState(() {
            isTtsPaused = false;
          });
          print('[TTS] toggleTts: Resumed TTS, isTtsPaused: $isTtsPaused');
        }
      } else {
        print('[TTS] toggleTts: Pausing TTS...');
        await flutterTts.pause();
        setState(() {
          isTtsPaused = true;
        });
        print('[TTS] toggleTts: Paused TTS, isTtsPaused: $isTtsPaused');
      }
    }
  }

  void stopListening() {
    print('[SpeechToText] stopListening: Stopping listening...');
    speech.stop();
    setState(() {
      isListening = false;
      isActivelyListening = false;
      recognizedText = '';
      _currentText = '';
      _hasSpoken = false;
    });
    _ringingController.stop();
    print('[SpeechToText] stopListening: Animation stopped');
    _checkPauseTimer?.cancel();
    _silenceTimer?.cancel();
  }

  @override
  void dispose() {
    print('[VoiceAssistant] dispose: Disposing VoiceAssistant...');
    speech.stop();
    print('[SpeechToText] dispose: SpeechToText stopped');
    flutterTts.stop();
    print('[TTS] dispose: FlutterTts stopped');
    _ringingController.dispose();
    print('[VoiceAssistant] dispose: AnimationController disposed');
    _checkPauseTimer?.cancel();
    _silenceTimer?.cancel();
    super.dispose();
    print('[VoiceAssistant] dispose: VoiceAssistant disposed');
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    return Scaffold(
      appBar: AppBar(),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF2A1B3D), Color(0xFF44318D)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedBuilder(
                animation: _ringingAnimation,
                builder: (context, child) {
                  return Transform.scale(
                    scale: _ringingAnimation.value,
                    child: Container(
                      width: screenWidth * 0.7,
                      height: screenWidth * 0.7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            isActivelyListening
                                ? Color(0xFF00FF00).withOpacity(0.8)
                                : Color(0xFFD8B5FF).withOpacity(0.8),
                            Colors.transparent,
                          ],
                        ),
                        border: Border.all(
                          color: Color(0xFF8EC5FC).withOpacity(0.6),
                          width: 5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0xFFD8B5FF).withOpacity(0.5),
                            blurRadius: 20,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: Center(
                        child: Icon(
                          Icons.phone,
                          color: Colors.white,
                          size: screenWidth * 0.3,
                        ),
                      ),
                    ),
                  );
                },
              ),
              SizedBox(height: 20),
              Text(
                recognizedText.isNotEmpty ? "تشخیص داده‌شده: $recognizedText" : "",
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 18,
                ),
              ),
              SizedBox(height: 10),
              Text(
                _errorMessage,
                style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: 16,
                ),
              ),
              SizedBox(height: 10),
              Text(
                'سطح صدا: $_soundLevel',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                ),
              ),
              SizedBox(height: 40),
              if (_isSpeaking)
                IconButton(
                  onPressed: toggleTts,
                  icon: Icon(
                    isTtsPaused ? Icons.play_arrow : Icons.pause,
                    color: Colors.white,
                    size: 40,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: Color(0xFFD8B5FF),
                    padding: EdgeInsets.all(15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}