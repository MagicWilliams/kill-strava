"""Regressions for #103: TestFlight runs #16 and #17 (11 Oct 2026) died with "Your account
has reached the maximum number of certificates" because every run minted an Apple
Development certificate and none was ever revoked.

The cleanup that fixes it holds a DELETE against the live developer account, and David's
Mac signs with one of those certificates. So most of these tests are about what it must
NOT revoke. Run: python3 -m unittest discover -s .github/scripts -v
"""

from __future__ import annotations

import base64
import contextlib
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import asc_certs as ac

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")


def cert(id, sha1, ctype="DEVELOPMENT", name="Created via API"):
    return {"id": id, "name": name, "displayName": name, "type": ctype,
            "serialNumber": "00", "expirationDate": "2027-10-11T00:00:00.000+0000", "sha1": sha1}


DAVID_MAC = cert("MACDAVID01", "A" * 40, name="David Latimore II")
STALE_CI = cert("CISTALE016", "B" * 40)  # left behind by run #16
THIS_RUN = cert("CINEW00018", "C" * 40)


class SelectForRevocation(unittest.TestCase):
    def test_revokes_only_the_certificate_this_run_minted(self):
        revoke, left = ac.select_for_revocation(
            before=[DAVID_MAC, STALE_CI],
            after=[DAVID_MAC, STALE_CI, THIS_RUN],
            runner_sha1s={THIS_RUN["sha1"]},
        )
        self.assertEqual([c["id"] for c in revoke], ["CINEW00018"])
        self.assertEqual(left, [])

    def test_pre_existing_certificate_is_never_revoked_even_if_the_runner_holds_it(self):
        # Guard 1 alone must hold: if a runner image ever shipped with an identity baked
        # into its keychain, the snapshot still protects it.
        revoke, _ = ac.select_for_revocation(
            before=[DAVID_MAC, STALE_CI],
            after=[DAVID_MAC, STALE_CI],
            runner_sha1s={DAVID_MAC["sha1"], STALE_CI["sha1"]},
        )
        self.assertEqual(revoke, [])

    def test_certificate_made_elsewhere_during_the_run_is_left_alone(self):
        # Guard 2 alone must hold: David opens Xcode on a new Mac mid-run and it mints a
        # certificate. New since the snapshot, but not ours.
        davids_new_mac = cert("MACDAVID02", "D" * 40, name="David Latimore II")
        revoke, left = ac.select_for_revocation(
            before=[DAVID_MAC],
            after=[DAVID_MAC, davids_new_mac, THIS_RUN],
            runner_sha1s={THIS_RUN["sha1"]},
        )
        self.assertEqual([c["id"] for c in revoke], ["CINEW00018"])
        self.assertEqual([c["id"] for c in left], ["MACDAVID02"])

    def test_empty_runner_keychain_revokes_nothing(self):
        revoke, left = ac.select_for_revocation(
            before=[DAVID_MAC], after=[DAVID_MAC, THIS_RUN], runner_sha1s=set()
        )
        self.assertEqual(revoke, [])
        self.assertEqual([c["id"] for c in left], ["CINEW00018"])

    def test_certificate_without_content_is_never_matched(self):
        no_content = cert("CINOCONTNT", None)
        revoke, _ = ac.select_for_revocation(
            before=[], after=[no_content], runner_sha1s={"", "None"}
        )
        self.assertEqual(revoke, [])

    def test_distribution_certificate_is_never_revoked(self):
        # Export signing is cloud-managed and must not be disturbed, even if somehow new
        # and present on the runner.
        dist = cert("DISTMANAGED", "E" * 40, ctype="DISTRIBUTION")
        revoke, left = ac.select_for_revocation(
            before=[], after=[dist], runner_sha1s={dist["sha1"]}
        )
        self.assertEqual(revoke, [])
        self.assertEqual(left, [])

    def test_failed_archive_that_minted_nothing_revokes_nothing(self):
        # Runs #16/#17 exactly: at the limit, Xcode couldn't create a certificate.
        revoke, left = ac.select_for_revocation(
            before=[DAVID_MAC, STALE_CI], after=[DAVID_MAC, STALE_CI], runner_sha1s=set()
        )
        self.assertEqual((revoke, left), ([], []))


class Normalize(unittest.TestCase):
    def test_drops_distribution_and_fingerprints_the_der(self):
        with open(os.path.join(FIX, "certs_after.json")) as f:
            certs = ac.normalize(json.load(f)["data"])
        self.assertEqual([c["id"] for c in certs], ["MACDAVID01", "CISTALE016", "CINEW00018"])
        self.assertTrue(all(len(c["sha1"]) == 40 and c["sha1"].isupper() for c in certs))

    def test_fingerprint_matches_what_security_prints(self):
        der = b"\x30\x82\x01\x00-some-certificate"
        item = {"id": "X1", "attributes": {"certificateType": "DEVELOPMENT",
                                            "certificateContent": base64.b64encode(der).decode()}}
        import hashlib
        self.assertEqual(ac.normalize([item])[0]["sha1"], hashlib.sha1(der).hexdigest().upper())


