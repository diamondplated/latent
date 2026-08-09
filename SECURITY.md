# Security

## Reporting a vulnerability

Use GitHub's **Security → Report a vulnerability** form on this repository (private vulnerability
reporting is enabled). Please don't open a public issue for an unpatched problem.

If it involves a specific image or archive, describe the file rather than attaching one you can't
share — format, rough dimensions, and where it came from is usually enough to reproduce.

## What Latent is, from a security standpoint

A local, single-user Mac app that reads image files from folders you point it at. There is no
account, no sync, no server, and no telemetry.

**No runtime network calls by default.** Out of the box the running app does not contact anything.
Three things can touch the network, and all three are things you ask for:

- `scripts/convert_*.py`, which you run yourself, once, to download model weights. If you never run
  them Latent still works, because every model-backed stage degrades to a classical fallback or a
  pass-through.
- The map view, which is MapKit and fetches its tiles from Apple while it is open.
- The phone companion, which is off until you switch it on, serves only your local network, and
  stops when you quit. See the README for its pairing and trust model.

## The properties that are meant to hold

- **No network at runtime unless the user turned it on.** A change that introduces a runtime fetch —
  update check, telemetry, remote model pull — breaks the core promise of the app. The only
  acceptable shape is the one the phone companion uses: off by default, switched on deliberately,
  scoped as narrowly as the feature allows, and documented plainly.
- **The phone companion stays on the local network.** Connections from outside a private address
  range are refused, there is no relay and no account, and traffic is unencrypted — so a change that
  would route it through a remote service, or that weakens the address gate or the one-time pairing,
  is a change to the app's core promise and not a routine one.
- **Deletion is recoverable.** Trashing uses `FileManager.trashItem`, so files go to the Finder
  Trash and can be restored. Nothing in the culling flow permanently deletes a photo.
- **Export can strip metadata.** `preserveMetadata: false` removes EXIF on write. That is a privacy
  feature, not an oversight — photos carry GPS coordinates.
- **Enhancement is non-destructive.** Results are written to `.enhance.json` sidecars; the original
  file is not modified.
- **Archive extraction is contained.** Archives are extracted into a fresh temporary directory, not
  into the folder being browsed, and the temp directory is removed if extraction fails.

## Attack surface worth knowing about

**Parsing untrusted images.** Latent decodes whatever you point it at through Apple's ImageIO and
Vision frameworks. A malicious image that exploits those is an Apple-level issue; keep macOS
patched. Latent adds no image parser of its own.

**Archive extraction shells out to external tools.** `ArchiveExtractor` runs `/usr/bin/unzip` and
`/usr/bin/tar` for zip and tar formats, using `Process` with argument arrays — there is no shell, so
a hostile filename cannot inject a command. Protection against path traversal (`../` entries) comes
from those tools' own behaviour rather than from a check in Latent; extraction into a private temp
directory is the containment.

For `.rar` and `.7z`, Latent looks for `unrar` / `7zz` in the standard Homebrew and MacPorts
prefixes and then falls back to resolving the name on your `PATH`. That means it will execute a
binary found on your `PATH` by name. That is your `PATH` and your machine, but if you keep untrusted
directories on it, be aware.

**Model weights are checksum-pinned.** Every conversion script that can download its own weights
verifies them against a SHA256 recorded in the script before `torch.load` ever sees the file
(`scripts/fetch.py`). A mismatch is fatal and there is no override — a cached file is re-verified
rather than trusted, so a tampered or half-written download from an earlier run cannot survive.

This matters more than it looks. The scripts call `torch.load(..., weights_only=True)`, which is the
right mitigation, but CVE-2025-32434 was a bypass of exactly that flag in torch < 2.6.0. A pinned
hash does not depend on which torch you happen to be running. `scripts/requirements.txt` also pins
torch at a version past that CVE, and drops `basicsr` entirely — it was unimportable on any modern
torch and carried an unpatched advisory of its own.

The exception is NAFNet: upstream publishes no GitHub release, so there is no canonical artifact to
pin. That script does not download anything. It requires you to place the checkpoint yourself and
prints the SHA256 of what it is about to load.

See [THIRD_PARTY_MODELS.md](THIRD_PARTY_MODELS.md) for what each model is and how it's licensed.
All four are permissively licensed.

## Out of scope

- Anything requiring an attacker who already has local code execution as your user.
- Crashes or hangs on deliberately malformed images. Those are bugs; file them as issues.
- The upstream ML projects and their published weights.

## Supported versions

Latent is pre-1.0 and only the current `main` is supported.
