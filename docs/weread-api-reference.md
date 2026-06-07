# WeRead API reference for KOReader plugin

This document combines two sources:

- Official WeRead skill interfaces under `/api/agent/gateway`.
- Web reader interfaces discovered from WeRead Web and validated by `scripts/fetch_weread_epub.py`.

The official skill is suitable for metadata, shelf, progress, notes, reviews, search, and stats. It does not provide full chapter body content. Full readable content requires the authenticated Web reader flow.

## 1. Authentication Models

### 1.1 Official Agent Gateway

Endpoint:

```text
POST https://i.weread.qq.com/api/agent/gateway
```

Headers:

```text
Authorization: Bearer $WEREAD_API_KEY
Content-Type: application/json
```

Body shape:

```json
{
  "api_name": "/store/search",
  "keyword": "三体",
  "count": 10,
  "skill_version": "1.0.3"
}
```

Rules:

- Every request must include `skill_version`.
- Business parameters are top-level fields, not nested under `params`.
- If a response includes `upgrade_info`, stop and follow the upgrade instruction.
- API key is user-bound; user identity is injected by the service.

### 1.2 Web Reader Session

Used for full chapter XHTML and images.

Required state:

- Valid WeRead Web cookies, especially `wr_vid`, `wr_skey`, `wr_rt`.
- Browser-like headers: `User-Agent`, `Referer`, `Origin`.

Cookie renewal endpoint:

```text
POST https://weread.qq.com/web/login/renewal
```

Body:

```json
{"rq":"%2Fweb%2Fbook%2Fread","ql":false}
```

Response:

```json
{"succ":1}
```

On success, persist the returned `Set-Cookie` values. Avoid duplicated host-only and domain cookies for the same name; stale duplicate `wr_skey` can cause `登录超时`.

## 2. Official Skill Interfaces

All endpoints below are called through:

```json
{"api_name":"<endpoint>","skill_version":"1.0.3", "...":"..."}
```

### 2.1 Search

Endpoint:

```text
/store/search
```

Parameters:

| Name | Type | Required | Notes |
|---|---|---:|---|
| `keyword` | string | yes | Search keyword |
| `scope` | int | no | Default service value is `10` |
| `maxIdx` | int | no | Pagination offset |
| `count` | int | no | Page size |

`scope` values:

| Scope | Meaning |
|---:|---|
| `0` | All results |
| `10` | E-books |
| `16` | Web novels |
| `14` | WeChat Listening/audiobooks/albums |
| `6` | Authors |
| `12` | Full-text search |
| `13` | Book lists |
| `2` | Official accounts |
| `4` | Articles |

Important response fields:

- `sid`
- `hasMore`
- `results[].title`
- `results[].scope`
- `results[].books[].searchIdx`
- `results[].books[].bookInfo.bookId`
- `results[].books[].bookInfo.title`
- `results[].books[].bookInfo.author`
- `results[].books[].bookInfo.cover`
- `results[].books[].newRating`
- `results[].books[].readingCount`

Use:

1. Search by user keyword.
2. Pick `bookId`.
3. Call `/book/info` or Web reader flow.

### 2.2 Book Metadata

Endpoint:

```text
/book/info
```

Parameters:

| Name | Type | Required |
|---|---|---:|
| `bookId` | string | yes |

Returns:

- `bookId`
- `title`
- `author`
- `translator`
- `cover`
- `intro`
- `category`
- `publisher`
- `publishTime`
- `isbn`
- `wordCount`
- `newRating`
- `newRatingCount`
- `newRatingDetail`

### 2.3 Official Chapter Catalog

Endpoint:

```text
/book/chapterinfo
```

Parameters:

| Name | Type | Required |
|---|---|---:|
| `bookId` | string | yes |

Returns:

- `bookId`
- `synckey`
- `chapterUpdateTime`
- `chapters[]`
- `chapters[].chapterUid`
- `chapters[].chapterIdx`
- `chapters[].title`
- `chapters[].wordCount`
- `chapters[].level`
- `chapters[].updateTime`
- `chapters[].price`
- `chapters[].paid`
- `chapters[].isMPChapter`
- `chapters[].anchors`

Use this for a safe metadata table of contents. For image resource `tar` URLs, use the Web catalog endpoint in section 3.3.

### 2.4 Reading Progress

