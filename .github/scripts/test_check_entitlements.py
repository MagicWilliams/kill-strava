"""The entitlements gate added with #103. Changing how CI signs is exactly the kind of
change that can produce an uploadable build with no HealthKit, and nothing downstream of
the upload would notice until David opened an empty app.

Run: python3 -m unittest discover -s .github/scripts -v
"""

from __future__ import annotations

import contextlib
import io
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

import check_entitlements as ce

GROUP = ce.APP_GROUP
GOOD_APP = {"com.apple.developer.healthkit": True,
            "com.apple.security.application-groups": [GROUP],
            "application-identifier": "2P8QGJVNJ7.studio.delight.tempo"}
GOOD_WIDGET = {"com.apple.security.application-groups": [GROUP]}


class Check(unittest.TestCase):
    def test_passes_when_both_bundles_kept_their_capabilities(self):
        self.assertEqual(ce.check({"studio.delight.tempo": GOOD_APP,
                                   "studio.delight.tempo.widgets": GOOD_WIDGET}), [])

    def test_fails_when_healthkit_was_stripped(self):
        app = {k: v for k, v in GOOD_APP.items() if k != "com.apple.developer.healthkit"}
        problems = ce.check({"studio.delight.tempo": app,
                             "studio.delight.tempo.widgets": GOOD_WIDGET})
        self.assertEqual(len(problems), 1)
        self.assertIn("com.apple.developer.healthkit", problems[0])

    def test_healthkit_false_is_not_healthkit(self):
        app = dict(GOOD_APP, **{"com.apple.developer.healthkit": False})
        self.assertTrue(ce.check({"studio.delight.tempo": app,
                                  "studio.delight.tempo.widgets": GOOD_WIDGET}))

    def test_fails_when_the_widget_lost_the_app_group(self):
        # The group is the only channel between app and widgets (#76): without it the
        # widgets render placeholders forever.
        problems = ce.check({"studio.delight.tempo": GOOD_APP,
                             "studio.delight.tempo.widgets": {
                                 "com.apple.security.application-groups": []}})
        self.assertEqual(len(problems), 1)
        self.assertIn("studio.delight.tempo.widgets", problems[0])

    def test_fails_when_the_widget_extension_is_missing_entirely(self):
        problems = ce.check({"studio.delight.tempo": GOOD_APP})
        self.assertEqual(problems, ["studio.delight.tempo.widgets: bundle not found in the IPA"])


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("codesign"), "needs macOS codesign")
class EndToEndOnARealSignature(unittest.TestCase):
    """Builds a two-bundle IPA, ad-hoc signs it with real entitlements, and runs the
    script exactly as the workflow does. Proves the codesign/plist plumbing, not just the
    comparison."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.dir)

    def bundle(self, path, bundle_id, exe, entitlements):
        os.makedirs(path)
        with open(os.path.join(path, "Info.plist"), "wb") as f:
            plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": exe,
                           "CFBundlePackageType": "APPL"}, f)
        shutil.copy("/usr/bin/true", os.path.join(path, exe))
        ents = os.path.join(self.dir, f"{exe}.entitlements")
        with open(ents, "wb") as f:
            plistlib.dump(entitlements, f)
        return ents

    def make_ipa(self, app_ents, widget_ents):
        root = os.path.join(self.dir, "root")
        app = os.path.join(root, "Payload", "Tempo.app")
        app_e = self.bundle(app, "studio.delight.tempo", "Tempo", app_ents)
        ext = os.path.join(app, "PlugIns", "TempoWidgets.appex")
        ext_e = self.bundle(ext, "studio.delight.tempo.widgets", "TempoWidgets", widget_ents)
        for path, ents in ((ext, ext_e), (app, app_e)):  # inside-out, as Xcode does
            subprocess.run(["codesign", "--force", "-s", "-", "--entitlements", ents, path],
                           check=True, capture_output=True)
        ipa = os.path.join(self.dir, "Tempo.ipa")
        with zipfile.ZipFile(ipa, "w") as z:
            for dirpath, _, files in os.walk(root):
                for name in files:
                    full = os.path.join(dirpath, name)
                    z.write(full, os.path.relpath(full, root))
        return ipa

    def run_script(self, ipa):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = ce.main([ipa])
        return code, out.getvalue()

    def test_good_ipa_passes(self):
        code, out = self.run_script(self.make_ipa(GOOD_APP, GOOD_WIDGET))
        self.assertEqual(code, 0, out)
        self.assertIn("com.apple.developer.healthkit = True", out)

    def test_ipa_without_healthkit_fails_the_run(self):
        app = {"com.apple.security.application-groups": [GROUP]}
        code, out = self.run_script(self.make_ipa(app, GOOD_WIDGET))
        self.assertEqual(code, 1)
        self.assertIn("::error::Entitlements check failed: studio.delight.tempo: "
                      "com.apple.developer.healthkit", out)


if __name__ == "__main__":
    unittest.main()