class KeychainParsing(unittest.TestCase):
    def test_reads_sha1_lines_and_ignores_sha256(self):
        with open(os.path.join(FIX, "keychain_runner.txt")) as f:
            sha1s = ac.parse_keychain_sha1s(f.read())
        self.assertEqual(len(sha1s), 2)
        self.assertTrue(all(len(s) == 40 for s in sha1s))

    def test_lowercase_is_normalised(self):
        self.assertEqual(ac.parse_keychain_sha1s("SHA-1 hash: " + "ab" * 20), {"AB" * 20})


class DerToRaw(unittest.TestCase):
    def test_strips_sign_padding_and_left_pads_short_integers(self):
        r = b"\x00" + b"\x80" + b"\x11" * 31  # 33 bytes: high bit set, so DER adds 0x00
        s = b"\x22" * 31  # 31 bytes: a leading zero byte was dropped
        der = b"\x30" + bytes([2 + len(r) + 2 + len(s)]) + b"\x02" + bytes([len(r)]) + r + b"\x02" + bytes([len(s)]) + s
        raw = ac.der_ecdsa_to_raw(der)
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[:32], b"\x80" + b"\x11" * 31)
        self.assertEqual(raw[32:], b"\x00" + b"\x22" * 31)

    def test_rejects_garbage(self):
        with self.assertRaises(ValueError):
            ac.der_ecdsa_to_raw(b"\x04notasequence")


