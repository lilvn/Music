# Feature status — autonomous build session

## Done & verified in the simulator
- **Flat system-adaptive redesign** — Liquid Glass removed everywhere; flat bottom bar
  (tabs + expanding search), bordered/filled buttons, solid mini bar. Light detail / Now
  Playing / Up Next / Lyrics pages. Featured gradient removed.
- **Search** — auto-focuses the keyboard on open; one-tap activation.
- **Tracklist formatting** — single-track albums now show a number like multi-track ones.
- **Bottom clearance** — scroll content clears the nav bar + mini player.
- **Disc scrub bug** — the mini-bar disc keeps spinning through a scrub (no freeze/glitch).
- **Detail Play row** — round play-next / add-to-queue buttons flank the Play pill.
- **Recently Played** shelf on Home (data-driven; populates as you listen).
- **Reset to top of queue** when the queue finishes.
- **Jellyfin scrobbling** — reports play / progress / stop while playing (endpoints verified).
- **Resume after interruptions** — re-activates the audio session and resumes.
- **Go to Album / Artist** from the Now Playing title.
- **Genre filter** on the Albums page (server-side, via GenreIds).
- **Nav bar + mini player stay above detail pages** — details now PUSH within the tab
  (zoom card-expand preserved); only Now Playing covers the whole screen. This also fixes
  the scroll-vs-dismiss conflict (back = nav-bar button + edge-swipe).
- **AirPlay** — AVRoutePickerView button in Now Playing (works on a device with AirPlay targets).
- **Spotlight** — indexes albums/artists/playlists on launch; tapping a result deep-links in.
- **Siri / Shortcuts** — in-app App Intents:
  - "Play <song/album/artist> in Jellytunes" (searches the library)
  - "Play recently played in Jellytunes"
  - "Add this to <playlist> in Jellytunes"
  Build/metadata verified. Full hands-free Siri phrasing should be confirmed on a device.

## Needs you / a device (not done autonomously, with reasons)
- **CarPlay** — requires the `com.apple.developer.carplay-audio` entitlement, which **Apple
  must grant to the developer account** (a managed entitlement request). It can't be enabled,
  built, or tested without that grant. Once granted: add the entitlement + a
  `CPTemplateApplicationSceneDelegate` exposing `CPListTemplate`s (library/now-playing) backed
  by the existing `JellyfinAPI`/`AudioPlayerManager`. Scoped but blocked on the entitlement.
- **Gapless playback** — true sample-accurate gapless requires migrating the engine from
  `AVPlayer` (+`replaceCurrentItem`) to **`AVQueuePlayer`** (pre-enqueue the next item so the
  transition has no gap). That reworks scrubbing, shuffle, manual next/prev, queue editing,
  and progress reporting, so it's risky to do blind — recommend doing it with you to validate
  playback feel. (Preloading the next item alone does NOT remove the `replaceCurrentItem` gap.)
- **Siri deeper context queries** — the play / add-to-playlist intents are in; richer
  conversational queries are best validated on a device with Siri.
