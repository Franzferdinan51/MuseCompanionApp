# iOS Permissions Audit — MuseCompanionApp

## Branch: `ios`
**Date:** 2026-10-03
**Status:** Info.plist updated, SMS gracefully degraded, simulator-tested

---

## Permission Mapping: Android → iOS

| Android Permission | iOS Equivalent | Status | Notes |
|---|---|---|---|
| `BLUETOOTH_ADVERTISE` | `NSBluetoothAlwaysUsageDescription` | ✅ Added | Required for BLE pairing |
| `BLUETOOTH_CONNECT` | `NSBluetoothAlwaysUsageDescription` | ✅ Added | Same key covers both |
| `BLUETOOTH` / `BLUETOOTH_ADMIN` | (covered above) | ✅ | Legacy, no separate iOS key |
| `INTERNET` | — | ✅ N/A | No iOS permission needed |
| `ACCESS_NETWORK_STATE` | — | ✅ N/A | No iOS permission needed |
| `FOREGROUND_SERVICE` | `UIBackgroundModes` | ✅ Added | `bluetooth-peripheral`, `bluetooth-central`, `audio` |
| `FOREGROUND_SERVICE_CONNECTED_DEVICE` | (covered above) | ✅ | Same background modes |
| `POST_NOTIFICATIONS` | — | ✅ N/A | Requested at runtime, no plist key |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | — | ⚠️ No equivalent | iOS manages this automatically; background modes help |
| `RECORD_AUDIO` | `NSMicrophoneUsageDescription` | ✅ Added | Hold-to-talk voice messages |
| `CAMERA` | `NSCameraUsageDescription` | ✅ Added | "Show the camera" feature |
| `FLASHLIGHT` | — | ✅ N/A | Part of camera on iOS |
| `MODIFY_AUDIO_SETTINGS` | — | ✅ N/A | Handled via AVAudioSession, no permission |
| `ACCESS_COARSE_LOCATION` / `ACCESS_FINE_LOCATION` | `NSLocationWhenInUseUsageDescription` | ✅ Added | Contextual assistance |
| `READ_CONTACTS` | `NSContactsUsageDescription` | ✅ Added | Message by name |
| `READ_CALENDAR` | `NSCalendarsUsageDescription` | ✅ Added | Scheduling help |
| `READ_SMS` / `SEND_SMS` | — | ❌ **BLOCKED** | **iOS does not allow SMS access. Ever.** See below. |
| `CALL_PHONE` | — | ✅ N/A | iOS uses `tel:` URLs, no permission needed |
| `SET_ALARM` | — | ⚠️ No equivalent | No iOS API for setting alarms |
| `VIBRATE` | — | ✅ N/A | No permission needed |
| `WAKE_LOCK` | — | ⚠️ No equivalent | Use `UIApplication.shared.isIdleTimerDisabled` |
| `ACCESS_WIFI_STATE` | — | ✅ N/A | No permission needed |
| `ACCESS_NOTIFICATION_POLICY` | — | ⚠️ No equivalent | iOS handles Do Not Disturb |
| `WRITE_SETTINGS` | — | ⚠️ No equivalent | iOS sandboxes all settings |

---

## Critical iOS Limitations

### 1. SMS — HARD BLOCKED ❌
**Android:** App can read SMS (`READ_SMS`) and send SMS (`SEND_SMS`).
**iOS:** Apple provides **zero** API for reading or sending SMS. This is a platform policy, not a technical limitation.

**Compensation:**
- `phone_bridge.dart`: Throws clear `PhoneActionException` on iOS explaining the limitation
- `settings_screen.dart`: SMS permission button hidden on iOS (`Platform.isIOS` check)
- **User workaround:** Use iMessage sharing via `UIActivityViewController` (manual, not programmatic)

### 2. Background BLE — RESTRICTED ⚠️
**Android:** Foreground service keeps BLE alive indefinitely.
**iOS:** Background modes help but iOS is aggressive:
- BLE peripheral mode works in background but with reduced frequency
- iOS may suspend the app; must use state restoration
- Background audio mode helps keep the app alive longer

**Mitigation:** Added `bluetooth-peripheral`, `bluetooth-central`, `audio` to `UIBackgroundModes`.

### 3. Battery Optimizations — NO EQUIVALENT ⚠️
**Android:** Can request exemption from Doze.
**iOS:** No API. iOS decides. Background modes are the only lever.

### 4. Phone Calls — DIFFERENT MODEL ✅
**Android:** `CALL_PHONE` permission, direct dial.
**iOS:** No permission needed. Use `tel:` URL scheme which prompts the user. This is actually *better* UX — user confirms each call.

---

## Files Changed (ios branch)

1. **`app/ios/Runner/Info.plist`**
   - Added 8 privacy usage descriptions (Bluetooth, Mic, Camera, Contacts, Calendars, Location, Speech)
   - Added `UIBackgroundModes`: bluetooth-peripheral, bluetooth-central, audio

2. **`app/ios/Podfile`**
   - Bumped platform from iOS 13.0 → 15.0
   - Added `post_install` hook forcing all Pods to 15.0 deployment target

3. **`app/ios/Runner.xcodeproj/project.pbxproj`**
   - Bumped `IPHONEOS_DEPLOYMENT_TARGET` 13.0 → 15.0

4. **`app/lib/app/phone_bridge.dart`**
   - Added `dart:io` import
   - iOS guard for SMS: throws descriptive error instead of cryptic failure

5. **`app/lib/ui/settings_screen.dart`**
   - SMS permission button hidden on iOS

---

## Testing
- ✅ Built for iOS Simulator (iPhone 16, iOS 26.5)
- ✅ App launches, shows generic avatar, status READY
- ✅ No crashes on permission-related code paths
- ⏳ Physical device testing needed for: BLE pairing, camera, microphone, background modes

---

## Future Work (iOS branch)
- [ ] Test BLE pairing on physical iPhone
- [ ] Verify background BLE stays connected
- [ ] Test camera/microphone permission flows
- [ ] Consider CallKit for better phone integration
- [ ] Evaluate PushKit for background wake
