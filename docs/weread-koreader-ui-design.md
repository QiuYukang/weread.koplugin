# KOReader WeRead Plugin V1 UI Design

This is the proposed V1 interaction design. It intentionally uses KOReader-like
menus, lists, dialogs, and small status surfaces so it works well on e-ink,
touch, and key-based devices.

## 1. Design Goals

- Open WeRead books in KOReader with as little ceremony as possible.
- Make account/session state visible without being noisy.
- Keep expensive actions explicit: whole-book download, sync all, clear cache.
- Make progress sync understandable and reversible.
- Avoid feature sprawl in V1; annotations are read-only unless a reliable write
  API is later confirmed.

## 2. Entry Points

### File Manager Main Menu

Menu path:

```text
Tools -> WeRead
```

Items:

| Item | Action |
|---|---|
| `Bookshelf` | Open WeRead shelf |
| `Search` | Search WeRead |
| `Paste reader URL` | Open a known WeRead reader URL |
| `Downloads` | Show cached/downloading books |
| `Sync` | Open sync status and manual sync |
| `Settings` | Account, API key, cookie, cache, behavior |

### Reader Menu

When reading a WeRead-backed local document:

```text
Tools -> WeRead
```

Items:

| Item | Action |
|---|---|
| `Sync progress now` | Upload current KOReader position through `/web/book/read` |
| `Show remote progress` | Compare local and WeRead server progress |
| `Book details` | Metadata, cache status, source link |
| `Notes` | Read-only WeRead highlights/thoughts for this book |
| `Download remaining chapters` | Continue background cache |
| `Cache settings` | Per-book cache cleanup |

## 3. First-Run Flow

### Screen: Welcome

Purpose: explain only the required setup choices.

Actions:

- `Import cookie`
- `Set WeRead API key`
- `Open settings`
- `Later`

Recommended copy:

```text
WeRead needs a Web cookie for book content.
The official API key is optional but recommended for shelf, search, progress,
and notes.
```

### Dialog: Import Cookie

Fields/actions:

- Paste raw `Cookie` header.
- Paste full `curl` command.
- Test login.
- Save.

Validation:

- Must contain at least `wr_skey`.
- Warn if `wr_vid` or `wr_rt` is missing.
- Run `/web/login/renewal`.
- Persist renewed cookies.

### Dialog: API Key

Fields/actions:

- Paste `WEREAD_API_KEY`.
- Test `/user/notebooks` or a light gateway call.
- Save.
- Skip.

Behavior:

- If no API key, content still works from reader URL/cookie path.
- Shelf/search/progress/notes may be limited or use Web fallbacks.

## 4. Bookshelf

List layout:

```text
Title
Author · progress% · updated date
Cache: none / partial / ready
```

Top actions:

- `Refresh`
- `Search`
- `Filter`

Item actions:

| Action | Meaning |
|---|---|
| `Open` | Open cached book or fetch first chapter |
| `Download` | Cache all chapters and images |
| `Details` | Show metadata and sync/cache state |
| `Sync progress` | Pull server progress and compare with local |
| `Remove cache` | Delete local chapter/assets only |

Empty states:

- Not logged in: show `Import cookie`.
- No API key: show `Paste reader URL` and `Set API key`.
- Network error: show retry and last successful refresh time.

## 5. Search

Screen:

- Search input dialog.
- Results list with title, author, category, reading count if available.

Result actions:

- `Open`
- `Download`
- `Book details`
- `Add to shelf` only if an official/write-capable API is later confirmed.

V1 should not pretend to add books to shelf unless that endpoint is validated.

## 6. Paste Reader URL

Purpose: developer and fallback path when official API key is absent.

Input examples:

```text
https://weread.qq.com/web/reader/{bookHash}
https://weread.qq.com/web/reader/{bookHash}k{chapterHash}
```

Flow:

