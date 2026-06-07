# KOReader WeRead Plugin V1 Plan

V1 should be a practical reader integration rather than a full WeRead clone.
The core promise is:

- browse/search WeRead books the user can read;
- open a book in KOReader with text, CSS, and images intact;
- cache chapters locally;
- keep reading progress approximately synced back to WeRead.

## 1. V1 Scope

### Must have

1. Authentication/session
   - Import Web cookie string or cookie jar.
   - Persist cookies locally.
   - Renew cookies through `/web/login/renewal`.
   - Detect login timeout and show a re-login/import prompt.

2. Discovery and metadata
   - Use the official gateway for shelf, search, book metadata, and chapter metadata when `WEREAD_API_KEY` is available.
   - Use Web reader/catalog endpoints as the fallback for a known reader URL/book id.

3. Content reading
   - Fetch reader HTML and parse `window.__INITIAL_STATE__`.
   - Fetch chapter catalog through `/web/book/chapterInfos`.
   - Fetch EPUB-format chapter shards through `/web/book/chapter/e_0`, `e_1`, `e_2`, `e_3`.
   - Decode XHTML/CSS.
   - Download `chapter.tar` resources and rewrite image URLs to local files.
   - Cache chapter XHTML/CSS/images under the plugin data directory.

4. Progress
   - Read initial server progress from the official gateway when available.
   - Convert server progress into KOReader starting location.
   - Convert KOReader current location back into WeRead fields: `chapterUid`, `chapterIdx`, `chapterOffset`, `progress`, `summary`.
   - Report progress and active reading time through `/web/book/read`.

5. Safety
   - Never print book body text to logs.
   - Rate-limit chapter fetches.
   - Only download a whole book after explicit user action.

### Nice to have in V1

- Read-only notes/highlights list using official skill endpoints.
- Manual "sync now" action.
- Per-book cache cleanup.
- EPUB export for debugging, hidden behind a developer option.

### Defer beyond V1

- Bidirectional highlight/note write-back.
- Review creation/editing.
- Full-text search inside remote WeRead content.
- TXT-format book decoding through `t_0`/`t_1`.
- WeRead AI endpoints.
- Social/discovery feeds.

## 2. Interface Map

| Capability | Preferred Interface | Fallback/Notes |
|---|---|---|
| Search | Official `/store/search` | None needed |
| Shelf | Official shelf endpoints | Web discovery later |
| Book metadata | Official book endpoints | Reader HTML `bookInfo` |
| Chapter metadata | Official book/chapter endpoints | `/web/book/chapterInfos` |
| Chapter body | Web `e_0/e_1/e_3` | Official skill does not expose body |
| CSS | Web `e_2` | `st=1` |
| Images | `chapterInfos.updated[].tar` | Rewrite remote `wrepub` URLs locally |
| Cookie refresh | `/web/login/renewal` | Required for Web content |
| Initial progress | Official `/book/getprogress` | Reader `progress` object |
| Progress upload | `/web/book/read` | Requires `token`, `psvts`, signatures |
| Notes/highlights read | Official `/user/notebooks`, `/book/bookmarklist`, `/review/list/mine` | Good V1 optional |
| Notes/highlights write | Unknown/not selected for V1 | Explore after core reader works |

## 3. Data Model

Plugin state should store:

- account/session:
  - cookie jar;
  - last renewal time;
  - last login error.
- per book:
  - `bookId`, `bookHash`, title, author, cover;
  - catalog JSON and `synckey`;
  - local chapter cache status;
  - image/resource cache status.
- per chapter:
  - `chapterUid`, `chapterIdx`, title, word count;
  - local XHTML path;
  - local CSS path or shared CSS reference;
  - local image/resource paths.
- progress:
  - KOReader document location;
  - WeRead `chapterUid`;
  - `chapterIdx`;
  - `chapterOffset`;
  - `progress`;
  - short `summary`;
  - last uploaded timestamp;
  - accumulated active reading seconds.

## 4. Progress Strategy

KOReader and WeRead do not expose exactly the same location model. V1 should use
a pragmatic mapping:

1. When opening a book:
   - fetch server progress;
   - locate matching chapter by `chapterUid`/`chapterIdx`;
   - map `chapterOffset` to an approximate text offset in the decoded XHTML;
   - open KOReader near that location.

2. While reading:
   - track current chapter file and KOReader page/location;
   - estimate `chapterOffset` from text position in the chapter;
   - compute book `progress` from chapter index plus in-chapter percentage;
   - keep a 20-character `summary` near the current text position.

3. When reporting:
   - generate `/web/book/read` payload;
   - include active reading seconds as `rt`;
   - upload on close, suspend, manual sync, and periodic interval;
   - suppress upload if the position did not move.

4. Conflict handling:
   - if remote progress is newer than local, ask before jumping;
   - if local progress is newer, upload local progress;
   - keep the local location authoritative during one KOReader session.

Official `/book/getprogress` returns:

- `book.chapterUid`
- `book.chapterOffset`
- `book.progress`
- reading-time fields
- `book.finishTime` only when finished

The official skill defines `book.progress` as an integer percent `0..100`.
The Web reader `/web/book/read` examples also accept progress values in the same
conceptual range, so V1 should keep an integer percent unless direct Web state
for the same book proves otherwise.

## 5. Annotation Strategy

V1 should treat WeRead annotations as read-only import/reference data:

- `/user/notebooks`: notebook overview for books with notes.
- `/book/bookmarklist`: personal highlight text for one book. It filters out
  pure bookmarks, so it is not a bookmark-position export.
- `/review/list/mine`: personal thoughts/reviews for one book.
- `/book/underlines`: per-chapter highlight heat statistics, no text.
- `/book/bestbookmarks`: popular highlights.
- `/book/readreviews`: thoughts under a highlight range.

KOReader local highlights can be stored locally in V1. WeRead write-back should
wait until a reliable create/update/delete annotation API is discovered and
validated.

## 6. First Implementation Milestones

1. Plugin shell
   - KOReader menu entry.
   - Settings screen for cookie/API key.
   - Basic session renewal check.

2. Book list
   - Shelf/search via official gateway.
   - Open by pasted WeRead reader URL as a developer fallback.

3. Reader cache
   - Fetch catalog.
   - Fetch one chapter on demand.
   - Fetch images from tar.
   - Render as local EPUB/document source for KOReader.

4. Whole-book cache
   - Background chapter fetch queue.
   - Progress UI.
   - Retry failed chapters.

5. Progress sync
   - Read initial progress.
   - Generate `/web/book/read` payload.
   - Upload progress on explicit "sync now".
   - Add automatic upload once manual sync is stable.

6. Read-only annotations
   - List highlights/notes from official endpoints.
   - Show them in a plugin panel or import as local KOReader highlights.

## 7. Open Questions

- `reader.pclts` is used by Web for `/web/book/read`; if missing, `_e(ct)` is
  the current fallback. This should be verified across multiple books/sessions.
- Annotation write-back needs more exploration. It is not required for V1.
- TXT-format books need separate decoding validation before claiming support.
