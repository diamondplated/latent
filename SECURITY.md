# Security

## Reporting a vulnerability

Use GitHub's **Security → Report a vulnerability** form on this repository (private vulnerability
reporting is enabled). Please don't open a public issue for an unpatched problem.

If it involves a specific image or archive, describe the file rather than attaching one you can't
share — format, rough dimensions, and where it came from is usually enough to reproduce.

## What Latent is, from a security standpoint

A local, single-user Mac app that reads image files from folders you point it at. There is no
account, no sync, no server, and no telemetry.

**No runtime network calls.** The running app does not contact anything. The only network access in
this project is `scripts/convert_*.py`, which you run yourself, once, to download model weights. If
you never run those scripts, Latent never touches the network — and it still works, because every
model-backed stage degrades to a classical fallback or a pass-through.

## The properties that are meant to hold

- **No network at runtime.** A change that introduces a runtime fetch — update check, telemetry,
  remote model pull — breaks the core promise of the app and needs to be behind an explicit,
  off-by-default flag.
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

**Model weights are downloaded without checksum pinning.** The conversion scripts fetch from the
upstream projects' GitHub release URLs over HTTPS, and do not verify a pinned hash of what comes
back. You are trusting TLS and those upstream releases. If you need a stronger guarantee, download
and verify the weights yourself and place the converted `.mlpackage` files in `Resources/Models/`.

See [THIRD_PARTY_MODELS.md](THIRD_PARTY_MODELS.md) for what each model is and how it's licensed —
GFPGAN's terms in particular have non-commercial carve-outs.

## Out of scope

- Anything requiring an attacker who already has local code execution as your user.
- Crashes or hangs on deliberately malformed images. Those are bugs; file them as issues.
- The upstream ML projects and their published weights.

## Supported versions

Latent is pre-1.0 and only the current `main` is supported.