Endpoint:

```text
/book/getprogress
```

Parameters:

| Name | Type | Required |
|---|---|---:|
| `bookId` | string | yes |

Returns:

- `bookId`
- `book.chapterUid`
- `book.chapterOffset`
- `book.progress`
- `book.updateTime`
- `book.recordReadingTime`
- `book.finishTime`
- `book.isStartReading`
- `timestamp`

Notes:

- `progress` is an integer from `0` to `100`.
- `1` means `1%`, not complete.
- Reading time fields are seconds.

### 2.5 Shelf

Endpoint:

```text
/shelf/sync
```

Parameters: none.

Returns:

- `books[]`
- `books[].bookId`
- `books[].title`
- `books[].author`
- `books[].cover`
- `books[].category`
- `books[].readUpdateTime`
- `books[].finishReading`
- `books[].secret`
- `albums[]`
- `albums[].albumInfo.albumId`
- `albums[].albumInfo.name`
- `albums[].albumInfo.authorName`
- `albums[].albumInfo.cover`
- `albums[].albumInfo.trackCount`
- `albums[].albumInfoExtra.secret`
- `mp`
- `archive[]`
- `bookCount`

Counting rule:

```text
shelf visible count = books.length + albums.length + (mp exists ? 1 : 0)
```

Albums are audiobooks and count as shelf entries.

### 2.6 Notes and Underlines

#### Notebook overview

Endpoint:

```text
/user/notebooks
```

Parameters:

| Name | Type | Required | Notes |
|---|---|---:|---|
| `count` | int | no | Default 20 |
| `lastSort` | int | no | Cursor from previous page's last `books[].sort` |

Returns:

- `totalBookCount`
- `totalNoteCount`
- `hasMore`
- `books[].bookId`
- `books[].book`
- `books[].reviewCount`
- `books[].noteCount`
- `books[].bookmarkCount`
- `books[].readingProgress`
- `books[].markedStatus`
- `books[].sort`

Total note count per book:

```text
reviewCount + noteCount + bookmarkCount
```

#### Single-book underlined text

Endpoint:

```text
/book/bookmarklist
```

Parameters:

| Name | Type | Required |
|---|---|---:|
| `bookId` | string | yes |

Returns underlines, not bookmark-position content:

- `updated[].bookmarkId`
- `updated[].bookId`
- `updated[].chapterUid`
- `updated[].markText`
- `updated[].createTime`
- `updated[].type`
- `updated[].range`
- `updated[].colorStyle`
- `chapters[]`
- `book`

#### Personal thoughts/reviews

Endpoint:

```text
/review/list/mine
```

Parameters:

| Name | Type | Required | Notes |
|---|---|---:|---|
| `bookid` | string | yes | Lowercase `bookid` |
| `synckey` | int | no | Cursor |
| `count` | int | no | Default 20 |

Returns:

- `reviews[]`
- `reviews[].review.reviewId`
- `reviews[].review.content`
- `reviews[].review.createTime`
- `reviews[].review.star`
- `reviews[].review.chapterName`
- `reviews[].review.isFinish`
- `totalCount`
- `hasMore`
- `synckey`

#### Chapter underline heat map

Endpoint:

```text
/book/underlines
```

Parameters:

| Name | Type | Required |
|---|---|---:|
| `bookId` | string | yes |
| `chapterUid` | int | yes |
| `synckey` | int | no |

Returns underline heat, not text:

- `underlines[].range`
- `underlines[].count`
- `underlines[].score`
- `underlines[].type`
- `synckey`

#### Popular highlights

Endpoint:

```text
/book/bestbookmarks
```

Parameters:

| Name | Type | Required | Notes |
|---|---|---:|---|
| `bookId` | string | yes | |
| `chapterUid` | int | no | `0` for all chapters |
| `synckey` | int | no | |

Returns:

- `items[].bookmarkId`
- `items[].chapterUid`
- `items[].range`
- `items[].markText`
- `items[].totalCount`
- `chapters[]`

#### Thoughts under a highlight

Endpoint:

```text
/book/readreviews
```

Parameters:

| Name | Type | Required |
|---|---|---:|
| `bookId` | string | yes |
| `chapterUid` | int | yes |
| `reviews[]` | array | yes |
| `reviews[].range` | string | yes |
| `reviews[].maxIdx` | int | no |
| `reviews[].count` | int | no |
| `reviews[].synckey` | int | no |

