# Samsung, LG and other brands

This project removes preinstalled apps with **ADB** (`pm uninstall --user`). That only exists on **Android TV /
Google TV**.

| Brand / OS | ADB debloat? | What you can do |
|---|---|---|
| **TCL** (Android TV / Google TV) | ✅ Yes, the verified reference brand | The [walkthrough](WALKTHROUGH.md) or the scripts |
| **Sony, Philips, Hisense (Google TV models), Xiaomi** and other Android TVs | ⚠️ Same method, different app list | The steps are identical, but [`packages.yaml`](../packages.yaml) lists TCL packages. Run `--list` / `--dry-run` first and only remove what you recognise. Please [report your model](../CONTRIBUTING.md#report-a-model). |
| **Samsung** (Tizen) | ❌ No | [Privacy settings](#samsung-tizen) |
| **LG** (webOS) | ❌ No | [Privacy settings](#lg-webos) |

## Why there's no Samsung or LG debloat

Samsung's **Tizen** and LG's **webOS** have no ADB and no package manager you can reach. Their *Developer Mode*
only lets you install your own apps. Removing built-in apps there requires exploiting the firmware (rooting). This
project doesn't do that: it would void the "no root, nothing that can't be undone" promise, and a firmware update
can brick a rooted TV.

What **does** work on every brand is turning off the tracking, so the rest of this page covers that.

## Samsung (Tizen)

Look for these in **Settings** (most are under **Settings → Support → Terms & Privacy** or **Settings → General →
Terms & Privacy**). Names and places change by model year:

- **Viewing Information Services** → off. This is ACR: the TV identifies what's on screen, from any input.
- **Interest-Based Advertisement** → off, and reset the advertising ID if offered.
- **Voice Recognition Services** / Bixby → off if you don't use voice.
- **Diagnostics / Smart Hub terms** → decline the optional ones.

`TODO(device)`: verify these menu paths on a real Samsung TV and note the model year.

## LG (webOS)

Look for these in **Settings → All Settings → General** (often under **System → Additional Settings** or
**User Agreements**). Names vary by webOS version:

- **Live Plus** → off. This is LG's ACR.
- **User Agreements** → turn off the optional ones: *Viewing Information*, *Voice Information*, *Interest-Based
  Recommendation*.
- **Ad tracking / "Limit Ad Tracking"** → on (limits tracking).

`TODO(device)`: verify these menu paths on a real LG TV and note the webOS version.

## Any brand: block it on the network

TV settings depend on the vendor keeping its word. To actually stop the traffic, block tracking domains at the
network level: a **Pi-hole** or a router that supports DNS blocklists. Look at what the TV contacts in the logs
before you block anything, because blocking the wrong domain can break streaming apps or updates.
