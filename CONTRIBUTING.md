# Contributing

The most useful contribution is a **report from a TV model we haven't seen yet**: what you removed, what broke,
and before/after numbers. Code and docs fixes are welcome too.

> [!IMPORTANT]
> Never post personal data: no IP addresses (use `192.168.1.50` in examples), no device serials (`adb devices`
> shows one for USB connections), no Google account details, and no full privacy reports. Model, firmware and
> `meminfo` numbers are fine and wanted.

## Licensing of contributions

By opening a pull request or posting content in an issue, you agree that your contribution is licensed under the
project's [MIT License](LICENSE) (inbound = outbound, as in GitHub's Terms of Service), and you confirm that:

- you wrote it yourself, or have the right to submit it under the MIT License;
- it contains no code, text or images copied from projects with incompatible licenses, and no brand logos;
- it contains no personal data (yours or anyone else's), and nothing that's under an NDA;
- it describes only methods that use official tools on devices you own: no rooting, firmware exploits or
  bypassing of any protection. Such contributions will be declined.

## Report a model

Open an issue with the **Model report** template. It asks for:

- `getprop ro.product.name` and `getprop ro.build.fingerprint` (not `ro.product.model`, which says `Smart TV` on TCL)
- Android version and RAM
- before/after `dumpsys meminfo` lines (see [RESULTS.md](docs/RESULTS.md#how-to-measure))
- which packages you removed, and anything that stopped working

## Verify a package on a new model

`verified_on` in [`packages.yaml`](packages.yaml) means: *removed on that TV, and the TV kept working*. Please only
add a device after doing this:

1. **Baseline.** Save the package list and meminfo (walkthrough [step 4](docs/WALKTHROUGH.md#step-4-baseline), or
   `--measure before`).
2. **Remove one package at a time** (or a small, related group) for the current user:
   `adb -s <tv> shell pm uninstall -k --user <id> <package>`
3. **Reboot**, then test the basics:
   - [ ] Home button → home screen appears
   - [ ] Input / source switching, Live TV (if you use it)
   - [ ] Remote: navigation, volume, mic button (if not removing voice)
   - [ ] Your streaming apps open and play
   - [ ] Settings opens; Chromecast still works (if you use it)
4. **Wait a day of normal use.** Some breakage only shows up on the next boot or update check.
5. If anything broke: `install-existing` it back, and set `risk: breaks-feature` with a `breaks:` description
   (or propose it for the **denylist** if it breaks something essential).

Then edit `packages.yaml`:

```yaml
devices:
  - id: YOUR_RO_PRODUCT_NAME          # e.g. G07_4K_GB_NF
    platform: Android TV 11
    build: RP1A.200622.001/AR17       # build id from the fingerprint, not the whole fingerprint
    ram: 2 GB
packages:
  - package: com.tcl.guard
    ...
    verified_on: [G07_4K_GB_NF, YOUR_RO_PRODUCT_NAME]
```

and regenerate the bash-readable copy:

```sh
python tools/packages.py gen
```

```sh
python tools/packages.py check
```

**Rules that CI enforces:**

- Nothing on the `denylist` may appear under `packages`. The scripts refuse denylisted packages in code too.
- `packages.tsv` must match `packages.yaml` exactly (always run `gen`).
- Both scripts carry a copy of the denylist between `BEGIN DENYLIST` / `END DENYLIST`. If you change the denylist
  in the YAML, update both scripts. `check` tells you what's missing.
- Unconfirmed behaviour is written as `TODO(device)`, never stated as fact. Unmeasured numbers may be given as
  `≈ value *(estimate)*`, never as a bare number.

## Development

Requirements: Python 3 with PyYAML, PowerShell (5.1 or 7) with **Pester 5+** and **PSScriptAnalyzer**, bash, and
**shellcheck**.

```sh
python -m pip install pyyaml shellcheck-py
```

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
```

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
```

**Run everything** (none of it talks to a real TV: the tests put a mock `adb` from `tests/mock-adb/` first on
PATH):

```sh
python tools/packages.py check
```

```sh
python -m unittest discover -s tests -p "test_*.py"
```

```sh
bash tests/test_debloat.sh
```

```powershell
Invoke-Pester tests/tv-debloat.Tests.ps1 -Output Detailed
```

```sh
shellcheck scripts/*.sh tests/mock-adb/adb tests/test_debloat.sh
```

```powershell
Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

**What CI checks, and what it can't.** On every push and pull request, GitHub Actions runs the package-list
check, the Python tests, shellcheck, the bash tests on Linux and on macOS (bash 3.2), and the Pester tests on
Windows PowerShell 5.1. All of them use the mock `adb`, so a green CI means *the scripts behave as designed*. It
does **not** mean an app is safe to remove on a real TV, that the hand-typed `cmd` commands in the walkthrough
work, or that the images match the docs. Those need a human:

- A change that adds a package, lowers its risk, or adds a device to `verified_on` must be **tested on a real TV**
  (see [Verify a package](#verify-a-package-on-a-new-model)), and the pull request must say on which model.
- A change to a walkthrough command must be **run in Windows `cmd`** once, pasted one line at a time.
- Removing something from the **denylist** needs a clear reason and a real-device test.

**Ground rules for the scripts:**

- The PowerShell and bash scripts stay at **feature parity**. A change to one needs the same change and test in
  the other.
- Every `adb` call gets an empty stdin (`$null |` / `< /dev/null`). Without it, adb swallows the user's input.
- Every change to the TV writes its undo line to the restore file. The privacy audit stays **read-only**: its tests
  fail on any non-read `adb` call.
- Test fixtures in `tests/fixtures/` say where they came from (real output or synthetic). Never add real IPs,
  serials or account data to them.

## Design assets

The README and doc images live in [`docs/assets/`](docs/assets/) (PNG @2x, with alt text and Mermaid fallbacks
listed in [`docs/assets/README.md`](docs/assets/README.md)). The PNGs in the repo are the published versions.
The source design files are kept by the maintainer. To change an image, open an issue describing the change
(e.g. new step text or a corrected number), or propose a new PNG in a pull request that follows the style and
rules in `docs/assets/README.md`.

No brand logos or assets, ever: draw TVs and remotes generically.
