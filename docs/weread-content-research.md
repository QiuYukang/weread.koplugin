# WeRead book content research

This note summarizes the current findings for a KOReader WeRead plugin. It focuses on authenticated access to a user's own readable WeRead content and intentionally avoids storing or printing book text.

For the complete endpoint reference and implementation workflow, see
`docs/weread-api-reference.md`.

For the first KOReader plugin milestone, see
`docs/weread-koreader-v1-plan.md`.

## Official skill capability

The official WeRead skill/gateway is useful for account and metadata workflows, but it does not expose full chapter content.

Useful capabilities:

- Search books.
- List shelf books.
- Fetch book metadata.
- Fetch chapter metadata/catalog.
- Read and update progress.
- Fetch notes, reviews, recommendations, and reading stats.

Missing capability:

- Full chapter body text/XHTML.

## Cookie renewal

The open-source `findmover/wxread` project keeps a Web session alive by calling:

```text
POST https://weread.qq.com/web/login/renewal
```

Typical body:

```json
{"rq":"%2Fweb%2Fbook%2Fread","ql":false}
```

If the existing session is valid, the response returns `{"succ":1}` and sends refreshed cookies, especially `wr_skey`. A KOReader plugin should keep cookies in a local cookie jar, call renewal before content requests, and persist the updated jar.

## IDs and hashes

The reader URL uses hashed IDs, for example:

```text
https://weread.qq.com/web/reader/{bookHash}k{chapterHash}
```

The formal numeric/string `bookId` can be read from the reader HTML:

- `window.__INITIAL_STATE__.reader.bookInfo.bookId`
- or the `application/ld+json` `@Id` field

WeRead's Web front end derives request IDs with `_e(value)`:

- `_e(bookId)` => `b`
- `_e(chapterUid)` => `c`
- `_e(clientTimestamp)` => `pc`

For the tested book:

```text
bookId: 43208843
_e(bookId): c9c321c07293508bc9c79df
chapterUid 2: c81322c012c81e728d9d180
chapterUid 119: 07e323f027707e1cd7dc674
```

## Catalog

The catalog endpoint is:

```text
POST https://weread.qq.com/web/book/chapterInfos
```

Body:

```json
{"bookIds":["43208843"]}
```

The response includes `bookId`, `format`, `synckey`, `copyRightSynckey`, book metadata, and `updated[]` chapters. Each chapter contains fields such as:

- `chapterUid`
- `chapterIdx`
- `title`
- `wordCount`
- `level`
- `price`
- `paid`
- optional `tar`

The `tar` URL is for chapter resources/assets, not the text body itself. It can contain images used by the chapter.

## Chapter content endpoints

Current Web reader code decodes these obfuscated paths:

```text
/web/book/chapter/e_0
/web/book/chapter/e_1
/web/book/chapter/e_2
/web/book/chapter/e_3
/web/book/chapter/t_0
/web/book/chapter/t_1
```

For EPUB-format books:

- `e_0`, `e_1`, and `e_3` are text/XHTML shards.
- `e_2` is the stylesheet shard and must be requested with `st=1`.

For text-format books, the analogous endpoints appear to be `t_0` and `t_1`, but the minimal script currently implements the EPUB path.

## Required request parameters

The content request body is JSON:

```json
{
  "b": "_e(bookId)",
  "c": "_e(chapterUid)",
  "r": "randomSquare",
  "st": 0,
  "ct": "currentUnixTimestamp",
  "ps": "psvtsFromReaderHtml",
  "pc": "_e(currentUnixTimestamp)",
  "sc": 1,
  "prevChapter": false,
  "s": "signature"
}
```

Important details:

- `ps` must come from the reader HTML: `window.__INITIAL_STATE__.reader.psvts`.
- `pc` must be `_e(ct)`. Using `0` returns `{}` for content endpoints.
- `sc=1` is required for full chapter content. `sc=0` can return a short preview ending with `...` for many paid/member-readable chapters.
- `e_2` uses the same request shape but `st=1`, and therefore a different signature.
- `s` is computed from the request body before adding `s`, using sorted keys and `encodeURIComponent(value)` joined by `&`.
- The signature hash starts with `0x15051505` and matches the Web front end's `_0x4333f2`.

