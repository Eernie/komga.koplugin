# Komga KOReader Plugin — Design Spec

**Date:** 2026-06-19
**Status:** Approved (design), pending implementation plan

## Purpose

A KOReader plugin (target device: Kobo running KOReader) that integrates with a
self-hosted [Komga](https://komga.org) comic server. It lets the user subscribe
to specific series, downloads their unread CBZ files to the device, and keeps
reading progress synchronized **bi-directionally** between the Kobo and Komga.

## Decisions (locked)

| Topic | Decision |
|-------|----------|
| Host app | KOReader plugin (`komga.koplugin`) |
| Auth | Komga REST API with `X-API-Key` header |
| Protocol | Komga **native REST API** (not OPDS) for browse, download, and progress |
| Download scope | Per subscribed series, download **unread** books only |
| Storage cleanup | Delete a local book once it is **completed AND that completion has been pushed to Komga** |
| Sync trigger | On **every WiFi connect** event (and a manual "Sync now"); startup also triggers if WiFi already up |
| Progress conflict | **Most-recent timestamp wins** when both sides changed since last sync |

## Why native REST over OPDS

OPDS can browse and download but **cannot write read-progress back** to Komga.
Bi-directional sync therefore requires the REST API regardless, so OPDS would
add a second protocol for no benefit. CBZ reading is page-based and Komga's
read-progress is `{ page, completed }` per book — a direct 1:1 mapping to
KOReader's current page.

## Components

### 1. `KomgaApi`
Thin REST client. HTTP transport is **injected** (constructor dependency) so the
module is unit-testable with a mocked transport.

Responsibilities / endpoints:
- List series: `GET /api/v1/series` (paged; `unpaged=true` where supported).
- List unread books in a series:
  `GET /api/v1/series/{seriesId}/books?read_status=UNREAD&unpaged=true`.
- Get a book (incl. `readProgress`): `GET /api/v1/books/{bookId}`.
- Download book file: `GET /api/v1/books/{bookId}/file` → original `.cbz` bytes.
- Get/Set read-progress:
  `PATCH /api/v1/books/{bookId}/read-progress` with body `{ "page": N, "completed": bool }`.
- Auth header on every request: `X-API-Key: <key>`.
- Base URL from settings; HTTPS via KOReader's bundled `ssl.https` (fallback `socket.http` for plain HTTP).

### 2. `Store` (persistent state)
Backed by `LuaSettings` (file under KOReader's settings dir, e.g.
`komga.lua`). Persists:
- `server_url`, `api_key`, `download_dir`
- `subscribed_series`: set of series IDs
- `last_sync_ts`
- `books`: manifest keyed by `bookId`, each record:
  ```
  { bookId, seriesId, seriesName, title, filePath,
    pageCount, localPage, localTs, syncedPage, syncedTs, completed }
  ```

The manifest is the source of truth for mapping a local file ↔ Komga book ID
and for detecting local vs. remote progress changes.

### 3. `ProgressTracker`
Bridges an open document ↔ its Komga book ID.
- On document **close/flush** (`onCloseDocument` / settings flush): if the open
  file is in the manifest, record its current page + timestamp into the manifest
  (`localPage`, `localTs`). Network not required — push happens at next sync.
- On **download / pull**: write the pulled Komga page into the book's `.sdr`
  sidecar so KOReader opens the book at the synced page.
- Page numbers are 1-based on both sides → direct mapping. `completed` ⇔ page at
  last page / KOReader "finished" status.

### 4. `Sync` (orchestrator)
Runs on WiFi-connect and manual trigger. Steps:

1. **Download new unread books**
   For each subscribed series → list unread books → for any book not already
   present locally, download to `<download_dir>/<SeriesName>/<Title>.cbz`
   (write to `<name>.cbz.part`, rename on success), and add a manifest record.

2. **Reconcile progress** per managed book:
   - Pull Komga `{ page, lastModified }`; read local `{ localPage, localTs }`.
   - Determine which side changed since `syncedTs`:
     - only remote changed → apply remote page to local sidecar.
     - only local changed → push local page to Komga.
     - both changed → **most-recent timestamp wins** (push or pull accordingly).
     - neither changed → no-op.
   - Update `syncedPage` / `syncedTs`.

3. **Cleanup**
   Any manifest book that is `completed` AND whose completion is reflected on
   Komga (push confirmed) → delete the local `.cbz` and its `.sdr` sidecar, and
   mark/remove the manifest record so it is not re-downloaded (it is no longer
   "unread" on Komga, so it won't reappear in step 1).

### 5. `main.lua` (plugin glue)
- Plugin lifecycle: `init`, register with KOReader.
- `addToMainMenu`: menu entries —
  - **Sync now**
  - **Manage series** (multi-select subscription list)
  - **Settings**: Server URL, API key, Download folder
- Event handlers:
  - `onNetworkConnected` → trigger `Sync`.
  - `onCloseDocument` / flush → `ProgressTracker` records local progress.

### Series selection UI
"Manage series" fetches the full series list from Komga and presents a
multi-select list (checked = subscribed). Selection persists as the
`subscribed_series` ID set in `Store`.

## Error handling

- Network/HTTP failure aborts the **current** sync gracefully with a status
  message; the manifest is left untouched so the next WiFi connect retries.
- Downloads use a `.part` temp file renamed on success → an interrupted download
  never appears complete.
- Progress is **always recorded locally first**; a failed push simply retries on
  the next sync. No progress is ever lost to a network failure.
- Cleanup only deletes after completion is confirmed pushed to Komga.

## Testing

- **Unit (busted, mocked HTTP transport):**
  - `KomgaApi` request/URL construction and response parsing.
  - Unread-book diff (what needs downloading).
  - Conflict-resolution decision (the most-recent-wins logic) across all four
    change cases.
- **Manual (on-device):** menu flows, WiFi-connect trigger, an end-to-end
  download → read → progress round-trip with Komga.

## Out of scope (YAGNI for v1)

- OPDS support.
- Keeping a buffer of finished books (delete is immediate after synced).
- Background/timed sync independent of WiFi events.
- Non-CBZ formats, reading-list/collection subscriptions, multi-server.
