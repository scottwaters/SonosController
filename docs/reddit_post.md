# Reddit Post Draft — r/sonos

**Title:** I built a free native macOS Sonos controller — open source, no cloud, no account required

---

**Body:**

Like a lot of you, I've been dreading the day Apple drops Rosetta and the old Sonos desktop app stops working. Instead of waiting, I built a replacement from scratch.

**SonosController** is a native macOS app (Swift/SwiftUI) that controls your Sonos speakers over your local network using the same UPnP protocols the speakers already support. No cloud API, no Sonos account needed for core features.

### What it does

- **Full playback control** — play, pause, skip, seek, shuffle, repeat, sleep timer
- **Multi-room** — group/ungroup speakers, per-speaker volume, proportional group volume
- **Browse your library** — NAS/network music library with search, Sonos Favorites, playlists
- **Music services** — TuneIn, Calm Radio, Sonos Radio search, Apple Music search, Spotify (with AppLink auth)
- **Now Playing** — album art with automatic iTunes lookup, radio stream artist/title parsing, manual artwork search
- **Listening history** — dashboard with charts, streaks, top tracks/artists/stations, timeline view
- **Menu bar mode** — control playback without switching apps
- **EQ controls** — bass, treble, loudness, home theater sub/surround
- **13 languages** — English, German, French, Dutch, Spanish, Italian, Swedish, Norwegian, Danish, Japanese, Portuguese, Polish, Chinese

### Technical details

- Universal binary (Apple Silicon + Intel)
- macOS 14+ (Sonoma)
- Zero external dependencies
- 267 unit tests
- App sandbox with minimal entitlements
- Tokens in Keychain, not plain text

### Music service status

| Service | Status |
|---------|--------|
| Local library (NAS) | Full browse + playback |
| Sonos Favorites/Playlists | Full browse + playback |
| TuneIn | Browse + search + playback (no login) |
| Calm Radio | Browse + playback (no login) |
| Apple Music | Search + playback (needs AM connected in Sonos app) |
| Sonos Radio | Search + playback (browse categories not yet working) |
| Spotify | Full browse + search + playback (AppLink auth) |
| Amazon Music | Not supported (requires native OAuth) |
| YouTube Music | Not supported (requires native OAuth) |

### What it doesn't do (yet)

- Can't add to Sonos Favorites (requires cloud API)
- Can't manage alarms (S2 uses cloud, not UPnP)
- Sonos Radio category browsing needs DeviceLink auth (working on it)

Tested against a live system with 16 speakers across 10 zones, 45,000+ track library, and multiple streaming services.

Happy to answer questions or take feature requests. MIT licensed.

---

*Not affiliated with Sonos, Inc. "Sonos" is a trademark of Sonos, Inc. This is an independent fan project using standard UPnP protocols.*
