"""Checksum-verified download for model weights.

Every conversion script pulls a `.pth` off the internet and hands it to
`torch.load`. Historically that was `urllib.request.urlretrieve` with no
verification at all, which means the integrity of the model you run came down
to trusting whatever the URL served that day.

`torch.load(weights_only=True)` is the other half of the defence, but it is
only as good as the torch you are running — CVE-2025-32434 was a bypass of
exactly that flag. Pinning the hash does not depend on a torch version.

A mismatch is fatal on purpose. There is no --force: if the bytes changed,
either upstream re-cut the release (in which case update the constant in the
script, deliberately, after checking why) or something is wrong.
"""
from __future__ import annotations

import hashlib
import sys
import urllib.request
from pathlib import Path


class ChecksumMismatch(RuntimeError):
    pass


def sha256_of(path: Path, _chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(_chunk), b""):
            h.update(block)
    return h.hexdigest()


def download_verified(url: str, dest: Path, sha256: str) -> None:
    """Download `url` to `dest` unless already present, then verify its hash.

    An existing file is re-verified rather than trusted, so a half-written or
    tampered-with cache from an earlier run cannot quietly survive.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)

    if dest.exists():
        actual = sha256_of(dest)
        if actual == sha256:
            print(f"weights already present and verified: {dest}")
            return
        print(f"cached file failed verification, re-downloading: {dest}", file=sys.stderr)
        dest.unlink()

    print(f"downloading {url}")
    tmp = dest.with_suffix(dest.suffix + ".part")
    try:
        urllib.request.urlretrieve(url, tmp)
        actual = sha256_of(tmp)
        if actual != sha256:
            raise ChecksumMismatch(
                f"\n  checksum mismatch for {url}"
                f"\n    expected {sha256}"
                f"\n    actual   {actual}"
                f"\n  Refusing to load these weights. If upstream legitimately re-cut this"
                f"\n  release, update the SHA256 constant in the conversion script after"
                f"\n  confirming why it changed."
            )
        tmp.replace(dest)
        print(f"saved and verified: {dest}")
    finally:
        tmp.unlink(missing_ok=True)


def demo() -> None:
    """Self-check: a good hash passes, a bad one raises and leaves no file."""
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        payload = b"latent checksum self-check"
        good = hashlib.sha256(payload).hexdigest()

        src = d / "src.bin"
        src.write_bytes(payload)
        url = src.resolve().as_uri()

        dest = d / "ok.bin"
        download_verified(url, dest, good)
        assert dest.exists() and sha256_of(dest) == good

        # Second call takes the "already present" path and must still verify.
        download_verified(url, dest, good)
        assert dest.exists()

        # A wrong expectation must raise and must not leave a file behind.
        bad_dest = d / "bad.bin"
        try:
            download_verified(url, bad_dest, "0" * 64)
        except ChecksumMismatch:
            pass
        else:
            raise AssertionError("expected ChecksumMismatch")
        assert not bad_dest.exists(), "a failed download must not leave the file in place"

        # A tampered cache must be detected and replaced, not trusted.
        dest.write_bytes(b"tampered")
        download_verified(url, dest, good)
        assert sha256_of(dest) == good

    print("fetch.py self-check passed")


if __name__ == "__main__":
    demo()
