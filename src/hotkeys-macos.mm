/** @fileoverview Carbon RegisterEventHotKey glue for the serve mode.
 *  Minimal C ABI so serve.cpp stays portable C++. */
#include <Carbon/Carbon.h>

#ifdef __APPLE__

#include <QString>
#include <QStringList>
#include <QtGlobal>

// 'omsn' as a FourCharCode, spelled numerically to dodge multichar warnings.
enum { kHotkeySignature = 0x6F6D736E };

enum {
  kHotkeyRegion = 1,
  kHotkeyWindow = 2,
  kHotkeyFullscreen = 3,
};

struct HotkeySpec {
  /** Environment override name, e.g. OMASNAP_HOTKEY_REGION. */
  const char *envName;
  /** Default combo in "cmd+shift+r" spelling. */
  const char *defaultCombo;
  const char *mode;
};

/** Serve defaults deliberately mirror the macOS system screenshot family
 *  (cmd+shift+…) without colliding with cmd+shift+3/4/5. */
constexpr HotkeySpec kSpecs[3] = {
    {"OMASNAP_HOTKEY_REGION", "cmd+shift+r", "region"},
    {"OMASNAP_HOTKEY_WINDOW", "cmd+shift+w", "window"},
    {"OMASNAP_HOTKEY_FULLSCREEN", "cmd+shift+f", "fullscreen"},
};

constexpr int kHotkeyCount = 3;

struct ParsedCombo {
  UInt32 keyCode = 0;
  UInt32 modifiers = 0;
  bool valid = false;
};

/** Maps one lowercased key token to a Carbon virtual keycode. */
int keyTokenToCarbon(const QString &token, bool &ok) {
  ok = true;
  const QChar first = token.isEmpty() ? QChar() : token.front();
  if (token.size() == 1 && first >= QLatin1Char('a') &&
      first <= QLatin1Char('z')) {
    static const int kLetters[26] = {
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E,
        kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
        kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O,
        kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
        kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y,
        kVK_ANSI_Z};
    return kLetters[first.toLatin1() - 'a'];
  }
  if (token.size() == 1 && first.isDigit())
    return kVK_ANSI_0 + (first.toLatin1() - '0');
  if (token.size() >= 2 && token.front() == QLatin1Char('f')) {
    bool numberOk = false;
    const int functionKey = token.mid(1).toInt(&numberOk);
    if (numberOk && functionKey >= 1 && functionKey <= 19)
      return kVK_F1 + (functionKey - 1);
  }
  if (token == QLatin1String("space"))
    return kVK_Space;
  if (token == QLatin1String("tab"))
    return kVK_Tab;
  if (token == QLatin1String("return") || token == QLatin1String("enter"))
    return kVK_Return;
  if (token == QLatin1String("esc") || token == QLatin1String("escape"))
    return kVK_Escape;
  if (token == QLatin1String("left"))
    return kVK_LeftArrow;
  if (token == QLatin1String("right"))
    return kVK_RightArrow;
  if (token == QLatin1String("up"))
    return kVK_UpArrow;
  if (token == QLatin1String("down"))
    return kVK_DownArrow;
  ok = false;
  return 0;
}

/** Parses "cmd+shift+r" spellings: modifiers cmd/ctrl/alt(option)/shift,
 *  then one key: a-z, 0-9, f1-f19, space, tab, return, esc, or arrows. */
ParsedCombo parseCombo(const QString &combo) {
  ParsedCombo parsed;
  bool sawKey = false;
  for (QString part : combo.split('+', Qt::SkipEmptyParts)) {
    part = part.trimmed().toLower();
    UInt32 modifier = 0;
    if (part == QLatin1String("cmd") || part == QLatin1String("command"))
      modifier = cmdKey;
    else if (part == QLatin1String("ctrl") || part == QLatin1String("control"))
      modifier = controlKey;
    else if (part == QLatin1String("alt") || part == QLatin1String("option"))
      modifier = optionKey;
    else if (part == QLatin1String("shift"))
      modifier = shiftKey;
    if (modifier) {
      parsed.modifiers |= modifier;
      continue;
    }
    if (sawKey)
      return {}; // Only one non-modifier token allowed.
    bool ok = false;
    const int keyCode = keyTokenToCarbon(part, ok);
    if (!ok)
      return {};
    parsed.keyCode = static_cast<UInt32>(keyCode);
    sawKey = true;
  }
  parsed.valid = sawKey && parsed.modifiers != 0;
  return parsed;
}

