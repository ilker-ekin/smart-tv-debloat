@echo off
REM Read-only privacy audit for Android TV / Google TV over ADB (verified on TCL). Changes NOTHING on the TV.
REM Usage:  privacy-audit.bat 192.168.1.50:5555
REM Output: privacy-report.txt (also printed to the screen)
REM See docs\PRIVACY.md for what each section means and how to act on it.

setlocal
if "%~1"=="" (
  echo Usage: %~nx0 ^<TV_IP:PORT^>   e.g. %~nx0 192.168.1.50:5555
  exit /b 1
)
set T=%~1
set R=privacy-report.txt

adb connect %T% >nul
adb -s %T% get-state >nul 2>&1 || (echo Not connected/authorized. Accept the prompt on the TV and retry. & exit /b 1)

> %R% echo Android TV privacy audit  %DATE% %TIME%
>>%R% echo Device:
adb -s %T% shell getprop ro.product.name >>%R%
adb -s %T% shell getprop ro.build.fingerprint >>%R%

>>%R% echo.
>>%R% echo ===== 1. Apps ALLOWED to use the microphone (RECORD_AUDIO app-op) =====
adb -s %T% shell cmd appops query-op RECORD_AUDIO allow >>%R% 2>&1
>>%R% echo --- foreground-only ---
adb -s %T% shell cmd appops query-op RECORD_AUDIO foreground >>%R% 2>&1

>>%R% echo.
>>%R% echo ===== 2. Recent microphone ACCESS history (who actually used it, and when) =====
adb -s %T% shell "dumpsys appops --op RECORD_AUDIO | grep -E 'Package|Access|Reject|Running'" >>%R% 2>&1

>>%R% echo.
>>%R% echo ===== 3. Is anything recording RIGHT NOW? =====
adb -s %T% shell "dumpsys audio | grep -A8 'RecordActivityMonitor'" >>%R% 2>&1

>>%R% echo.
>>%R% echo ===== 4. Voice assistant / hotword services =====
>>%R% echo assistant:
adb -s %T% shell settings get secure assistant >>%R%
>>%R% echo voice_interaction_service:
adb -s %T% shell settings get secure voice_interaction_service >>%R%
>>%R% echo voice_recognition_service:
adb -s %T% shell settings get secure voice_recognition_service >>%R%
>>%R% echo hotword / always-on packages installed:
adb -s %T% shell "pm list packages | grep -iE 'hotword|alexa|katniss|assistant|micmanager|voice'" >>%R%

>>%R% echo.
>>%R% echo ===== 5. Accessibility services (can read the screen; a classic spyware vector) =====
adb -s %T% shell settings get secure enabled_accessibility_services >>%R%

>>%R% echo.
>>%R% echo ===== 6. Notification listeners =====
adb -s %T% shell settings get secure enabled_notification_listeners >>%R%

>>%R% echo.
>>%R% echo ===== 7. Device admins / device owner =====
adb -s %T% shell "dumpsys device_policy | grep -iE 'admin|owner'" >>%R% 2>&1

>>%R% echo.
>>%R% echo ===== 8. User-installed (third-party) apps and who installed them =====
adb -s %T% shell pm list packages -3 -i >>%R%

>>%R% echo.
>>%R% echo ===== 9. Apps allowed to install other apps (unknown sources) =====
adb -s %T% shell cmd appops query-op REQUEST_INSTALL_PACKAGES allow >>%R% 2>&1

>>%R% echo.
>>%R% echo ===== 10. Location =====
adb -s %T% shell settings get secure location_mode >>%R%
adb -s %T% shell cmd appops query-op COARSE_LOCATION allow >>%R% 2>&1

>>%R% echo.
>>%R% echo ===== 11. Debugging left on? (turn OFF when done) =====
>>%R% echo adb_enabled:
adb -s %T% shell settings get global adb_enabled >>%R%
>>%R% echo adb_wifi_enabled:
adb -s %T% shell settings get global adb_wifi_enabled >>%R%

type %R%
echo.
echo Saved to %R%. Nothing on the TV was changed.
endlocal
