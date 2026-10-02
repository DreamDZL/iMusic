<div align="center">

<img src="platforms/ios/docs/iMusicIcon.png" width="140" alt="iMusic" />

# iMusic

**Native iOS 27 music client with an Apple Music-inspired interface**

SwiftUI · System Liquid Glass · LX User API · LX Sync Server

[![Platform](https://img.shields.io/badge/platform-iOS%2027%2B-blue?logo=apple)](#build)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](platforms/ios/Package.swift)
[![LGPL-3.0](https://img.shields.io/badge/license-LGPL--3.0-orange)](LICENSE)
[![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-orange)](COPYING)

</div>

iMusic continues the native iOS project from [Moumusic](https://github.com/jiajia2222/Moumusic). Its main destinations are Home, New, Search and Library. The interface uses native SwiftUI navigation and follows the system Liquid Glass appearance. Imported LX User API sources provide third-party playback and fallback; automatic mode may first use an eligible signed-in provider account.

QQ Music and NetEase public playlist imports become editable local copies. Edits to those copies stay in iMusic and are not written to the originating provider playlist. Local favorites and compatible playlists can sync through a self-hosted [LX Sync Server](https://github.com/lyswhut/lx-music-sync-server). Source scripts are managed locally on each device.

Users can also copy their NetEase liked songs into iMusic's local favorites from the Library. This import is one-way; later changes stay in iMusic and LX Sync.

## Features

- Apple Music-inspired Home, New, Search and Library page structure
- Artist, album and playlist details, mini-player, full-screen player, queue and synchronized lyrics
- Native lock-screen and Control Center playback controls
- User-managed LX source import, validation, enable/disable, switching, export and deletion
- Multi-source catalog search and playback resolution
- Local favorites, recent playback and editable playlists
- QQ Music and NetEase public playlist imports as local copies
- Optional LX Sync for compatible favorites and playlists
- iOS 27 system Liquid Glass, with transparency and tint following iPhone display and accessibility settings
- Some continuous decorative animations and audio spectrum analysis are throttled or paused for Low Power Mode, thermal pressure and inactive app scenes; New content refreshes automatically at most every ten minutes

The default target does not include an in-app audio-download screen, Home Screen widgets or CarPlay integration. Playback Live Activities remain available. The player can reuse local audio files that are already present.

## Sources and synchronization

Open **Library → More → Manage LX Sources** to import a source from a file or URL and run its availability check. No third-party source URLs are bundled.

Open **Library → Sync Library** to enter an LX Sync Server address and connection code. The client syncs compatible favorites and playlists. LX Sync does not carry LX source scripts, so import those on each device. Edits to imported QQ Music and NetEase copies remain local to iMusic and do not modify the provider playlists.

## Build

The iOS application requires macOS and Xcode. XcodeGen generates the app and ActivityKit extension targets:

```sh
cd platforms/ios/ios
xcodegen generate
xcodebuild -project KumoneIOS.xcodeproj -scheme KumoneIOS -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

The deployment target is iOS 27 and the app is designed for standard iPhone sizes. It does not include a foldable-specific layout.

## Project layout

```text
platforms/ios/
├── Sources/Kumone/
│   ├── Core/API/          Catalog, playlist import and LX source bridge
│   ├── Core/Models/       Track, playlist and lyric models
│   ├── Core/Player/       AVPlayer, queue, lyrics and system playback state
│   ├── Core/Storage/      Local library, source configuration and account data
│   ├── Core/Sync/         LX Sync wire models and client
│   ├── DesignSystem/      SwiftUI theme, Liquid Glass and rendering budget
│   └── Features/          Home, New, Search, Library, settings and player
├── ios/                   iOS app shell, playback Live Activity extension, tests and XcodeGen manifest
└── docs/                  Product icon and screenshots
platforms/android/         Preserved upstream subtree; not part of the iMusic iOS target
```

## Upstream and licensing

- [Moumusic](https://github.com/jiajia2222/Moumusic) — native iOS project foundation
- [LX Music Mobile](https://github.com/lyswhut/lx-music-mobile) — LX source and data protocol reference
- [LX Sync Server](https://github.com/lyswhut/lx-music-sync-server) — compatible self-hosted sync service

Upstream source files, assets and notices retain their original license obligations. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [LICENSE](LICENSE) and [COPYING](COPYING).