Returns:

- `reviews[].range`
- `reviews[].totalCount`
- `reviews[].hasMore`
- `reviews[].maxIdx`
- `reviews[].synckey`
- `reviews[].pageReviews[].review.content`
- `reviews[].pageReviews[].review.abstract`
- `reviews[].pageReviews[].review.range`

#### Single review detail

Endpoint:

```text
/review/single
```

Parameters:

| Name | Type | Required |
|---|---|---:|
| `reviewId` | string | yes |
| `commentsCount` | int | no |
| `commentsDirection` | int | no |
| `likesCount` | int | no |
| `likesDirection` | int | no |
| `synckey` | int | no |

Returns:

- `reviewId`
- `review`
- `htmlContent`
- `synckey`

### 2.7 Public Book Reviews

Endpoint:

```text
/review/list
```

Parameters:

| Name | Type | Required | Notes |
|---|---|---:|---|
| `bookId` | string | yes | |
| `reviewListType` | int | no | `0` all, `1` recommended, `2` negative, `3` latest, `4` normal |
| `count` | int | no | Default 20 |
| `maxIdx` | int | no | Pagination |
| `synckey` | int | no | Pagination |

Returns:

- `reviewsCnt`
- `recentTotalCnt`
- `reviewsHasMore`
- `friendCommentCount`
- `deepVRecommendInfo`
- `deepVRecommendValue`
- `reviews[].idx`
- `reviews[].review.review.reviewId`
- `reviews[].review.review.content`
- `reviews[].review.review.htmlContent`
- `reviews[].review.review.star`
- `reviews[].review.review.isFinish`
- `reviews[].review.review.createTime`
- `reviews[].review.review.author`

### 2.8 Reading Statistics

Endpoint:

```text
/readdata/detail
```

Parameters:

| Name | Type | Required | Notes |
|---|---|---:|---|
| `mode` | string | no | `weekly`, `monthly`, `annually`, `overall`; default `monthly` |
| `baseTime` | int | no | Unix timestamp inside target period; `overall` uses `0` |

Important response fields:

- `baseTime`
- `readTimes`
- `dailyReadTimes`
- `readDays`
- `totalReadTime`
- `dayAverageReadTime`
- `compare`
- `readLongest[]`
- `readStat[]`
- `preferCategory[]`
- `preferTime[]`
- `preferAuthor[]`
- `readRate`
- `wrReadTime`
- `wrListenTime`
- `rank`
- `yearReport`

Rules:

- Time fields are seconds.
- Use `totalReadTime` for totals.
- `dayAverageReadTime` is average over natural days, not reading days.
- Arbitrary date ranges require combining natural weekly/monthly/annual queries.

### 2.9 Recommendations

#### Personalized recommendations

Endpoint:

```text
/book/recommend
```

Parameters:

| Name | Type | Required |
|---|---|---:|
| `count` | int | no |
| `maxIdx` | int | no |

Returns:

- `books[].bookId`
- `books[].title`
- `books[].author`
- `books[].cover`
- `books[].intro`
- `books[].category`
- `books[].reason`
- `books[].readingCount`
- `books[].searchIdx`
- `books[].newRating`

#### Similar books

Endpoint:

```text
/book/similar
```

Parameters:

| Name | Type | Required |
|---|---|---:|
| `bookId` | string | yes |
| `count` | int | no |
| `maxIdx` | int | no |
| `sessionId` | string | no |

Returns:

- `booksimilar.sessionId`
- `booksimilar.books[].idx`
- `booksimilar.books[].book.bookInfo`

## 3. Web Reader Interfaces

These endpoints are not part of the official skill. They are required for actual readable chapter content.

### 3.1 Reader HTML

Endpoint:

```text
GET https://weread.qq.com/web/reader/{bookHash}
GET https://weread.qq.com/web/reader/{bookHash}k{chapterHash}
```

Where:

- `bookHash = _e(bookId)`
- `chapterHash = _e(chapterUid)`

Use:

- Read `window.__INITIAL_STATE__`.
- Extract `reader.bookInfo.bookId`.
- Extract `reader.bookInfo.title`, `reader.bookInfo.author`.
- Extract `reader.psvts` for chapter content requests.

Important:

