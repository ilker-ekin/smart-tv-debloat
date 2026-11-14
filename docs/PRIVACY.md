# Privacy check: microphone, listening, tracking

The privacy audit is **read-only**: it only reads settings and lists, and changes nothing on the TV. Run it before
and after debloating.

| You use | Command | Report |
|---|---|---|
| Windows cmd | `scripts\privacy-audit.bat 192.168.1.50:5555` | `privacy-report.txt` |
| Windows PowerShell | `powershell -ExecutionPolicy Bypass -File scripts\privacy-audit.ps1 192.168.1.50` | `reports\<time>-privacy.txt` |
| macOS / Linux | `./scripts/privacy-audit.sh 192.168.1.50` | `reports/<time>-privacy.txt` |
| From the debloat script | `tv-debloat.ps1 192.168.1.50 -Privacy` / `tv-debloat.sh 192.168.1.50 --privacy` | same as above |

All three print the same 11 sections. The PowerShell and bash versions also put a **Findings** summary on top:

```
OK     microphone     com.google.android.katniss (voice search, allow): last used 225 days, 21 hours ago
INFO   recording now  check section 3 by hand: with nobody holding the mic button it should list no active recording
OK     accessibility  no accessibility services enabled
OK     location       location is off
INFO   users          2 Android users on this TV; apps removed for one user stay for the others
WARN   debugging      ADB is on (needed for this audit). Turn it OFF when you are done: anyone on your Wi-Fi gets full control
```

`REVIEW` lines are worth a closer look. `OK` and `INFO` aren't problems.

> [!WARNING]
> The report describes your TV and the apps on it. Don't post it publicly. `reports/` and `privacy-report.txt`
> are git-ignored in this repo.

## What ADB can and can't tell you

| Question | Can ADB answer it? |
|---|---|
| Which apps are **allowed** to use the mic | ✅ Section 1 |
| Which apps **actually used** the mic, and when | ✅ Section 2 (app-op access history) |
| Is something recording **right now** | ✅ Section 3 (read it yourself; the scripts don't interpret it yet) |
| Is a hotword / "always listening" assistant set | ✅ Section 4 |
| Is the **remote's mic hardware** physically live | ❌ No. The remote talks Bluetooth; ADB only sees audio once Android receives it. TCL remotes with a mic button are **push-to-talk**: the mic streams only while you hold the button. |
| Does the TV send **viewing data** (ACR) | ⚠️ Only partly. Turn off the privacy toggles [below](#on-tv-privacy-settings-no-adb-needed). Proof at network level needs router or Pi-hole logs. |

## Reading the timestamps

Section 2 has lines like this:

```
Package com.google.android.katniss:
  RECORD_AUDIO (allow):
    Access: [fg-s] 2026-01-01 00:00:00.000 (-225d21h26m3s120ms) duration=+4s210ms
```

In plain words:

- `(-225d21h26m3s120ms)` = **225 days, 21 hours, 26 minutes ago**. The minus sign means "in the past".
- It's the **last** time this app opened the microphone, one entry per state (`fg` = app in the foreground,
  `bg` = background). It is **not** a recording, and not a list of every use.
- `duration=+4s210ms` = the mic was open for **4.2 seconds** that time: a voice search.
- `[fg-s]` = foreground, while you used the app. A `bg` entry for an app you didn't use for voice deserves a look.

## Reading the report

**1–2. Microphone.** Expect only voice components: `com.google.android.katniss`, `com.google.android.tv.assistant`,
`com.tcl.assistant`, `com.tcl.micmanager`, and maybe YouTube for voice search. Anything else with mic access,
especially an app you never use for voice, is a red flag: the scripts mark it `REVIEW`.

**3. Recording now.** With nobody pressing the mic button, this should show no active recording.
`TODO(device)`: capture this section's real output on the G07 so the scripts can check it automatically.

**4. Assistant / hotword.** Shows the system assistant. If you don't use voice at all, remove the assistant
([below](#locking-it-down)). The remote's mic button then does nothing.

**5–7. Accessibility, notification listeners, device admins.** On a stock TV these should be **empty or `null`**,
apart from things you turned on yourself. (Projectivy's launcher override, for example, appears as an accessibility
service. That one is expected.) Anything unknown here can read the screen or control the device.

**8–9. Third-party apps and unknown sources.** You should recognise every app listed. Installer
`com.android.vending` = Play Store. `null` = sideloaded or preinstalled.

**10. Location.** A TV doesn't need it. `0` = off.

**11. Debugging.** `1` = on. Turn it **off** when you're done: open ADB means full control for anyone on your Wi-Fi.

## Locking it down

Revoke the mic from one app (reversible). `%T%` is the TV address from the walkthrough:

```cmd
adb -s %T% shell pm revoke <package> android.permission.RECORD_AUDIO
```

```cmd
adb -s %T% shell appops set <package> RECORD_AUDIO ignore
```

Undo:

```cmd
adb -s %T% shell appops set <package> RECORD_AUDIO default
```

```cmd
adb -s %T% shell pm grant <package> android.permission.RECORD_AUDIO
```

`pm revoke` fails on some system apps. The `appops ... ignore` line still blocks them.

No voice at all (frees RAM too):

```cmd
adb -s %T% shell "pm uninstall -k --user 0 com.google.android.katniss; pm uninstall -k --user 0 com.google.android.tv.assistant; pm uninstall -k --user 0 com.tcl.assistant"
```

The debloat already removes `com.tcl.smartalexa` (Alexa).

## On-TV privacy settings (no ADB needed)

Turn these off in **Settings**. Names vary by firmware:

- **Settings → Privacy → Usage & Diagnostics** → off
- **Settings → Privacy → Ads** → *Opt out of ads personalization* / delete the advertising ID
- **Settings → Privacy → Location** → off
- **Settings → Privacy → Microphone** (if present) → off for apps you don't use voice in
- **TCL privacy / Terms → "Viewing Information Services" / "Smart TV experience"** (if present) → off. This is the
  ACR (what-you-watch) tracking.
- **Settings → Privacy → Google Assistant** → turn off *Personal results* if you keep the Assistant

## Results on the reference TV

**TCL G07_4K_GB_NF · Android TV 11 · RP1A.200622.001/AR17**, audited with `privacy-audit.bat`:

- Only **Google Assistant** (`com.google.android.katniss`) has microphone permission.
- Its last microphone use was **225 days** before the audit.
- **Nothing** was recording at the time of the audit.
- **No** accessibility services, **no** device admins, **no** apps allowed to install other apps.
- Location is **off**.
- The TV has **two** Android users (0 and 10).
