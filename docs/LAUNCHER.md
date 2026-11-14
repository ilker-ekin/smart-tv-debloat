# Cleaner home screen with Projectivy Launcher

The stock Google TV / Android TV home screen fills rows with recommendations and ads. **Projectivy Launcher** is a
third-party launcher from the Play Store that shows only the apps you pin. This step is optional and fully
reversible.

> [!CAUTION]
> **Never disable or uninstall `com.google.android.apps.tv.launcherx`** (the stock home screen) to "force" another
> launcher. Some guides suggest it, but on many TVs it breaks the Home button, input switching and the setup flow.
> It's on this repo's denylist, so the scripts refuse to touch it. Projectivy's **Override current launcher**
> option gets the same result without removing anything.

## Set it up

1. On the TV, open the **Play Store**, search **Projectivy Launcher**, and install it.
2. Open Projectivy. Pin the apps you actually use (e.g. Live TV, YouTube, Netflix) and hide the rest.
3. In Projectivy's settings, turn on **Override current launcher**. Android asks you to allow Projectivy as an
   **accessibility service**: that's how it catches the Home button. Allow it.
4. Press **Home** on the remote. You should land in Projectivy.

`TODO(device)`: confirm the exact menu path to *Override current launcher* in the current Projectivy version on
the G07, and whether the Home and Input buttons behave normally afterwards.

> [!NOTE]
> Once the override is on, the privacy audit lists Projectivy under **accessibility services**. That's expected
> because you enabled it yourself. See [PRIVACY.md](PRIVACY.md).

## Undo

1. In Projectivy's settings, turn **Override current launcher** off. Or turn off its accessibility service under
   **Settings → System → Accessibility**.
2. Optionally uninstall Projectivy from the Play Store.

The stock home screen comes back on the next Home press. Nothing else was changed.