EventHandlerRef handlerRef_ = 0;
EventHotKeyRef hotkeyRefs_[kHotkeyCount] = {0, 0, 0};
/** Stable UTF-8 storage: returning toUtf8() temporaries would dangle. */
QByteArray registeredCombos_[kHotkeyCount];
void (*callback_)(void *ctx, const char *mode) = 0;
void *context_ = 0;

OSStatus handleHotKeyEvent(EventHandlerCallRef nextHandler, EventRef event,
                           void *userData) {
  static_cast<void>(nextHandler);
  static_cast<void>(userData);
  if (GetEventKind(event) != kEventHotKeyPressed)
    return eventNotHandledErr;

  EventHotKeyID hotKeyId;
  if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, 0,
                        sizeof(hotKeyId), 0,
                        &hotKeyId) != noErr ||
      hotKeyId.signature != kHotkeySignature || hotKeyId.id < kHotkeyRegion ||
      hotKeyId.id > kHotkeyFullscreen)
    return eventNotHandledErr;

  if (callback_)
    callback_(context_, kSpecs[hotKeyId.id - 1].mode);
  return noErr;
}

extern "C" {

void omasnap_uninstall_hotkeys();

bool omasnap_install_hotkeys(void (*callback)(void *ctx, const char *mode),
                             void *ctx) {
  if (handlerRef_)
    return true;

  EventTypeSpec types[1];
  types[0].eventClass = kEventClassCommand;
  types[0].eventKind = kEventHotKeyPressed;
  const OSStatus status = InstallEventHandler(
      GetApplicationEventTarget(), handleHotKeyEvent, 1, types, 0, &handlerRef_);
  if (status != noErr) {
    handlerRef_ = 0;
    return false;
  }

  callback_ = callback;
  context_ = ctx;
  int registered = 0;
  for (int i = 0; i < kHotkeyCount; ++i) {
    QString combo = QString::fromLatin1(kSpecs[i].defaultCombo);
    const QString override =
        qEnvironmentVariable(kSpecs[i].envName).trimmed();
    if (!override.isEmpty())
      combo = override.toLower();

    const ParsedCombo parsed = parseCombo(combo);
    if (!parsed.valid) {
      qWarning("omasnap serve: ignoring invalid hotkey %s=%s",
               kSpecs[i].envName, qPrintable(combo));
      continue;
    }

    EventHotKeyID hotKeyId;
    hotKeyId.signature = kHotkeySignature;
    hotKeyId.id = static_cast<UInt32>(i + 1);
    if (RegisterEventHotKey(parsed.keyCode, parsed.modifiers, hotKeyId,
                            GetApplicationEventTarget(), 0,
                            &hotkeyRefs_[i]) != noErr) {
      // A single conflict (another tool owns this combo) must not take down
      // the remaining bindings.
      hotkeyRefs_[i] = 0;
      qWarning("omasnap serve: hotkey %s is already taken by another app; "
               "set %s to remap it",
               qPrintable(combo), kSpecs[i].envName);
      continue;
    }
    registeredCombos_[i] = combo.toUtf8();
    ++registered;
  }
  if (registered == 0) {
    omasnap_uninstall_hotkeys();
    return false;
  }
  return true;
}

/** Human-readable spelling of the actually-registered combos, or an empty
 *  string when index has no active binding. Call after install. */
const char *omasnap_hotkey_description(int index) {
  if (index < 0 || index >= kHotkeyCount)
    return "";
  return registeredCombos_[index].constData();
}

void omasnap_uninstall_hotkeys() {
  for (int i = 0; i < kHotkeyCount; ++i) {
    if (hotkeyRefs_[i]) {
      UnregisterEventHotKey(hotkeyRefs_[i]);
      hotkeyRefs_[i] = 0;
    }
    registeredCombos_[i].clear();
  }
  if (handlerRef_) {
    RemoveEventHandler(handlerRef_);
    handlerRef_ = 0;
  }
  callback_ = 0;
  context_ = 0;
}
}
#endif // __APPLE__