- Fetching chapter content immediately with `pc == ps` can return `{}`. Use a current/future `ct` whose `_e(ct)` differs from `psvts`.

### 3.2 Cookie Renewal

Endpoint:

```text
POST https://weread.qq.com/web/login/renewal
```

Headers:

```text
Content-Type: application/json;charset=UTF-8
Origin: https://weread.qq.com
Referer: https://weread.qq.com/
Cookie: ...
```

Body:

```json
{"rq":"%2Fweb%2Fbook%2Fread","ql":false}
```

Use:

- Call before reader/content requests.
- Persist refreshed cookies.

### 3.3 Web Catalog With Resource URLs

Endpoint:

```text
POST https://weread.qq.com/web/book/chapterInfos
```

Body:

```json
{"bookIds":["43208843"]}
```

Important response fields:

- `data[]` or top-level book record
- `bookId`
- `format`, e.g. `epub`
- `synckey`
- `copyRightSynckey`
- `book.title`
- `updated[]`
- `updated[].chapterUid`
- `updated[].chapterIdx`
- `updated[].title`
- `updated[].wordCount`
- `updated[].level`
- `updated[].price`
- `updated[].paid`
- `updated[].files`
- `updated[].tar`

Use:

- Main TOC for content fetch.
- `tar` points to chapter resource package.
- Skip cover/zero-word entries unless handling cover resources separately.

### 3.4 Chapter Content Shards

EPUB-format endpoints:

```text
POST https://weread.qq.com/web/book/chapter/e_0
POST https://weread.qq.com/web/book/chapter/e_1
POST https://weread.qq.com/web/book/chapter/e_2
POST https://weread.qq.com/web/book/chapter/e_3
```

TXT-format endpoints found in Web code:

```text
POST https://weread.qq.com/web/book/chapter/t_0
POST https://weread.qq.com/web/book/chapter/t_1
```

TXT decoding still needs separate validation.

#### Request body

For `e_0`, `e_1`, `e_3`:

```json
{
  "b": "_e(bookId)",
  "c": "_e(chapterUid)",
  "r": "randomInt0to9999Squared",
  "ct": "currentUnixTimestamp",
  "ps": "reader.psvts",
  "pc": "_e(ct)",
  "sc": 1,
  "prevChapter": false,
  "st": 0,
  "s": "signature"
}
```

For `e_2` stylesheet:

```json
{
  "...": "...",
  "sc": 1,
  "st": 1,
  "s": "signatureForSt1"
}
```

Key discoveries:

- `sc=1` gives full chapter content.
- `sc=0` can return only a short preview ending in `...`.
- `e_2` uses `st=1`; the other shards use `st=0`.
- Sign with the request fields before adding `s`.

#### Signature string

Build sorted query:

```text
b=<encodeURIComponent(value)>&c=<...>&ct=<...>&pc=<...>&prevChapter=false&ps=<...>&r=<...>&sc=1&st=0
```

Rules:

- Sort keys lexicographically.
- Use JavaScript value spelling: `false`, not Python `False`.
- Use `encodeURIComponent` behavior.
- Do not append trailing `&`.

Then apply the Web hash:

```text
a = 0x15051505
b = a
for i from len(query)-1 down to 1 step -2:
  a = (a ^ (charCode(query[i]) << ((len(query)-i) % 30))) & 0x7fffffff
  b = (b ^ (charCode(query[i-1]) << (i % 30))) & 0x7fffffff
s = hex(a + b).lower()
```

### 3.5 Reading Progress Report

Endpoint:

```text
POST https://weread.qq.com/web/book/read
```

Use:

- Report active reading time.
- Upload the latest book/chapter progress.
- Keep WeRead Web/App progress close to KOReader local progress.

This is the endpoint from the original browser curl. The Web front end posts it
when entering a reader and while reading.

#### Request body

```json
{
  "appId": "webAppId(userAgent)",
  "b": "_e(bookId)",
  "c": "_e(chapterUid)",
  "ci": 2,
  "co": 1543,
  "sm": "first 20 chars around current position",
  "pr": 0,
  "rt": 30,
  "ts": 1780666397000,
  "rn": 123,
  "sg": "sha256(ts + rn + reader.token)",
  "ct": 1780666397,
  "ps": "reader.psvts",
  "pc": "reader.pclts or _e(ct)",
  "s": "signature"
}
```

