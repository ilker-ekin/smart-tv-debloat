## What changed

<!-- One or two lines. -->

## Checklist

CI covers the scripts against a simulated TV. These need a human:

- [ ] **`packages.yaml` changed** (new package, lower risk, new `verified_on`, or denylist change): I tested it on a
      real TV. Model (`ro.product.name`) and firmware: <!-- e.g. G07_4K_GB_NF, RP1A.200622.001/AR17 -->
- [ ] I ran `python tools/packages.py gen` after editing `packages.yaml`
- [ ] **Walkthrough commands changed:** I ran them in Windows `cmd`, one line at a time
- [ ] **Script changed:** the same change and a test exist for both PowerShell and bash
- [ ] No personal data (IPs other than `192.168.1.50`, serials, account info) in code, docs, fixtures or screenshots
- [ ] My contribution is my own work and I agree to license it under the [MIT License](../LICENSE)

Not applicable? Tick it anyway or delete the line.
