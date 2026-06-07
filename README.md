# WeRead KOReader Plugin

V1 work-in-progress plugin for reading WeRead books in KOReader.

Current implementation:

- KOReader plugin metadata and main menu integration.
- `Tools -> WeRead` menu.
- Cookie/cURL import.
- Optional `config.lua` preload for API key, cURL, cookie, sync, and cache defaults.
- Cookie renewal through `POST https://weread.qq.com/web/login/renewal`.
- Official API key storage.
- Official gateway client for `/api/agent/gateway`.
- Reader URL parser that extracts `bookId`, `psvts`, `pclts`, and `token`.
- WeRead `_e()` hash, sorted-query `s` signature, Web `appId`, and `/web/book/read` payload generation.
- Confirmed manual progress upload through `/web/book/read`.

Planned next V1 steps:

- Render shelf/search results as KOReader lists instead of summary dialogs.
- Connect parsed books to a local cache record and open flow.
- Port chapter shard decoding and image tar handling from `scripts/fetch_weread_epub.py`.
- Add read-only notes/highlights screens.

Install:

```text
koreader/plugins/weread.koplugin/
  _meta.lua
  main.lua
  lib/
```

Then restart KOReader and open:

```text
Tools -> WeRead
```

Configuration file:

```text
cp config.example.lua config.lua
```

Edit `config.lua` on your computer, then copy the whole plugin folder to the
device. This is the recommended way because typing a long cURL/API key on an
e-reader is painful.

The plugin loads `config.lua` on startup. You can also reload it from:

```text
Tools -> WeRead -> Settings -> Reload config.lua
```

Safety:

- The plugin stores cookies and API key in KOReader settings.
- It does not log raw cookies, API key, or book body text.
- Manual progress upload asks for confirmation before calling `/web/book/read`.

Android logs:

- In KOReader: `Top menu -> Help -> Bug Report / Report a bug`, then save the log file.
- For better crash logs: enable verbose logging in that screen, restart KOReader, reproduce the crash, then save the bug report again.
- With ADB:

```bash
adb logcat -c
adb logcat > koreader-android.log
```

Reproduce the crash, stop `adb logcat`, then inspect or share `koreader-android.log`.
