"""Tests for tools/packages.py. Run: python -m unittest discover -s tests -p "test_*.py" -v"""
import copy
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("packages_tool", ROOT / "tools" / "packages.py")
pt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pt)


def pkg(pkg_name="com.example.app", **kw):
    base = {"package": pkg_name, "name": "X", "description": "", "tier": 1, "risk": "safe",
            "breaks": "", "verified_on": []}
    base.update(kw)
    return base


BASE = {
    "schema_version": 1,
    "devices": [{"id": "DEV1", "platform": "Android TV 11", "build": "B", "ram": "2 GB"}],
    "packages": [pkg()],
    "denylist": ["com.google.android.apps.tv.launcherx"],
}


def errs_for(mutate):
    data = copy.deepcopy(BASE)
    mutate(data)
    return pt.validate(data)


class ValidateTests(unittest.TestCase):
    def test_real_file_is_valid(self):
        self.assertEqual(pt.validate(pt.load()), [])

    def test_base_fixture_is_valid(self):
        self.assertEqual(errs_for(lambda d: None), [])

    def test_denylisted_package_is_rejected(self):
        e = errs_for(lambda d: d["packages"].append(pkg("com.google.android.apps.tv.launcherx")))
        self.assertTrue(any("DENYLIST" in x for x in e), e)

    def test_duplicate_package(self):
        e = errs_for(lambda d: d["packages"].append(pkg()))
        self.assertTrue(any("duplicate package" in x for x in e), e)

    def test_bad_tier_and_risk(self):
        e = errs_for(lambda d: d["packages"].__setitem__(0, pkg(tier=4, risk="maybe")))
        self.assertTrue(any("tier" in x for x in e) and any("risk" in x for x in e), e)

    def test_bool_tier_rejected(self):
        e = errs_for(lambda d: d["packages"].__setitem__(0, pkg(tier=True)))
        self.assertTrue(any("tier" in x for x in e), e)

    def test_unknown_device(self):
        e = errs_for(lambda d: d["packages"].__setitem__(0, pkg(verified_on=["NOPE"])))
        self.assertTrue(any("unknown device" in x for x in e), e)

    def test_tab_in_field_rejected(self):
        e = errs_for(lambda d: d["packages"].__setitem__(0, pkg(name="a\tb")))
        self.assertTrue(any("tabs" in x for x in e), e)

    def test_breaks_feature_needs_text(self):
        e = errs_for(lambda d: d["packages"].__setitem__(0, pkg(risk="breaks-feature")))
        self.assertTrue(any("breaks-feature" in x for x in e), e)

    def test_missing_and_unknown_fields(self):
        def m(d):
            p = pkg()
            del p["risk"]
            p["colour"] = "red"
            d["packages"][0] = p
        e = errs_for(m)
        self.assertTrue(any("missing fields" in x for x in e) and any("unknown fields" in x for x in e), e)

    def test_invalid_package_name(self):
        e = errs_for(lambda d: d["packages"].__setitem__(0, pkg("not a package")))
        self.assertTrue(any("invalid package name" in x for x in e), e)


class TsvTests(unittest.TestCase):
    def test_render_is_lf_and_has_deny_rows(self):
        out = pt.render_tsv(BASE)
        self.assertNotIn("\r", out)
        self.assertIn("deny\tcom.google.android.apps.tv.launcherx", out)
        rows = [r for r in out.splitlines() if not r.startswith("#")]
        self.assertTrue(all(len(r.split("\t")) == len(pt.TSV_COLUMNS) for r in rows))

    def test_committed_tsv_in_sync(self):
        self.assertEqual(pt.check(pt.load()), [])

    def test_stale_tsv_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            old_tsv, old_scripts = pt.TSV_PATH, pt.SCRIPTS
            try:
                pt.TSV_PATH = Path(tmp) / "packages.tsv"
                pt.SCRIPTS = []
                pt.TSV_PATH.write_bytes(pt.render_tsv(BASE).replace("\n", "\r\n").encode())
                self.assertTrue(any("out of date" in x for x in pt.check(BASE)))
            finally:
                pt.TSV_PATH, pt.SCRIPTS = old_tsv, old_scripts

    def test_script_denylist_mismatch_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            old_tsv, old_scripts, old_root = pt.TSV_PATH, pt.SCRIPTS, pt.ROOT
            try:
                pt.ROOT = Path(tmp)
                pt.TSV_PATH = Path(tmp) / "packages.tsv"
                pt.TSV_PATH.write_bytes(pt.render_tsv(BASE).encode())
                s = Path(tmp) / "x.sh"
                s.write_text("# BEGIN DENYLIST\ncom.android.systemui\n# END DENYLIST\n", encoding="utf-8")
                pt.SCRIPTS = [s]
                e = pt.check(BASE)
                self.assertTrue(any("differs" in x for x in e), e)
            finally:
                pt.TSV_PATH, pt.SCRIPTS, pt.ROOT = old_tsv, old_scripts, old_root


if __name__ == "__main__":
    unittest.main()