Fields:

| Name | Meaning |
|---|---|
| `appId` | Deterministic browser app id derived from User-Agent |
| `b` | `_e(bookId)` |
| `c` | `_e(chapterUid)`; use `_e(0)` if unknown |
| `ci` | Chapter index from catalog/reader state |
| `co` | Chapter offset |
| `sm` | Short summary near current position; Web uses about 20 chars |
| `pr` | Book progress value from Web reader progress model |
| `rt` | Active reading seconds since the previous report |
| `ts` | Current client timestamp in milliseconds |
| `rn` | Random integer, usually `0..999` |
| `sg` | `sha256(str(ts) + str(rn) + reader.token)` |
| `ct` | Current Unix timestamp in seconds |
| `ps` | `window.__INITIAL_STATE__.reader.psvts` |
| `pc` | `reader.pclts`; if absent, `_e(ct)` worked for content requests and is a reasonable fallback |
| `s` | `weread_sign(sorted_query(all fields except s))` |

`appId` algorithm:

```text
prefix = concat(len(part) % 10 for first 12 User-Agent space-separated parts)
hash = 0
for char in User-Agent:
  hash = (131 * hash + charCode(char)) & 0x7fffffff
appId = "wb" + prefix + "h" + hash
```

For the tested Edge User-Agent, this reproduces:

```text
wb115321887466h529830856
```

Implementation note:

- `scripts/fetch_weread_epub.py --dump-read-payload` generates this payload without updating server state.
- `scripts/fetch_weread_epub.py --report-read` sends it to WeRead.
- Use `--report-read` only when the offset/progress comes from KOReader's actual current position.

### 3.6 `_e(value)` Hash

Used for:

- `bookHash` in reader URL.
- `chapterHash` in reader URL.
- `b` request field.
- `c` request field.
- `pc = _e(ct)`.

Algorithm summary:

1. Convert input to string.
2. Compute MD5 hex `h`.
3. Start result with first 3 chars of `h`.
4. If input is numeric:
   - split into 9-digit chunks
   - convert each chunk to hex
   - type flag is `3`
5. If input is non-numeric:
   - concatenate char code hex values
   - type flag is `4`
6. Append `type_flag + "2" + h[-2:]`.
7. For each chunk append `len(chunk)` as 2-char hex plus chunk; join chunks with `g`.
8. If result length is below 20, append leading MD5 chars to length 20.
9. Append first 3 chars of `md5(result)`.

Examples:

```text
_e("43208843") = c9c321c07293508bc9c79df
_e("2")        = c81322c012c81e728d9d180
_e("119")      = 07e323f027707e1cd7dc674
```

### 3.7 Shard Response Format

Each non-empty shard is a string:

```text
<32-char uppercase MD5><encoded body>
```

Rules:

- Verify `MD5(encodedBody).upper() == prefix`.
- `{}` means request parameters, session, entitlement, or `sc/st` are wrong.

For EPUB content:

1. Remove MD5 prefix from `e_0`, `e_1`, `e_3`.
2. Concatenate in order: `e_0 + e_1 + e_3`.
3. Drop first character.
4. Reverse WeRead's character swaps.
5. Convert Base64-url to Base64.
6. Decode bytes and repair UTF-8 sequences.
7. Result is XHTML or text-like content.

For CSS:

1. Remove MD5 prefix from `e_2`.
2. Apply the same decode routine to that single payload.
3. Result is CSS.

### 3.8 Chapter Resource Packages

Endpoint example from `chapterInfos.updated[].tar`:

```text
GET https://res.weread.qq.com/wrco/tar_43208843_36
```

Requirements:

- Send valid WeRead cookies.
- Send reader `Referer`.
- Follow redirects to Tencent COS signed URL.

Response:

- POSIX tar archive.
- Contains files such as `36/epub_43208843_44`.
- File content can be PNG/JPEG/etc. Extension may be absent.

Use:

1. Download `tar`.
2. Extract image files.
3. Detect type by magic bytes.
4. Write into EPUB, e.g. `OEBPS/images/epub_43208843_44.png`.
5. Rewrite XHTML image URLs:

```html
<img src="https://res.weread.qq.com/wrepub/epub_43208843_44" />
```

to:

```html
<img src="../images/epub_43208843_44.png" />
```

