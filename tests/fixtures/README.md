# Test fixtures for the mock `adb`

Canned output that `tests/mock-adb/adb(.ps1)` prints instead of talking to a TV.

| File | Source |
|---|---|
| `meminfo-before.txt` | **Real.** The baseline lines from the reference TV (TCL G07_4K_GB_NF), see `docs/RESULTS.md`. |
| `meminfo-synthetic-after.txt` | **Synthetic.** Invented numbers so the diff table can be tested. Not a measurement. |
| `users.txt` | **Shape only.** The reference TV listed user 0 and user 10; names and flags here are placeholders. |
| `packages.txt` | **Synthetic.** A mix of packages from `packages.yaml` and the denylist, to exercise the scripts. |
| `users-single.txt` | **Shape only.** A one-user TV, for the no-warning case. |
| `settings-reference.txt` | **Real values** from the reference TV's audit (no accessibility services, location off); `adb_enabled=1` is implied by the connection. |
| `settings-flagged.txt` | **Synthetic.** Red flags (accessibility service, notification listener, location on) to test the findings. |
| `appops-record-audio-flagged.txt` | **Synthetic.** Adds an unknown app that used the mic 2 hours ago. |
| `appops-record-audio.txt` | **Real format.** Shape of `dumpsys appops --op RECORD_AUDIO` with the `-225d…` relative timestamp seen on the reference TV. |

Fixtures are stored with LF line endings. The mock adds `\r` to every line when `MOCK_ADB_CRLF=1`,
which is how CRLF handling is tested.