## Response format and decoding

Each successful shard response has:

- first 32 characters: uppercase MD5 of the remaining body
- remaining body: encoded payload

Decoding steps:

1. Verify the MD5 prefix.
2. Drop the first 32 characters from each shard.
3. For chapter XHTML, concatenate `e_0 + e_1 + e_3`; ignore `e_2`.
4. Drop the first character from the concatenated string.
5. Compute swap positions from the tail characters.
6. Reverse the character swaps.
7. Convert Base64-url to Base64.
8. Decode and repair UTF-8 byte sequences.

For `e_2`, the same shard decoding can be applied to the single CSS response.

Verified behavior:

- Chapter 2 decoded to XHTML with title and paragraph tags.
- Chapter 119 decoded to text content.
- `e_2` decoded to CSS.

## EPUB generation strategy

The minimal script writes a local EPUB using only the Python standard library:

- `mimetype`
- `META-INF/container.xml`
- `OEBPS/content.opf`
- `OEBPS/toc.ncx`
- `OEBPS/nav.xhtml`
- one XHTML file per fetched chapter
- one shared CSS file from the decoded `e_2` shard when available

For a production KOReader plugin, the EPUB file can be replaced by an internal cache of chapter XHTML and resources, but generating EPUB is a good end-to-end validation path.

## Validation result

The minimal script was validated against the authenticated reader URL for book `43208843`.

Small sample:

```text
python3 scripts/fetch_weread_epub.py \
  --reader-url 'https://weread.qq.com/web/reader/c9c321c07293508bc9c79df' \
  --cookie-file /tmp/weread-script.cookies \
  --save-cookies /tmp/weread-script.cookies \
  --output /tmp/weread-sample.epub \
  --limit 2
```

Result:

```text
chapters: 2
output: /tmp/weread-sample.epub
bytes: 24767
```

Whole-book run:

```text
python3 scripts/fetch_weread_epub.py \
  --reader-url 'https://weread.qq.com/web/reader/c9c321c07293508bc9c79df' \
  --cookie-file /tmp/weread-script.cookies \
  --save-cookies /tmp/weread-script.cookies \
  --output /tmp/weread-full.epub
```

Result:

```text
bookId: 43208843
title: 持续交付2.0：业务引领的DevOps精要（增订本）
chapters: 134
output: /tmp/weread-full.epub
bytes: 285287
```

EPUB structure check:

```text
entries: 140
chapter xhtml files: 134
spine itemrefs: 134
nav chapter links: 134
css chars: 18490
mimetype: application/epub+zip
```

Important caveat: many chapters decode to very short text bodies while the shared CSS and `tar` resources are substantial. This strongly suggests some visual content still needs resource-package handling. The current script proves the authenticated chapter-content API and EPUB assembly path; it does not yet produce a fully polished, image-complete reading copy.

Follow-up validation fixed the caveat above:

- Using `sc=1` returns the full XHTML for chapters that were previously truncated by `sc=0`.
- Downloading `chapterInfos.updated[].tar` and rewriting `https://res.weread.qq.com/wrepub/...` image URLs into EPUB-local `OEBPS/images/...` files restores chapter images.

Updated whole-book run:

```text
output: /tmp/weread-full-with-images.epub
chapters: 134
entries: 422
images: 282
spine itemrefs: 134
manifest image items: 282
remote weread image refs: 0
bytes: 18265702
```

Spot checks:

```text
1.2 持续交付2.0: 6 local images, including 图1-6
4.3 行动原则: 2 local images, text no longer ends with ...
```

## Open work

- Add TXT-book support via `t_0` and `t_1`.
- Add throttling, retry, and resume cache.
- Decide plugin UX for cookie import/renewal and session expiration.
- Avoid bulk export by default in the KOReader UI; fetch chapters on demand and cache locally.
