#!/usr/bin/env python3
"""Fail the TestFlight run if the exported IPA lost an entitlement the app can't live without.

Signing can succeed and still strip capabilities: an App ID missing a capability, a
profile that predates it, or a signing-path change (#103 weighed archiving unsigned) all
produce a perfectly uploadable build that silently has no HealthKit, which for this app
is worse than no build at all. So the exported, distribution-signed IPA is opened and
each bundle's *signed* entitlements are read back with `codesign` before upload.

    check_entitlements.py path/to/Tempo.ipa

The requirements mirror `entitlements.properties` in ios/project.yml. Keep them in step:
adding a capability there without adding it here means it ships unguarded.
"""

from __future__ import annotations

import glob
import os
import plistlib
import subprocess
import sys
import tempfile
import zipfile

APP_GROUP = "group.studio.delight.tempo"

# bundle id -> entitlement -> required value. `True` must be exactly true; a list means
# every listed element must be present in the signed array.
REQUIRED: dict[str, dict[str, object]] = {
    "studio.delight.tempo": {
        "com.apple.developer.healthkit": True,
        "com.apple.security.application-groups": [APP_GROUP],
    },
    "studio.delight.tempo.widgets": {
        "com.apple.security.application-groups": [APP_GROUP],
    },
}


def missing_entitlements(entitlements: dict, required: dict[str, object]) -> list[str]:
    problems = []
    for key, want in required.items():
        have = entitlements.get(key)
        if want is True:
            if have is not True:
                problems.append(f"{key} is {have!r}, expected true")
        elif isinstance(want, list):
            if not isinstance(have, list):
                problems.append(f"{key} is {have!r}, expected an array containing {want}")
            else:
                absent = [w for w in want if w not in have]
                if absent:
                    problems.append(f"{key} lacks {absent} (has {have})")
        elif have != want:
            problems.append(f"{key} is {have!r}, expected {want!r}")
    return problems


def check(found: dict[str, dict], required: dict[str, dict] = REQUIRED) -> list[str]:
    """found: bundle id -> signed entitlements. Returns human-readable problems; empty
    means pass. A required bundle that isn't in the IPA at all is a failure too: a widget
    extension that fell out of the build would otherwise pass vacuously."""
    problems = []
    for bundle_id, req in required.items():
        if bundle_id not in found:
            problems.append(f"{bundle_id}: bundle not found in the IPA")
            continue
        problems += [f"{bundle_id}: {p}" for p in missing_entitlements(found[bundle_id], req)]
    return problems


def signed_entitlements(bundle: str) -> dict:
    """The entitlements baked into the code signature: what the device actually enforces,
    not what the .entitlements file asked for."""
    for flag in (["--entitlements", "-", "--xml"], ["--entitlements", ":-"]):
        out = subprocess.run(["codesign", "-d", *flag, bundle], capture_output=True)
        if out.returncode == 0 and out.stdout.strip():
            try:
                return plistlib.loads(out.stdout)
            except Exception:
                continue
    raise RuntimeError(f"could not read signed entitlements from {bundle}")


def bundles_in(payload_root: str) -> list[str]:
    apps = glob.glob(os.path.join(payload_root, "Payload", "*.app"))
    exts = [e for a in apps for e in glob.glob(os.path.join(a, "PlugIns", "*.appex"))]
    return apps + exts


def bundle_id(bundle: str) -> str:
    with open(os.path.join(bundle, "Info.plist"), "rb") as f:
        return plistlib.load(f)["CFBundleIdentifier"]


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: check_entitlements.py path/to/App.ipa", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(argv[0]) as z:
            z.extractall(tmp)
        found = {}
        for b in bundles_in(tmp):
            ents = signed_entitlements(b)
            found[bundle_id(b)] = ents
            print(f"{os.path.basename(b)} ({bundle_id(b)}):")
            for k in sorted(ents):
                print(f"  {k} = {ents[k]!r}")
    problems = check(found)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if problems:
        for p in problems:
            print(f"::error::Entitlements check failed: {p}")
        if summary:
            with open(summary, "a") as f:
                f.write("### Entitlements check: FAILED, not uploaded\n\n")
                f.writelines(f"- {p}\n" for p in problems)
        return 1
    print("Entitlements check passed: HealthKit and the app group survived signing.")
    if summary:
        with open(summary, "a") as f:
            f.write("### Entitlements check: passed\n\nHealthKit and the app group are in the signed IPA (app and widget extension).\n\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
