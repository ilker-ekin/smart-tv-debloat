#!/usr/bin/env python3
"""Validate packages.yaml and generate packages.tsv from it.

    python tools/packages.py check   # validate YAML, denylist, TSV sync, script denylists
    python tools/packages.py gen     # (re)write packages.tsv

Why a TSV at all: the bash script must run on stock macOS (bash 3.2) and Git Bash
without extra tools, and there is no YAML parser there without `yq`/python. A
tab-separated file is trivially read with `while IFS=$'\\t' read -r ...`.
packages.yaml stays the single source of truth; CI runs `check`, which fails if
the committed TSV differs from a fresh render.

Why custom checks instead of JSON Schema only: the rules that matter most
(no denylisted package in `packages`, TSV in sync, script denylists in sync)
are cross-file and need code anyway. This keeps it to one dependency: PyYAML.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: python -m pip install pyyaml")

ROOT = Path(__file__).resolve().parent.parent
YAML_PATH = ROOT / "packages.yaml"
TSV_PATH = ROOT / "packages.tsv"
# Scripts embed a copy of the denylist between these markers (enforced in code).
SCRIPTS = [ROOT / "scripts" / "tv-debloat.ps1", ROOT / "scripts" / "tv-debloat.sh"]
DENY_BEGIN = "BEGIN DENYLIST"
DENY_END = "END DENYLIST"

PKG_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$")
RISKS = {"safe", "caution", "breaks-feature"}
FIELDS = ["package", "name", "description", "tier", "risk", "breaks", "verified_on"]
TSV_COLUMNS = ["kind", "package", "tier", "risk", "name", "breaks", "verified_on", "description"]


def load() -> dict:
    try:
        with YAML_PATH.open(encoding="utf-8") as fh:
            return yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        sys.exit(f"ERROR: {YAML_PATH.name} is not valid YAML:\n{exc}")


def validate(data: dict) -> list[str]:
    errs: list[str] = []
    if not isinstance(data, dict):
        return ["top level must be a mapping"]
    for key in ("schema_version", "devices", "packages", "denylist"):
        if key not in data:
            errs.append(f"missing top-level key: {key}")
    if errs:
        return errs
    if data["schema_version"] != 1:
        errs.append(f"unsupported schema_version: {data['schema_version']}")

    device_ids = set()
    for i, dev in enumerate(data["devices"] or []):
        for k in ("id", "platform", "build", "ram"):
            if not isinstance(dev, dict) or not dev.get(k):
                errs.append(f"devices[{i}]: missing {k}")
        if isinstance(dev, dict) and dev.get("id"):
            if dev["id"] in device_ids:
                errs.append(f"devices[{i}]: duplicate id {dev['id']}")
            device_ids.add(dev["id"])

    deny = data["denylist"] or []
    deny_set = set()
    for d in deny:
        if not isinstance(d, str) or not PKG_RE.match(d):
            errs.append(f"denylist: invalid package name {d!r}")
        elif d in deny_set:
            errs.append(f"denylist: duplicate {d}")
        deny_set.add(d)

    seen = set()
    for i, p in enumerate(data["packages"] or []):
        where = f"packages[{i}]"
        if not isinstance(p, dict):
            errs.append(f"{where}: must be a mapping")
            continue
        where = f"packages[{i}] ({p.get('package', '?')})"
        missing = [f for f in FIELDS if f not in p]
        extra = [f for f in p if f not in FIELDS]
        if missing:
            errs.append(f"{where}: missing fields {missing}")
        if extra:
            errs.append(f"{where}: unknown fields {extra}")
        if missing:
            continue
        pkg = p["package"]
        if not isinstance(pkg, str) or not PKG_RE.match(pkg):
            errs.append(f"{where}: invalid package name")
        if pkg in seen:
            errs.append(f"{where}: duplicate package")
        seen.add(pkg)
        if pkg in deny_set:
            errs.append(f"{where}: is on the DENYLIST and must not be offered for removal")
        if p["tier"] not in (1, 2, 3) or isinstance(p["tier"], bool):
            errs.append(f"{where}: tier must be 1, 2 or 3")
        if p["risk"] not in RISKS:
            errs.append(f"{where}: risk must be one of {sorted(RISKS)}")
        for f in ("name", "description", "breaks"):
            v = p[f]
            if not isinstance(v, str):
                errs.append(f"{where}: {f} must be a string")
            elif re.search(r"[\t\r\n]", v):
                errs.append(f"{where}: {f} must not contain tabs or newlines (TSV)")
        if not p["name"]:
            errs.append(f"{where}: name must not be empty")
        if not isinstance(p["verified_on"], list):
            errs.append(f"{where}: verified_on must be a list")
        else:
            for dev in p["verified_on"]:
                if dev not in device_ids:
                    errs.append(f"{where}: verified_on references unknown device {dev!r}")
        if p["risk"] == "breaks-feature" and not p["breaks"]:
            errs.append(f"{where}: risk breaks-feature needs a 'breaks' description")
    return errs


def render_tsv(data: dict) -> str:
    lines = [
        "# GENERATED from packages.yaml by `python tools/packages.py gen`. Do not edit by hand.",
        "\t".join(TSV_COLUMNS),
    ]
    for p in data["packages"]:
        lines.append("\t".join([
            "pkg", p["package"], str(p["tier"]), p["risk"], p["name"], p["breaks"],
            ",".join(p["verified_on"]), p["description"],
        ]))
    for d in data["denylist"]:
        lines.append("\t".join(["deny", d, "", "", "", "", "", ""]))
    return "\n".join(lines) + "\n"


def script_denylist(path: Path) -> list[str] | None:
    """Package names between the BEGIN/END DENYLIST markers, or None if absent."""
    text = path.read_text(encoding="utf-8")
    if DENY_BEGIN not in text:
        return None
    block = text.split(DENY_BEGIN, 1)[1].split(DENY_END, 1)[0]
    return sorted(set(re.findall(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+", block)))


def check(data: dict) -> list[str]:
    errs = validate(data)
    if errs:
        return errs
    if not TSV_PATH.exists():
        errs.append("packages.tsv missing; run: python tools/packages.py gen")
    elif TSV_PATH.read_bytes().decode("utf-8") != render_tsv(data):
        errs.append("packages.tsv is out of date (or has CRLF); run: python tools/packages.py gen")
    want = sorted(set(data["denylist"]))
    for s in SCRIPTS:
        if not s.exists():
            continue  # script not written yet
        got = script_denylist(s)
        rel = s.relative_to(ROOT)
        if got is None:
            errs.append(f"{rel}: no '{DENY_BEGIN}' / '{DENY_END}' block")
        elif got != want:
            errs.append(f"{rel}: hardcoded denylist differs from packages.yaml "
                        f"(missing {sorted(set(want) - set(got))}, extra {sorted(set(got) - set(want))})")
    return errs


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "check"
    data = load()
    if cmd == "gen":
        errs = validate(data)
        if errs:
            print("\n".join(f"ERROR: {e}" for e in errs), file=sys.stderr)
            return 1
        TSV_PATH.write_bytes(render_tsv(data).encode("utf-8"))  # bytes: force LF on Windows
        print(f"wrote {TSV_PATH.name}: {len(data['packages'])} packages, {len(data['denylist'])} denylisted")
        return 0
    if cmd == "check":
        errs = check(data)
        if errs:
            print("\n".join(f"ERROR: {e}" for e in errs), file=sys.stderr)
            return 1
        print(f"OK: {len(data['packages'])} packages, {len(data['denylist'])} denylisted, TSV in sync")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