1. Parse reader URL.
2. Fetch reader HTML.
3. Extract `bookId`, title, author, `psvts`, `pclts`, `token`.
4. Fetch `/web/book/chapterInfos`.
5. Show book details with `Open` and `Download`.

## 7. Book Details

Sections:

- Metadata: title, author, category, word count if available.
- Remote progress: chapter, percent, read time.
- Local progress: KOReader current location.
- Cache: chapters ready, images ready, failed chapters.
- Session: cookie valid/expired, last renewal.

Actions:

- `Open`
- `Download all`
- `Sync progress now`
- `Pull remote progress`
- `Notes`
- `Clear cache`

## 8. Reading Progress Sync

### Manual Sync Dialog

Shown after `Sync progress now`:

```text
Local position
Chapter: 4.3 Action Principles
Progress: 65%

Remote position
Chapter: 4.1 ...
Progress: 58%

Action
[Upload local] [Use remote] [Cancel]
```

Rules:

- If local moved since last upload, default to `Upload local`.
- If remote is newer than the current KOReader session, ask before jumping.
- If positions are nearly identical, show a small success message and do nothing.

### Automatic Sync

Setting:

| Option | Default |
|---|---|
| On book close | on |
| Every N minutes | off in V1, user can enable |
| On suspend | on if KOReader event is available |
| Upload only when moved | on |

Status message:

```text
WeRead progress synced
```

Error message:

```text
Sync failed: login expired
[Renew cookie] [Settings]
```

## 9. Downloads

List layout:

```text
Book title
42 / 134 chapters · 96 images · last error if any
```

Actions:

- `Resume`
- `Pause`
- `Retry failed`
- `Open available`
- `Clear`

Download behavior:

- On-demand chapter fetch is the default.
- Whole-book download requires explicit confirmation.
- Rate-limit requests and show progress.

## 10. Notes

V1 mode: read-only.

Tabs or menu sections:

- Highlights from `/book/bookmarklist`.
- My thoughts from `/review/list/mine`.
- Popular highlights from `/book/bestbookmarks` if enabled.

Actions:

- `Jump to chapter` when `chapterUid` exists.
- `Import to KOReader notes` can be considered after location mapping is stable.

No V1 action:

- Create WeRead highlight.
- Edit WeRead thought.
- Delete WeRead note.

## 11. Settings

Sections:

### Account

- Cookie status.
- Import cookie/curl.
- Renew now.
- Clear account data.

### Official API

- API key status.
- Set/update API key.
- Test API.

### Sync

- Pull remote progress on open: on.
- Ask before remote jump: on.
- Upload on close: on.
- Upload interval: off / 5 / 10 / 15 / 30 minutes.
- Prefer local/remote on conflict: ask by default.

### Cache

- Cache directory.
- Max cache size.
- Download images: on.
- Clear failed downloads.
- Clear all WeRead cache.

### Advanced

- Paste reader URL.
- Dump `/web/book/read` payload for debugging.
- Developer logs: off by default.

## 12. Error States

| Error | User-facing action |
|---|---|
| Login expired | Renew cookie, then ask to re-import if renewal fails |
| No entitlement | Explain the chapter cannot be read by this account |
| Empty shard response | Retry once, renew cookie, then show diagnostic |
| Image package missing | Continue text reading, mark images incomplete |
| Progress upload failed | Keep local progress and retry later |
| API key missing | Offer cookie/reader URL fallback |

## 13. V1 Acceptance Criteria

- A first-time user can import cookie/curl and validate login.
- A user with API key can browse shelf and search.
- A user can paste a reader URL and open that book without API key.
- A chapter opens with text, CSS, and images.
- Whole-book cache can be started, paused, resumed, and retried.
- Local progress can be uploaded through `/web/book/read`.
- Remote progress can be read through `/book/getprogress` when API key exists.
- Notes can be viewed read-only for a book.
- No screen logs raw cookie, API key, or book body text.