def raw_to_der(raw: bytes) -> bytes:
    def integer(b: bytes) -> bytes:
        b = b.lstrip(b"\x00") or b"\x00"
        if b[0] & 0x80:
            b = b"\x00" + b
        return b"\x02" + bytes([len(b)]) + b
    body = integer(raw[:32]) + integer(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


def b64url_decode(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


@unittest.skipUnless(shutil.which("openssl"), "openssl not on PATH")
class JWT(unittest.TestCase):
    """The token Apple will see. Signed with a throwaway P-256 key exactly the way the
    workflow signs with ASC_KEY_P8, then verified independently."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.key = os.path.join(self.dir, "AuthKey_TEST.p8")
        self.pub = os.path.join(self.dir, "pub.pem")
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt",
                        "ec_paramgen_curve:P-256", "-out", self.key], check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", self.key, "-pubout", "-out", self.pub],
                       check=True, capture_output=True)

    def tearDown(self):
        shutil.rmtree(self.dir)

    def test_es256_token_verifies_and_carries_app_store_connect_claims(self):
        token = ac.make_jwt("KEYID12345", "issuer-uuid", ac.openssl_signer(self.key), now=1_760_000_000)
        header_b64, payload_b64, sig_b64 = token.split(".")
        header = json.loads(b64url_decode(header_b64))
        payload = json.loads(b64url_decode(payload_b64))
        self.assertEqual(header, {"alg": "ES256", "kid": "KEYID12345", "typ": "JWT"})
        self.assertEqual(payload["aud"], "appstoreconnect-v1")
        self.assertEqual(payload["iss"], "issuer-uuid")
        self.assertLessEqual(payload["exp"] - payload["iat"], 20 * 60)

        raw = b64url_decode(sig_b64)
        self.assertEqual(len(raw), 64)
        sig_path = os.path.join(self.dir, "sig.der")
        with open(sig_path, "wb") as f:
            f.write(raw_to_der(raw))
        verify = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", self.pub, "-signature", sig_path],
            input=f"{header_b64}.{payload_b64}".encode(), capture_output=True)
        self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)


class CLIDryRun(unittest.TestCase):
    """The workflow's exact command lines, against canned API responses. No key, no
    network: urlopen is booby-trapped."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.snapshot = os.path.join(self.dir, "certs-before.json")
        self.summary = os.path.join(self.dir, "summary.md")
        self.env = mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": self.summary})
        self.env.start()
        self.net = mock.patch("urllib.request.urlopen", side_effect=AssertionError("network used"))
        self.net.start()

    def tearDown(self):
        self.net.stop()
        self.env.stop()
        shutil.rmtree(self.dir)

    def run_main(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = ac.main(list(argv))
        return code, out.getvalue()

    def test_snapshot_then_cleanup_would_revoke_only_this_runs_certificate(self):
        code, _ = self.run_main("snapshot", "--out", self.snapshot,
                                "--from-json", os.path.join(FIX, "certs_before.json"))
        self.assertEqual(code, 0)
        with open(self.snapshot) as f:
            self.assertEqual([c["id"] for c in json.load(f)], ["MACDAVID01", "CISTALE016"])

        code, out = self.run_main("cleanup", "--before", self.snapshot,
                                  "--after-json", os.path.join(FIX, "certs_after.json"),
                                  "--keychain-sha1s", os.path.join(FIX, "keychain_runner.txt"),
                                  "--dry-run")
        self.assertEqual(code, 0)
        self.assertIn("Would revoke (created by this run): **1**", out)
        self.assertIn("| `CINEW00018` | Created via API | DEVELOPMENT | 2027-10-12 | would revoke |", out)
        self.assertIn("| `MACDAVID01` | David Latimore II | DEVELOPMENT | 2027-07-08 | pre-existing: kept |", out)
        self.assertNotIn("DISTMANAGED", out)
        with open(self.summary) as f:
            self.assertIn("CINEW00018", f.read())

    def test_missing_snapshot_revokes_nothing_and_fails(self):
        code, out = self.run_main("cleanup", "--before", os.path.join(self.dir, "nope.json"),
                                  "--after-json", os.path.join(FIX, "certs_after.json"),
                                  "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("revoking nothing", out)

    def test_canned_after_data_cannot_be_used_for_a_live_revoke(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            ac.main(["cleanup", "--before", self.snapshot,
                     "--after-json", os.path.join(FIX, "certs_after.json")])


class LiveCleanupAgainstAFakeAccount(unittest.TestCase):
    """The non-dry-run path, with the API replaced by an in-memory account."""

    class FakeAccount:
        def __init__(self, certs, fail_on=()):
            self.certs = list(certs)
            self.deleted = []
            self.fail_on = set(fail_on)

        def list_dev_certs(self):
            return list(self.certs)

        def revoke(self, cert_id):
            if cert_id in self.fail_on:
                raise RuntimeError("HTTP 409")
            self.deleted.append(cert_id)
            self.certs = [c for c in self.certs if c["id"] != cert_id]

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.snapshot = os.path.join(self.dir, "before.json")
        with open(self.snapshot, "w") as f:
            json.dump([DAVID_MAC, STALE_CI], f)
        self.keychain = os.path.join(self.dir, "kc.txt")
        with open(self.keychain, "w") as f:
            f.write(f"SHA-1 hash: {THIS_RUN['sha1']}\n")

    def tearDown(self):
        shutil.rmtree(self.dir)

    def cleanup(self, account):
        out = io.StringIO()
        with mock.patch.object(ac, "client_from_args", return_value=account), \
                mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}), \
                contextlib.redirect_stdout(out):
            code = ac.main(["cleanup", "--key", "unused", "--before", self.snapshot,
                            "--keychain-sha1s", self.keychain])
        return code, out.getvalue()

    def test_deletes_exactly_one_and_count_returns_to_baseline(self):
        account = self.FakeAccount([DAVID_MAC, STALE_CI, THIS_RUN])
        code, out = self.cleanup(account)
        self.assertEqual(code, 0)
        self.assertEqual(account.deleted, ["CINEW00018"])
        self.assertIn("Minted this run: **1**", out)
        self.assertIn("Left on the account now: **2**", out)

    def test_imported_ci_identity_is_reused_never_revoked_and_nothing_is_minted(self):
        # #183: run 38698347575 (15 Oct 2026) minted H45BP2D28T and revoked it, the 19th
        # "Certificate Has Been Revoked" email since 12 Oct. With the long-lived CI identity
        # imported, the runner keychain holds it, but it predates the snapshot, so it must
        # survive cleanup, and the summary must say nothing was minted.
        ci_identity = cert("CIIDENT183", "D" * 40, name="Apple Development: CI")
        with open(self.snapshot, "w") as f:
            json.dump([DAVID_MAC, ci_identity], f)
        with open(self.keychain, "w") as f:
            f.write(f"SHA-1 hash: {ci_identity['sha1']}\n")
        account = self.FakeAccount([DAVID_MAC, ci_identity])
        code, out = self.cleanup(account)
        self.assertEqual(code, 0)
        self.assertEqual(account.deleted, [])
        self.assertIn("Minted this run: **0**", out)
        self.assertIn("Revoked (created by this run): **0**", out)
        self.assertIn("Left on the account now: **2**", out)
        self.assertIn("| `CIIDENT183` | Apple Development: CI | DEVELOPMENT | 2027-10-11 | pre-existing: kept |", out)

    def test_a_failed_revoke_turns_the_step_red(self):
        account = self.FakeAccount([DAVID_MAC, STALE_CI, THIS_RUN], fail_on={"CINEW00018"})
        code, out = self.cleanup(account)
        self.assertEqual(code, 1)
        self.assertIn("revoke FAILED", out)


if __name__ == "__main__":
    unittest.main()
