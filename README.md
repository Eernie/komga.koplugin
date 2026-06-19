# Komga Sync — KOReader plugin

Subscribe to Komga series, download their unread CBZ files to your Kobo, and
sync reading progress bi-directionally with your Komga server.

## Requirements
- A Kobo (or other device) running [KOReader](https://koreader.rocks).
- A Komga server (v1.x) reachable from the device, with an **API key**
  (Komga → Account Settings → Generate API Key).

## Install
1. Download `komga.koplugin.zip` from the [latest release](../../releases/latest).
2. Unzip it — you'll get a `komga.koplugin` folder.
3. Copy that `komga.koplugin` folder into KOReader's `plugins/` directory:
   - Kobo: `.adds/koreader/plugins/komga.koplugin`
4. Restart KOReader.

(Or clone this repo and copy `_meta.lua`, `main.lua`, and `komga/` into a `komga.koplugin` folder yourself.)

## Configure
Top menu → **Komga Sync**:
1. **Server URL** — e.g. `https://komga.example.com`
2. **API key** — paste your Komga API key.
3. **Download folder** — defaults to KOReader's data dir `/komga`.
4. **Manage series** — tick the series you want synced.
5. **Sync now** — runs a sync immediately.

After that, a sync runs automatically on every WiFi connection: new unread
books download, progress syncs both ways (most-recent change wins on conflict),
and finished books are removed from the device once their completion is on Komga.

## How it works
- **Download:** for each subscribed series, only books still marked *unread* on
  Komga are downloaded (to `<download folder>/<Series>/<Book>.cbz`). Downloads go
  to a `.part` file and are renamed on success, so an interrupted download is
  never mistaken for a complete one.
- **Progress sync:** reading is page-based for CBZ, which maps 1:1 to Komga's
  per-book read-progress. Each sync compares the device page and the Komga page
  against the last synced state; whichever side changed is applied to the other,
  and if both changed the most recently updated side wins.
- **Cleanup:** once a book is finished *and* that completion has been pushed to
  Komga, its local `.cbz` and `.sdr` sidecar are deleted to free space.

## Development
Pure logic lives in `komga/` and is unit-tested with [busted](https://lunarmodules.github.io/busted/):

```bash
brew install lua luarocks
luarocks install busted
busted
```

The KOReader-bound modules (`komga/client.lua`, `komga/progress_tracker.lua`,
`main.lua`) depend on the KOReader runtime and are verified on-device.
