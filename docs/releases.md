# Latent Releases and Updates

Latent supports two update workflows.

## Local developer update

Use this when this checkout is your source of truth:

```bash
cd /Users/andrew/Projects/photo-viewer
./scripts/update_from_github.sh
```

That script requires a clean working tree, fast-forwards `main` from GitHub,
builds `Latent.app`, installs it into `/Applications`, registers document
types, and opens it.

## Sparkle update flow

The user-facing updater uses Sparkle:

- `SUFeedURL` points to `https://diamondplated.github.io/latent/appcast.xml`
- GitHub Releases host `Latent-<version>.zip`
- GitHub Pages hosts the signed Sparkle `appcast.xml`
- the app starts Sparkle only when `SUPublicEDKey` is configured in the bundle

Local builds use a placeholder public key, so the Check for Updates menu item is
disabled. Release builds inject the real key from GitHub secrets.

## Generate Sparkle keys

Download Sparkle tools and generate a key pair:

```bash
SPARKLE_VERSION=2.9.1
mkdir -p /tmp/sparkle
curl -fsSL \
  "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
  -o /tmp/sparkle/Sparkle.tar.xz
tar -xJf /tmp/sparkle/Sparkle.tar.xz -C /tmp/sparkle

/tmp/sparkle/bin/generate_keys
```

`generate_keys` stores the private key in your login Keychain and prints the
public key for `SUPublicEDKey`.

Export the private key for GitHub Actions:

```bash
/tmp/sparkle/bin/generate_keys -x /tmp/latent-sparkle-private-key.txt
cat /tmp/latent-sparkle-private-key.txt
rm /tmp/latent-sparkle-private-key.txt
```

Add these repository secrets in GitHub:

- `SPARKLE_PUBLIC_ED_KEY`: the public key printed by `generate_keys`
- `SPARKLE_PRIVATE_KEY`: the exported private key contents

Do not commit the private key. That would make update signing security a very
expensive hat.

## Enable GitHub Pages

In GitHub:

1. Open `diamondplated/latent`.
2. Go to Settings -> Pages.
3. Set Source to GitHub Actions.

The release workflow deploys only:

- `appcast.xml`
- the markdown release note file used by Sparkle

## Cut a release

Make sure `main` is green, then tag:

```bash
git checkout main
git pull --ff-only origin main
git tag v0.1.1
git push origin v0.1.1
```

The `Release Latent` workflow will:

1. run `swift test`
2. build `Latent.app`
3. inject `CFBundleShortVersionString`, `CFBundleVersion`, and `SUPublicEDKey`
4. archive `Latent.app` as `Latent-0.1.1.zip`
5. sign `appcast.xml` with the Sparkle private key
6. publish the zip to GitHub Releases
7. deploy `appcast.xml` to GitHub Pages

## Developer ID signing

The current workflow is enough for Sparkle-signed update archives, but public
distribution should add Apple Developer ID signing and notarization. The bundle
script already honors `CODE_SIGN_IDENTITY`; CI still needs the Developer ID
certificate import and notarization steps before this is truly public-user
polished.
