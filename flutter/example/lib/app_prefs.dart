import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Default persona: a friendly woman named Eva who elaborates on request.
const String kDefaultSystemPrompt =
    "You are Eva, a warm and friendly woman. You chat in a relaxed, kind, and "
    "approachable way. You're always happy to go into detail and give thorough, "
    "helpful explanations whenever the user asks for more.";

const String _kSystemPromptKey = 'system_prompt';

Future<String> loadSystemPrompt() async {
  final prefs = await SharedPreferences.getInstance();
  final v = prefs.getString(_kSystemPromptKey);
  return (v == null || v.trim().isEmpty) ? kDefaultSystemPrompt : v;
}

Future<void> saveSystemPrompt(String value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kSystemPromptKey, value);
}

// ── Theme ────────────────────────────────────────────────────────────────────

/// Current theme mode; the root app rebuilds when this changes.
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(ThemeMode.system);

const String _kThemeModeKey = 'theme_mode';

Future<void> initThemeMode() async {
  final prefs = await SharedPreferences.getInstance();
  themeModeNotifier.value = switch (prefs.getString(_kThemeModeKey)) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

Future<void> setThemeMode(ThemeMode mode) async {
  themeModeNotifier.value = mode;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _kThemeModeKey,
    switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    },
  );
}

// ── Voice input ──────────────────────────────────────────────────────────────

/// Which speech-to-text engine the mic button uses.
/// - [fast]: the bundled offline streaming model (English only).
/// - [system]: the phone's built-in recognizer (many languages, incl. the
///   system language; uses Android's speech service).
enum VoiceEngine { fast, system }

const String _kVoiceEngineKey = 'voice_engine';
const String _kVoiceLocaleKey = 'voice_locale';

Future<VoiceEngine> loadVoiceEngine() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kVoiceEngineKey) == 'system'
      ? VoiceEngine.system
      : VoiceEngine.fast;
}

Future<void> saveVoiceEngine(VoiceEngine engine) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      _kVoiceEngineKey, engine == VoiceEngine.system ? 'system' : 'fast');
}

/// Locale id for the system recognizer (e.g. `pt_BR`). Empty means "auto" —
/// fall back to the device's system locale / let the recognizer decide.
Future<String> loadVoiceLocale() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kVoiceLocaleKey) ?? '';
}

Future<void> saveVoiceLocale(String localeId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kVoiceLocaleKey, localeId);
}