Validated:

- `1.2 持续交付2.0`: 6 local images, including `图1-6`.
- Whole book: 282 image files, 0 remaining `https://res.weread.qq.com` image refs.

## 4. End-To-End Fetch Workflow

### 4.1 From Search To EPUB

1. Search official skill:

```json
{"api_name":"/store/search","keyword":"持续交付2.0","scope":10,"skill_version":"1.0.3"}
```

2. Pick `bookId`.
3. Renew Web cookies.
4. Fetch reader HTML:

```text
GET /web/reader/{_e(bookId)}
```

5. Parse `reader.bookInfo` and `reader.psvts`.
6. Fetch Web catalog:

```json
{"bookIds":["<bookId>"]}
```

7. For each chapter with `wordCount > 0`:
   - Fetch chapter reader HTML with `bookHash + "k" + chapterHash`.
   - Parse fresh `psvts`.
   - Fetch `e_0`, `e_1`, `e_3` with `sc=1`, `st=0`.
   - Fetch `e_2` with `sc=1`, `st=1`.
   - Decode XHTML and CSS.
   - Download `tar` if present.
   - Rewrite images.
   - Store chapter XHTML and assets.
8. Build EPUB or KOReader cache.

### 4.2 KOReader Plugin Strategy

Recommended plugin behavior:

- Use official gateway for search, shelf, metadata, progress, notes, and reviews.
- Use Web reader flow only when opening/downloading readable content.
- Fetch chapters on demand and cache locally.
- Cache per book:
  - catalog JSON
  - per-chapter XHTML
  - shared CSS
  - extracted images
  - cookie/session timestamp
- Refresh cookies with `/web/login/renewal` before content fetch.
- Avoid default bulk export in UI; make it an explicit user action.

### 4.3 Minimal Script Usage

Sample:

```bash
python3 scripts/fetch_weread_epub.py \
  --reader-url 'https://weread.qq.com/web/reader/c9c321c07293508bc9c79df' \
  --cookie-file /tmp/weread-script.cookies \
  --save-cookies /tmp/weread-script.cookies \
  --output /tmp/weread-full-with-images.epub
```

Useful options:

| Option | Meaning |
|---|---|
| `--reader-url` | Reader URL for target book |
| `--book-id` | Formal bookId, if known |
| `--cookie-file` | Netscape/Mozilla cookie jar |
| `--cookie-string` | Raw Cookie header |
| `--save-cookies` | Persist renewed cookies |
| `--limit` | Fetch first N readable chapters |
| `--skip` | Skip first N readable chapters |
| `--sleep` | Delay between shard requests |
| `--no-renew` | Skip renewal |

Validated output:

```text
/tmp/weread-full-with-images.epub
chapters: 134
images: 282
bytes: 18265702
```

## 5. Error Handling

### `{"errCode": -2012, "errMsg": "登录超时"}`

Meaning:

- Expired or conflicting Web cookies.

Fix:

- Call `/web/login/renewal`.
- Persist returned cookies.
- Remove stale duplicate `wr_skey`/`wr_rt` values.

### `{"errCode": -2010, "errMsg": "用户不存在"}`

Meaning:

- Request effectively unauthenticated.

Fix:

- Check cookie jar has WeRead cookies.
- Check cookie domain is `.weread.qq.com`.

### Content endpoint returns `{}`

Likely causes:

- Wrong signature.
- Python/other language encoded boolean as `False` instead of JS `false`.
- `pc` missing or equals stale value.
- `sc=0` instead of `sc=1`.
- `e_2` requested with `st=0` instead of `st=1`.
- Session lacks entitlement for the chapter.
- Cookie expired.

### Images show blank placeholders

Cause:

- XHTML still points to `https://res.weread.qq.com/wrepub/...`, but EPUB reader cannot fetch authenticated remote resources.

Fix:

- Download `chapter.tar`.
- Extract image files.
- Add them to EPUB manifest.
- Rewrite `img src` to local relative paths.

## 6. Known Gaps

- TXT book flow via `t_0`/`t_1` has not been fully validated.
- Audio/albums are official skill metadata only; no content download flow is documented here.
- Some WeRead frontend algorithms may change; keep the code modular and easy to update.
- Use this only for user-authenticated, user-readable content. Do not expose a bulk export flow by default.
