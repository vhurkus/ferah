# Ferah

A free, open-source Mac cleaner and app uninstaller that tells you what it found, why it's safe to remove, and never deletes anything permanently: everything goes to the Trash, where Finder's **Put Back** still works.

## Install

```sh
brew install --cask vhurkus/tap/ferah
```

Or download the notarized DMG from [Releases](https://github.com/vhurkus/ferah/releases). Requires macOS 15 or later.

## What it does

- **Uninstall apps completely** — the app plus the files it leaves in your Library and in /Library. Only files that provably belong to the app are preselected; guesses by name are left for you to review. Apps you drag to the Trash yourself are noticed, and their leftovers offered.
- **Storage** — see where your disk space goes, folder by folder, and open any folder to look deeper.
- **System Data** — Time Machine local snapshots, Xcode simulators and iPhone/iPad backups, each removed the way macOS expects.
- **Caches, logs and developer files** — Xcode build data, package manager caches, `node_modules`.
- **Large & old files**, **duplicates** (byte-for-byte identical), **background items** (launch agents and daemons, with the app they belong to).
- **Homebrew** — installed apps and tools, updates, and casks whose app is gone.
- **Menu bar** — free space at a glance and a warning when it runs low.

Ferah makes no speed-up promises, doesn't "clean" memory and never removes app language files.

## Safety

Every removal passes one policy (`Sources/CleanerCore/TrashPolicy.swift`): nothing outside your home folder except third-party apps and their /Library leftovers, nothing in Keychains, iCloud Drive, Mail or Messages, nothing that belongs to macOS or Apple's apps. Items you can't move yourself go through Finder, which asks for your password.

Full Disk Access is optional; without it some folders can't be measured.

## Build

Needs the Command Line Tools (Xcode not required).

```sh
scripts/test.sh              # unit tests
scripts/build-app.sh debug   # build/Ferah.app
scripts/make-dmg.sh          # release DMG (set NOTARY_PROFILE to notarize)
```

## Türkçe

Ferah, ücretsiz ve açık kaynak bir Mac temizleyici ve uygulama kaldırıcıdır. Bulduğu her şeyin neden güvenle silinebileceğini söyler ve hiçbir şeyi kalıcı olarak silmez; her şey Çöp Kutusu'na gider. Arayüz Türkçe ve İngilizcedir.

## License

MIT
