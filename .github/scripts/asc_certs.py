#!/usr/bin/env python3
"""Keep the TestFlight workflow from leaking Apple Development certificates (#103).

Every TestFlight run starts on a fresh macOS runner with an empty keychain. The signed
archive (automatic signing, -allowProvisioningUpdates, App Store Connect API key) has no
development identity to reuse, so Xcode mints a brand-new Apple Development certificate
every time and never cleans it up. Runs #16 and #17 (11 Oct 2026) then failed with
"Your account has reached the maximum number of certificates" and every merge after that
would have too.

So the workflow brackets the archive:

    snapshot  -> before the archive, record every development certificate on the account
    cleanup   -> after export (always), revoke what this run created, and nothing else

"What this run created" has to clear two independent bars before anything is revoked:
  1. its id is absent from the snapshot taken before the archive, AND
  2. its SHA-1 fingerprint is in this runner's keychain (i.e. Xcode minted it *here*).
A certificate that existed before the run fails (1). One that David's Mac happens to create
mid-run fails (2). His Mac's own identity, "Apple Development: David Latimore II
(JX4RKFC6W2)", fails both. If either bar can't be evaluated, nothing is revoked.

Standard library only (plus the system `openssl` and `security` binaries), so there is no
pip install on the runner to rot. The JWT is ES256, signed by `openssl dgst`.

    asc_certs.py snapshot --key AuthKey.p8 --out before.json
    asc_certs.py cleanup  --key AuthKey.p8 --before before.json [--dry-run]
    asc_certs.py list     --key AuthKey.p8          # read-only; marks this Mac's own certs

Dry runs against canned JSON need no key and no network:

    asc_certs.py cleanup --before before.json --after-json after.json \\
        --keychain-sha1s keychain.txt --dry-run
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Callable, Iterable

API_ROOT = "https://api.appstoreconnect.apple.com"
# "Apple Development" is DEVELOPMENT; IOS_DEVELOPMENT is the legacy iOS-only flavour.
# Distribution certificates are cloud-managed at export time and never touched here.
DEV_TYPES = ("DEVELOPMENT", "IOS_DEVELOPMENT")


# --------------------------------------------------------------------------- pure logic


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _der_read_len(der: bytes, i: int) -> tuple[int, int]:
    first = der[i]
    if first < 0x80:
        return first, i + 1
    n = first & 0x7F
    return int.from_bytes(der[i + 1 : i + 1 + n], "big"), i + 1 + n


def der_ecdsa_to_raw(der: bytes, size: int = 32) -> bytes:
    """openssl emits ECDSA signatures as DER SEQUENCE{INTEGER r, INTEGER s}; JWS ES256
    wants the fixed-width r||s concatenation (RFC 7518 §3.4). Getting this wrong yields a
    token Apple rejects with a bare 401, so it is pinned by tests."""
    if not der or der[0] != 0x30:
        raise ValueError("not a DER SEQUENCE")
    _, i = _der_read_len(der, 1)
    parts = []
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("expected DER INTEGER")
        n, i = _der_read_len(der, i + 1)
        value = der[i : i + n].lstrip(b"\x00")
        if len(value) > size:
            raise ValueError("integer wider than curve size")
        parts.append(value.rjust(size, b"\x00"))
        i += n
    return parts[0] + parts[1]


def make_jwt(key_id: str, issuer_id: str, sign: Callable[[bytes], bytes], now: int) -> str:
    """App Store Connect team-key token. `sign` takes the signing input and returns a DER
    ECDSA signature (what `openssl dgst -sign` produces). Lifetime is capped at 20 min by
    Apple; 15 leaves headroom for clock skew."""
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    signing_input = (
        b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + b64url(json.dumps(payload, separators=(",", ":")).encode())
    )
    signature = der_ecdsa_to_raw(sign(signing_input.encode("ascii")))
    return signing_input + "." + b64url(signature)


def normalize(items: Iterable[dict]) -> list[dict]:
    """Flatten API `data` entries to what the decision needs. Non-development types are
    dropped here as well as in the query filter: this code must never be able to see,
    let alone revoke, a distribution certificate."""
    out = []
    for item in items:
        attrs = item.get("attributes") or {}
        ctype = attrs.get("certificateType")
        if ctype not in DEV_TYPES:
            continue
        content = attrs.get("certificateContent")
        sha1 = hashlib.sha1(base64.b64decode(content)).hexdigest().upper() if content else None
        out.append(
            {
                "id": item["id"],
                "name": attrs.get("name"),
                "displayName": attrs.get("displayName"),
                "type": ctype,
                "serialNumber": attrs.get("serialNumber"),
                "expirationDate": attrs.get("expirationDate"),
                "sha1": sha1,
            }
        )
    return out


_SHA1_LINE = re.compile(r"^SHA-1 hash:\s*([0-9A-Fa-f]{40})\s*$", re.MULTILINE)


def parse_keychain_sha1s(security_output: str) -> set[str]:
    """Fingerprints from `security find-certificate -a -Z`."""
    return {m.upper() for m in _SHA1_LINE.findall(security_output)}


def select_for_revocation(
    before: list[dict], after: list[dict], runner_sha1s: set[str]
) -> tuple[list[dict], list[dict]]:
    """Returns (revoke, left_alone_but_new).

    revoke: certificates absent from the pre-run snapshot AND minted on this runner.
    left_alone_but_new: absent from the snapshot but NOT in this runner's keychain, so
    someone else (David's Mac, a concurrent tool) made them during the run. Reported,
    never revoked.
    """
    before_ids = {c["id"] for c in before}
    new = [c for c in after if c["id"] not in before_ids and c.get("type") in DEV_TYPES]
    revoke = [c for c in new if c.get("sha1") and c["sha1"] in runner_sha1s]
    left = [c for c in new if c not in revoke]
    return revoke, left


def _row(c: dict, note: str = "") -> str:
    name = c.get("displayName") or c.get("name") or "?"
    expires = (c.get("expirationDate") or "?")[:10]
    return f"| `{c['id']}` | {name} | {c.get('type')} | {expires} | {note} |"


def render_summary(
    before: list[dict],
    after: list[dict],
    revoked: list[dict],
    left: list[dict],
    failed: list[tuple[dict, str]],
    remaining: int | None,
    dry_run: bool,
) -> str:
    verb = "Would revoke" if dry_run else "Revoked"
    lines = ["### Development certificates (#103)", ""]
    lines.append(f"- Before archive: **{len(before)}**")
    lines.append(f"- After export: **{len(after)}**")
    # Minted and revoked are the same set today. They are separate lines because they
    # answer different questions: Minted says whether Xcode reused the imported CI
    # identity (#183; should be 0), Revoked says whether the safety net had to act.
    lines.append(f"- Minted this run: **{len(revoked)}**")
    lines.append(f"- {verb} (created by this run): **{len(revoked)}**")
    if remaining is not None:
        lines.append(f"- Left on the account now: **{remaining}** (re-listed via the API)")
    if left:
        lines.append(
            f"- New since the snapshot but not made by this runner, left alone: **{len(left)}**"
        )
    if failed:
        lines.append(f"- Revocations that failed: **{len(failed)}**")
    lines += ["", "| id | name | type | expires | |", "|---|---|---|---|---|"]
    revoked_ids = {c["id"] for c in revoked}
    left_ids = {c["id"] for c in left}
    failed_ids = {c["id"]: why for c, why in failed}
    for c in after:
        if c["id"] in failed_ids:
            note = f"revoke FAILED: {failed_ids[c['id']]}"
        elif c["id"] in revoked_ids:
            note = verb.lower()
        elif c["id"] in left_ids:
            note = "new, not ours: kept"
        else:
            note = "pre-existing: kept"
        lines.append(_row(c, note))
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------------- I/O


def openssl_signer(key_path: str) -> Callable[[bytes], bytes]:
    def sign(data: bytes) -> bytes:
        return subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path],
            input=data,
            capture_output=True,
            check=True,
        ).stdout

    return sign


class ASCClient:
    def __init__(self, token: str):
        self.token = token

    def _request(self, method: str, url: str) -> dict | None:
        req = urllib.request.Request(
            url, method=method, headers={"Authorization": f"Bearer {self.token}"}
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:500]
            raise RuntimeError(f"{method} {url} -> HTTP {e.code}: {detail}") from None
        return json.loads(body) if body else None

    def list_dev_certs(self) -> list[dict]:
        query = urllib.parse.urlencode(
            {"filter[certificateType]": ",".join(DEV_TYPES), "limit": "200"}
        )
        url: str | None = f"{API_ROOT}/v1/certificates?{query}"
        items: list[dict] = []
        while url:
            page = self._request("GET", url) or {}
            items += page.get("data", [])
            url = (page.get("links") or {}).get("next")
        return normalize(items)

    def revoke(self, cert_id: str) -> None:
        if not re.fullmatch(r"[A-Za-z0-9]+", cert_id):
            raise ValueError(f"refusing odd certificate id {cert_id!r}")
        self._request("DELETE", f"{API_ROOT}/v1/certificates/{cert_id}")


def client_from_args(args: argparse.Namespace) -> ASCClient:
    key_id = os.environ.get("ASC_KEY_ID")
    issuer = os.environ.get("ASC_ISSUER_ID")
    if not (args.key and key_id and issuer):
        sys.exit("need --key plus ASC_KEY_ID and ASC_ISSUER_ID in the environment")
    return ASCClient(make_jwt(key_id, issuer, openssl_signer(args.key), int(time.time())))


def runner_keychain_sha1s() -> set[str]:
    out = subprocess.run(
        ["security", "find-certificate", "-a", "-Z"], capture_output=True, text=True
    ).stdout
    return parse_keychain_sha1s(out)


def _load(path: str) -> list[dict]:
    with open(path) as f:
        data = json.load(f)
    # Accept either our own snapshot format (a list) or a raw API response (canned).
    return normalize(data["data"]) if isinstance(data, dict) else data


def _summary(text: str) -> None:
    print(text)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as f:
            f.write(text + "\n")


# --------------------------------------------------------------------------- commands


def cmd_snapshot(args: argparse.Namespace) -> int:
    certs = _load(args.from_json) if args.from_json else client_from_args(args).list_dev_certs()
    # Write atomically: a half-written snapshot must not read as "nothing existed".
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(args.out)))
    with os.fdopen(fd, "w") as f:
        json.dump(certs, f, indent=2)
    os.replace(tmp, args.out)
    print(f"{len(certs)} development certificate(s) on the account before the archive:")
    for c in certs:
        print(f"  {c['id']}  {c.get('displayName') or c.get('name')}  expires {c.get('expirationDate')}")
    return 0


def cmd_cleanup(args: argparse.Namespace) -> int:
    try:
        before = _load(args.before)
    except (OSError, ValueError) as e:
        # No trustworthy snapshot means we cannot tell old from new. Revoke nothing.
        print(f"::error::No usable pre-run snapshot ({e}); revoking nothing.")
        return 1

    client = None if args.after_json else client_from_args(args)
    after = _load(args.after_json) if args.after_json else client.list_dev_certs()
    if args.keychain_sha1s:
        with open(args.keychain_sha1s) as f:
            sha1s = parse_keychain_sha1s(f.read())
    else:
        sha1s = runner_keychain_sha1s()

    revoke, left = select_for_revocation(before, after, sha1s)

    failed: list[tuple[dict, str]] = []
    if not args.dry_run:
        for c in revoke:
            try:
                client.revoke(c["id"])  # type: ignore[union-attr]
                print(f"revoked {c['id']} ({c.get('displayName') or c.get('name')})")
            except Exception as e:  # keep going; report every failure
                failed.append((c, str(e)))

    remaining = None
    if client is not None and not args.dry_run:
        try:
            remaining = len(client.list_dev_certs())
        except Exception as e:
            print(f"::warning::could not re-list certificates after cleanup: {e}")

    _summary(render_summary(before, after, revoke, left, failed, remaining, args.dry_run))

    for c in left:
        print(
            f"::warning::Development certificate {c['id']} appeared during this run but was "
            "not created on this runner, so it was left alone."
        )
    if left and not sha1s:
        # The fix would be silently inert: Xcode's identity isn't where `security` looks.
        print(
            "::warning::This runner's keychain search list returned no certificates, so no "
            "new certificate could be proven to be this run's. Nothing was revoked and the "
            "leak in #103 is NOT fixed on this runner image."
        )
    if failed:
        for c, why in failed:
            print(f"::error::Could not revoke {c['id']}: {why}")
        return 1
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    certs = _load(args.from_json) if args.from_json else client_from_args(args).list_dev_certs()
    mine = runner_keychain_sha1s()
    print(f"{len(certs)} development certificate(s):")
    for c in certs:
        here = "  <- in THIS machine's keychain" if c.get("sha1") in mine else ""
        print(
            f"  {c['id']}  {c.get('displayName') or c.get('name')}  "
            f"expires {(c.get('expirationDate') or '?')[:10]}{here}"
        )
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("snapshot", help="record development certificates before the archive")
    s.add_argument("--key", help="path to the AuthKey_*.p8")
    s.add_argument("--out", required=True)
    s.add_argument("--from-json", help="canned API response instead of calling Apple")
    s.set_defaults(func=cmd_snapshot)

    c = sub.add_parser("cleanup", help="revoke development certificates this run created")
    c.add_argument("--key", help="path to the AuthKey_*.p8")
    c.add_argument("--before", required=True, help="snapshot written by `snapshot`")
    c.add_argument("--after-json", help="canned API response instead of calling Apple")
    c.add_argument("--keychain-sha1s", help="canned `security find-certificate -a -Z` output")
    c.add_argument("--dry-run", action="store_true", help="decide and report, revoke nothing")
    c.set_defaults(func=cmd_cleanup)

    ls = sub.add_parser("list", help="read-only listing; marks certs in this machine's keychain")
    ls.add_argument("--key", help="path to the AuthKey_*.p8")
    ls.add_argument("--from-json", help="canned API response instead of calling Apple")
    ls.set_defaults(func=cmd_list)

    args = p.parse_args(argv)
    if getattr(args, "dry_run", False) is False and getattr(args, "after_json", None):
        p.error("--after-json is canned data; pair it with --dry-run")
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
