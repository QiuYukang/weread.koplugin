local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("logger")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template

local Cookie = require("lib.cookie")
local Client = require("lib.client")
local Content = require("lib.content")
local I18n = require("lib.i18n")
local Settings = require("lib.settings")
local WeRead = require("lib.weread")

local function _(text)
    return I18n.tr(text)
end

local WeReadPlugin = WidgetContainer:extend{
    name = "weread",
    is_doc_only = false,
}

local function plugin_dir()
    local source = debug.getinfo(1, "S").source or ""
    local path = source:match("^@(.+)$") or source
    return path:match("^(.*)/[^/]+$") or "."
end

function WeReadPlugin:init()
    math.randomseed(os.time())
    self.plugin_dir = plugin_dir()
    self.settings = Settings:new()
    self.client = Client:new(self.settings)
    self:loadConfigFile()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function WeReadPlugin:loadConfigFile()
    local config_path = (self.plugin_dir or plugin_dir()) .. "/config.lua"
    local file = io.open(config_path, "r")
    if not file then
        return
    end
    file:close()

    local ok, config = pcall(dofile, config_path)
    if not ok then
        self._config_error = tostring(config)
        return
    end
    local applied, err = self.settings:apply_config(config)
    if not applied then
        self._config_error = err
        return
    end

    local raw_cookie = ""
    local curl_payload
    if type(config.curl) == "string" and config.curl:match("%S") then
        raw_cookie, curl_payload = Cookie.extract_from_curl(config.curl)
    elseif type(config.cookie) == "string" and config.cookie:match("%S") then
        raw_cookie = config.cookie
    end

    if raw_cookie and raw_cookie:match("%S") then
        local cookies = Cookie.parse_cookie_header(raw_cookie)
        if Cookie.has_login_cookie(cookies) then
            self.settings:set("cookies", cookies)
        end
    end

    if curl_payload and curl_payload ~= "" then
        local parsed_ok, payload = pcall(function()
            return self.client:json_decode(curl_payload)
        end)
        if parsed_ok and type(payload) == "table" then
            self.settings:set("curl_payload", payload)
        end
    end
    self.settings:flush()
end

function WeReadPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("weread_show", {
        category = "none",
        event = "ShowWeRead",
        title = _("WeRead"),
        filemanager = true,
        reader = true,
    })
    Dispatcher:registerAction("weread_sync_progress", {
        category = "none",
        event = "WeReadSyncProgress",
        title = _("Sync WeRead progress"),
        reader = true,
    })
end

function WeReadPlugin:addToMainMenu(menu_items)
    menu_items.weread = {
        text = _("WeRead"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getMainMenuItems()
        end,
    }
end

function WeReadPlugin:safeCallback(label, callback)
    return function()
        logger.info("WeRead: action start:", label)
        local ok, err = xpcall(callback, debug.traceback)
        if not ok then
            self:closeBusy()
            logger.err("WeRead: action failed:", label, err)
            self:showInfo(T(_("%1 failed:\n%2"), label, tostring(err)))
        else
            logger.info("WeRead: action done:", label)
        end
    end
end

function WeReadPlugin:getMainMenuItems()
    local items = {
        {
            text = _("Bookshelf"),
            callback = self:safeCallback(_("Bookshelf"), function()
                self:showBookshelf()
            end),
        },
        {
            text = _("Search"),
            callback = self:safeCallback(_("Search"), function()
                self:showSearch()
            end),
        },
        {
            text = _("Paste reader URL"),
            callback = self:safeCallback(_("Paste reader URL"), function()
                self:showPasteReaderURL()
            end),
        },
        {
            text = _("Downloads"),
            callback = self:safeCallback(_("Downloads"), function()
                self:showDownloads()
            end),
        },
        {
            text = _("Sync"),
            callback = self:safeCallback(_("Sync"), function()
                self:showSyncStatus()
            end),
        },
        {
            text = _("Settings"),
            sub_item_table_func = function()
                return self:getSettingsMenuItems()
            end,
        },
    }

    if self.ui.document then
        table.insert(items, 1, {
            text = _("Sync progress now"),
            callback = self:safeCallback(_("Sync progress now"), function()
                self:onWeReadSyncProgress()
            end),
        })
        table.insert(items, 2, {
            text = _("Book details"),
            callback = self:safeCallback(_("Book details"), function()
                self:showCurrentBookDetails()
            end),
        })
        table.insert(items, 3, {
            text = _("Notes"),
            callback = self:safeCallback(_("Notes"), function()
                self:showNotes()
            end),
        })
    end

    return items
end

function WeReadPlugin:getSettingsMenuItems()
    return {
        {
            text = _("Import cookie/cURL"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Import cookie/cURL"), function()
                self:showImportCookieDialog()
            end),
        },
        {
            text = _("Reload config.lua"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Reload config.lua"), function()
                self:loadConfigFile()
                if self._config_error then
                    self:showInfo(T(_("config.lua error:\n%1"), self._config_error))
                else
                    self:showInfo(_("config.lua loaded."))
                end
            end),
        },
        {
            text = _("Set official API key"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Set official API key"), function()
                self:showApiKeyDialog()
            end),
        },
        {
            text = _("Renew cookie now"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Renew cookie now"), function()
                self:renewCookieWithUI()
            end),
        },
        {
            text = _("Pull progress on open"),
            checked_func = function()
                return self.settings:get("sync").pull_on_open
            end,
            callback = self:safeCallback(_("Pull progress on open"), function()
                self:toggleSyncSetting("pull_on_open")
            end),
        },
        {
            text = _("Upload progress on close"),
            checked_func = function()
                return self.settings:get("sync").upload_on_close
            end,
            callback = self:safeCallback(_("Upload progress on close"), function()
                self:toggleSyncSetting("upload_on_close")
            end),
        },
        {
            text = _("Download chapter images"),
            checked_func = function()
                return self.settings:get("cache").download_images
            end,
            callback = self:safeCallback(_("Download chapter images"), function()
                local cache = self.settings:get("cache")
                cache.download_images = not cache.download_images
                self.settings:set("cache", cache)
                self.settings:flush()
            end),
        },
        {
            text = _("Account status"),
            callback = self:safeCallback(_("Account status"), function()
                self:showAccountStatus()
            end),
        },
        {
            text = _("Clear account data"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Clear account data"), function()
                self:confirmClearAccount()
            end),
        },
    }
end

function WeReadPlugin:showInfo(text)
    UIManager:show(InfoMessage:new{
        text = text,
    })
end

function WeReadPlugin:showTransientInfo(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 2,
    })
end

function WeReadPlugin:showBusy(text)
    self:closeBusy()
    self.busy_message = InfoMessage:new{
        text = text,
        dismissable = false,
    }
    UIManager:show(self.busy_message)
    self:refreshUI()
end

function WeReadPlugin:closeBusy()
    if self.busy_message then
        UIManager:close(self.busy_message)
        self.busy_message = nil
        self:refreshUI()
    end
end

function WeReadPlugin:refreshUI()
    if UIManager.forceRePaint then
        local ok, err = pcall(function()
            UIManager:forceRePaint()
        end)
        if not ok then
            logger.warn("WeRead: forceRePaint failed:", err)
        end
    end
end

function WeReadPlugin:showInputDialog(dialog)
    UIManager:show(dialog)
    if dialog.onShowKeyboard then
        local ok, err = pcall(function()
            dialog:onShowKeyboard()
        end)
        if not ok then
            logger.warn("WeRead: failed to show keyboard:", err)
        end
    end
end

function WeReadPlugin:runNetworkAction(label, action)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local ok, result = pcall(action)
        if ok then
            self:showInfo(result or label)
        else
            self:showInfo(T(_("%1 failed:\n%2"), label, tostring(result)))
        end
    end)
end

function WeReadPlugin:showList(title, items, empty_text)
    if not items or #items == 0 then
        self:showInfo(empty_text or _("No items."))
        return
    end
    UIManager:show(Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        title_bar_fm_style = true,
    })
end

function WeReadPlugin:showImportCookieDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Import WeRead cookie or cURL"),
        input = "",
        input_type = "text",
        description = _("Paste a raw Cookie header or a full cURL copied from /web/book/read."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Save"), function()
                        local input = dialog:getInputText()
                        local cookie_header, curl_data = Cookie.extract_from_curl(input)
                        local cookies = Cookie.parse_cookie_header(cookie_header)
                        if not Cookie.has_login_cookie(cookies) then
                            self:showInfo(_("Could not find a valid wr_skey cookie."))
                            return
                        end
                        self.settings:set("cookies", cookies)
                        if curl_data and curl_data ~= "" then
                            local ok, payload = pcall(function()
                                return self.client:json_decode(curl_data)
                            end)
                            if ok and type(payload) == "table" then
                                self.settings:set("curl_payload", payload)
                            end
                        end
                        self.settings:flush()
                        UIManager:close(dialog)
                        self:renewCookieWithUI()
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function WeReadPlugin:showApiKeyDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Set WeRead API key"),
        input = self.settings:get("api_key", ""),
        input_type = "text",
        description = _("Used for shelf, search, progress, and notes through the official gateway."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Save"), function()
                        self.settings:set("api_key", dialog:getInputText())
                        self.settings:flush()
                        UIManager:close(dialog)
                        self:showInfo(_("API key saved."))
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function WeReadPlugin:renewCookieWithUI()
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Cookie is not configured."))
        return
    end
    self:runNetworkAction(_("Renew cookie"), function()
        local result = self.client:renew_cookie()
        if result and result.succ then
            return _("WeRead cookie renewed.")
        end
        return _("Cookie renewal completed, but response did not include succ=1.")
    end)
end

function WeReadPlugin:showAccountStatus()
    local cookie_status = self.settings:is_cookie_configured() and _("configured") or _("missing")
    local api_status = self.settings:is_api_configured() and _("configured") or _("missing")
    self:showInfo(T(_("Cookie: %1\nOfficial API key: %2\nCache directory:\n%3"), cookie_status, api_status, BD.dirpath(self.settings.cache_dir)))
end

function WeReadPlugin:confirmClearAccount()
    UIManager:show(ConfirmBox:new{
        text = _("Clear WeRead cookie and API key? Cached books will remain."),
        ok_text = _("Clear"),
        ok_callback = self:safeCallback(_("Clear"), function()
            self.settings:reset_account()
            self:showInfo(_("WeRead account data cleared."))
        end),
    })
end

function WeReadPlugin:toggleSyncSetting(key)
    local sync = self.settings:get("sync")
    sync[key] = not sync[key]
    self.settings:set("sync", sync)
    self.settings:flush()
end

function WeReadPlugin:showBookshelf()
    if not self.settings:is_api_configured() then
        self:showInfo(_("Set the official API key to browse your WeRead shelf. You can still open a book by pasting a reader URL."))
        return
    end
    self:showBusy(_("Loading bookshelf..."))
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local ok, result = pcall(function()
            return self.client:gateway("/shelf/sync", {})
        end)
        if not ok then
            self:closeBusy()
            self:showInfo(T(_("Load bookshelf failed:\n%1"), tostring(result)))
            return
        end
        self.shelf_books = result.books or {}
        self:closeBusy()
        self:showShelfPage(1)
    end)
end

function WeReadPlugin:showShelfPage(page)
    local books = self.shelf_books or {}
    local page_size = 20
    local total = #books
    local total_pages = math.max(1, math.ceil(total / page_size))
    page = math.max(1, math.min(page or 1, total_pages))

    local start_index = (page - 1) * page_size + 1
    local end_index = math.min(total, start_index + page_size - 1)
    local items = {}

    if page > 1 then
        table.insert(items, {
            text = _("Previous page"),
            post_text = T(_("%1 / %2"), tostring(page - 1), tostring(total_pages)),
            callback = self:safeCallback(_("Previous page"), function()
                self:showShelfPage(page - 1)
            end),
        })
    end

    for book_index = start_index, end_index do
        local book = books[book_index]
        if book then
            table.insert(items, {
                text = book.title or book.bookId or _("Untitled"),
                mandatory = book.finishReading == 1 and _("Done") or "",
                post_text = book.author or "",
                callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                    self:showBookRecord(book)
                end),
            })
        end
    end

    if page < total_pages then
        table.insert(items, {
            text = _("Next page"),
            post_text = T(_("%1 / %2"), tostring(page + 1), tostring(total_pages)),
            callback = self:safeCallback(_("Next page"), function()
                self:showShelfPage(page + 1)
            end),
        })
    end

    self:showList(
        T(_("WeRead Bookshelf (%1-%2 / %3)"), tostring(start_index), tostring(end_index), tostring(total)),
        items,
        _("Your WeRead shelf is empty.")
    )
end

function WeReadPlugin:showBookRecord(book)
    local books = self.settings:get("books", {})
    local book_id = book.book_id or book.bookId
    if book_id then
        books[book_id] = books[book_id] or {}
        books[book_id].book_id = book_id
        books[book_id].title = book.title
        books[book_id].author = book.author
        books[book_id].cover = book.cover
        books[book_id].updated_at = os.time()
        self.settings:set("books", books)
        self.settings:flush()
    end
    self:showBookMenu(books[book_id] or book)
end

function WeReadPlugin:showBookMenu(book)
    local book_id = book.book_id or book.bookId
    local items = {
        {
            text = _("Chapter list"),
            post_text = book.chapters and T(_("%1 chapters"), tostring(#book.chapters)) or _("Not loaded"),
            callback = self:safeCallback(_("Chapter list"), function()
                self:showChapterList(book, 1)
            end),
        },
        {
            text = _("Open cached book"),
            post_text = book.cached_file or _("Not cached"),
            callback = self:safeCallback(_("Open cached book"), function()
                self:openCachedBook(book)
            end),
        },
        {
            text = _("Download first chapter and read"),
            post_text = _("MVP"),
            callback = self:safeCallback(_("Download first chapter and read"), function()
                self:downloadFirstChapterAndRead(book)
            end),
        },
        {
            text = _("Download first 5 chapters"),
            post_text = _("Batch"),
            callback = self:safeCallback(_("Download first 5 chapters"), function()
                self:downloadFirstNChapters(book, 5)
            end),
        },
        {
            text = _("Download full book"),
            post_text = _("EPUB"),
            callback = self:safeCallback(_("Download full book"), function()
                self:confirmDownloadAllChapters(book)
            end),
        },
        {
            text = _("Get progress"),
            callback = self:safeCallback(_("Get progress"), function()
                if book_id then
                    self:pullProgressWithUI(book_id)
                end
            end),
        },
        {
            text = _("Cache status"),
            callback = self:safeCallback(_("Cache status"), function()
                self:showInfo(T(_("Cached file:\n%1"), book.cached_file or _("Not cached")))
            end),
        },
    }
    self:showList(book.title or _("Book details"), items, _("No actions."))
end

function WeReadPlugin:loadChapters(book, callback)
    if book.chapters and #book.chapters > 0 then
        callback(book.chapters)
        return
    end
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before loading chapters."))
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        self:showBusy(_("Loading chapter list..."))
        local ok, chapters_or_err = pcall(function()
            Content.ensure_reader_state(self.client, book)
            return Content.fetch_catalog(self.client, book)
        end)
        self:closeBusy()
        if not ok then
            self:showInfo(T(_("Load chapters failed:\n%1"), tostring(chapters_or_err)))
            return
        end
        local books = self.settings:get("books", {})
        local book_id = book.book_id or book.bookId
        if book_id then
            books[book_id] = book
            self.settings:set("books", books)
            self.settings:flush()
        end
        callback(chapters_or_err)
    end)
end

function WeReadPlugin:showChapterList(book, page)
    self:loadChapters(book, function(chapters)
        local page_size = 25
        local total = #chapters
        local total_pages = math.max(1, math.ceil(total / page_size))
        page = math.max(1, math.min(page or 1, total_pages))
        local start_index = (page - 1) * page_size + 1
        local end_index = math.min(total, start_index + page_size - 1)
        local items = {}

        if page > 1 then
            table.insert(items, {
                text = _("Previous page"),
                post_text = T(_("%1 / %2"), tostring(page - 1), tostring(total_pages)),
                callback = self:safeCallback(_("Previous page"), function()
                    self:showChapterList(book, page - 1)
                end),
            })
        end

        for chapter_index = start_index, end_index do
            local chapter = chapters[chapter_index]
            if chapter then
                local cached = book.cached_chapters and book.cached_chapters[tostring(chapter.chapterUid)]
                table.insert(items, {
                    text = chapter.title or T(_("Chapter %1"), tostring(chapter.chapterUid)),
                    post_text = cached and _("Cached") or T(_("%1 words"), tostring(chapter.wordCount or 0)),
                    callback = self:safeCallback(chapter.title or _("Chapter"), function()
                        self:showChapterMenu(book, chapter)
                    end),
                })
            end
        end

        if page < total_pages then
            table.insert(items, {
                text = _("Next page"),
                post_text = T(_("%1 / %2"), tostring(page + 1), tostring(total_pages)),
                callback = self:safeCallback(_("Next page"), function()
                    self:showChapterList(book, page + 1)
                end),
            })
        end

        self:showList(
            T(_("Chapters (%1-%2 / %3)"), tostring(start_index), tostring(end_index), tostring(total)),
            items,
            _("No chapters.")
        )
    end)
end

function WeReadPlugin:showChapterMenu(book, chapter)
    local cached = book.cached_chapters and book.cached_chapters[tostring(chapter.chapterUid)]
    local items = {
        {
            text = _("Open cached chapter"),
            post_text = cached or _("Not cached"),
            callback = self:safeCallback(_("Open cached chapter"), function()
                if cached then
                    self:openFile(cached)
                else
                    self:showInfo(_("No cached file."))
                end
            end),
        },
        {
            text = _("Download chapter and read"),
            callback = self:safeCallback(_("Download chapter and read"), function()
                self:downloadChapterAndRead(book, chapter)
            end),
        },
    }
    self:showList(chapter.title or _("Chapter"), items, _("No actions."))
end

function WeReadPlugin:openFile(path)
    if not path or path == "" then
        self:showInfo(_("No cached file."))
        return
    end
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        self.ui:openFile(path)
    end
end

function WeReadPlugin:openCachedBook(book)
    self:openFile(book.cached_file)
end

function WeReadPlugin:downloadFirstChapterAndRead(book)
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before downloading book content."))
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        self:showBusy(_("Downloading first chapter, please wait..."))
        local ok, path_or_err, chapter = pcall(function()
            return Content.fetch_first_chapter(self.client, self.settings, book)
        end)
        if not ok then
            self:closeBusy()
            self:showInfo(T(_("Download failed:\n%1"), tostring(path_or_err)))
            return
        end
        local books = self.settings:get("books", {})
        local book_id = book.book_id or book.bookId
        if book_id then
            books[book_id] = book
            self.settings:set("books", books)
            self.settings:flush()
        end
        self:closeBusy()
        UIManager:show(ConfirmBox:new{
            text = T(_("Chapter saved:\n%1\n\nRead now?"), path_or_err),
            ok_text = _("Read now"),
            ok_callback = self:safeCallback(_("Read now"), function()
                self:openFile(path_or_err)
            end),
        })
    end)
end

function WeReadPlugin:downloadChapterAndRead(book, chapter)
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before downloading book content."))
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        self:showBusy(T(_("Downloading chapter: %1"), chapter.title or tostring(chapter.chapterUid)))
        local ok, path_or_err = pcall(function()
            return Content.fetch_chapter_epub(self.client, self.settings, book, chapter)
        end)
        if not ok then
            self:closeBusy()
            self:showInfo(T(_("Download failed:\n%1"), tostring(path_or_err)))
            return
        end
        local books = self.settings:get("books", {})
        local book_id = book.book_id or book.bookId
        if book_id then
            books[book_id] = book
            self.settings:set("books", books)
            self.settings:flush()
        end
        self:closeBusy()
        UIManager:show(ConfirmBox:new{
            text = T(_("Chapter saved:\n%1\n\nRead now?"), path_or_err),
            ok_text = _("Read now"),
            ok_callback = self:safeCallback(_("Read now"), function()
                self:openFile(path_or_err)
            end),
        })
    end)
end

function WeReadPlugin:downloadFirstNChapters(book, count)
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before downloading book content."))
        return
    end
    self:loadChapters(book, function(chapters)
        local limit = math.min(count or 5, #chapters)
        local selected = {}
        for chapter_index = 1, limit do
            table.insert(selected, chapters[chapter_index])
        end
        self:downloadChaptersAsBook(book, selected, "first-" .. tostring(limit))
    end)
end

function WeReadPlugin:confirmDownloadAllChapters(book)
    self:loadChapters(book, function(chapters)
        UIManager:show(ConfirmBox:new{
            text = T(_("Download all %1 chapters as one EPUB?"), tostring(#chapters)),
            ok_text = _("Download"),
            ok_callback = self:safeCallback(_("Download full book"), function()
                self:downloadChaptersAsBook(book, chapters, "full")
            end),
            cancel_text = _("Close"),
        })
    end)
end

function WeReadPlugin:downloadChaptersAsBook(book, chapters, suffix)
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before downloading book content."))
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        self:showBusy(_("Preparing download..."))
        local ok, path_or_err, saved_chapters = pcall(function()
            return Content.fetch_chapters_epub(self.client, self.settings, book, chapters, {
                suffix = suffix or "book",
                progress = function(chapter_index, total, chapter, stage)
                    if stage == "images" then
                        self:showBusy(T(_("Downloading images %1 / %2: %3"), tostring(chapter_index), tostring(total), chapter.title or tostring(chapter.chapterUid)))
                    else
                        self:showBusy(T(_("Downloading %1 / %2: %3"), tostring(chapter_index), tostring(total), chapter.title or tostring(chapter.chapterUid)))
                    end
                end,
            })
        end)
        local books = self.settings:get("books", {})
        local book_id = book.book_id or book.bookId
        if book_id then
            books[book_id] = book
            self.settings:set("books", books)
            self.settings:flush()
        end
        self:closeBusy()
        if not ok then
            self:showInfo(T(_("Download failed:\n%1"), tostring(path_or_err)))
            return
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("Downloaded %1 chapters.\n\nBook saved:\n%2\n\nRead now?"), tostring(#(saved_chapters or {})), path_or_err),
            ok_text = _("Read now"),
            ok_callback = self:safeCallback(_("Read now"), function()
                self:openFile(path_or_err)
            end),
            cancel_text = _("Close"),
        })
    end)
end

function WeReadPlugin:pullProgressWithUI(book_id)
    self:runNetworkAction(_("Pull progress"), function()
        local result = self.client:get_progress(book_id)
        local progress = result and result.book and result.book.progress or 0
        return T(_("Remote progress: %1%%"), tostring(progress))
    end)
end

function WeReadPlugin:showSearch()
    if not self.settings:is_api_configured() then
        self:showInfo(_("Set the official API key before using WeRead search."))
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Search WeRead"),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Search"), function()
                        local keyword = dialog:getInputText()
                        UIManager:close(dialog)
                        self:searchWithUI(keyword)
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function WeReadPlugin:searchWithUI(keyword)
    if not keyword or keyword == "" then
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local ok, result = pcall(function()
            return self.client:gateway("/store/search", {
                keyword = keyword,
                count = 10,
            })
        end)
        if not ok then
            self:showInfo(T(_("Search failed:\n%1"), tostring(result)))
            return
        end
        local items = {}
        for group_index, group in ipairs(result.results or {}) do
            for book_index, entry in ipairs(group.books or {}) do
                local book = entry.bookInfo or entry
                table.insert(items, {
                    text = book.title or book.bookId or _("Untitled"),
                    post_text = book.author or "",
                    mandatory = book.category or "",
                    callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                        self:showBookRecord(book)
                    end),
                })
            end
        end
        self:showList(T(_("Search: %1"), keyword), items, _("No search results."))
    end)
end

function WeReadPlugin:showPasteReaderURL()
    local dialog
    dialog = InputDialog:new{
        title = _("Paste WeRead reader URL"),
        input = "https://weread.qq.com/web/reader/",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Parse"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Parse"), function()
                        local url = dialog:getInputText()
                        UIManager:close(dialog)
                        self:parseReaderURLWithUI(url)
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function WeReadPlugin:parseReaderURLWithUI(url)
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before parsing reader URLs."))
        return
    end
    self:runNetworkAction(_("Parse reader URL"), function()
        local html = self.client:get_text(url, { referer = url })
        local book_id = html:match([["bookId"%s*:%s*"([^"]+)"]]) or html:match([["bookId"%s*:%s*(%d+)]])
        local title = html:match([["title"%s*:%s*"([^"]+)"]]) or _("Unknown title")
        local psvts = html:match([["psvts"%s*:%s*"([^"]+)"]])
        local pclts = html:match([["pclts"%s*:%s*"([^"]+)"]])
        local token = html:match([["token"%s*:%s*"([^"]+)"]])
        if not book_id then
            return _("Reader HTML loaded, but bookId was not found.")
        end
        local books = self.settings:get("books", {})
        books[book_id] = {
            book_id = book_id,
            title = title,
            reader_url = url,
            psvts = psvts,
            pclts = pclts,
            token = token,
            updated_at = os.time(),
        }
        self.settings:set("books", books)
        self.settings:flush()
        return T(_("Reader URL parsed.\nBook: %1\nbookId: %2"), title, book_id)
    end)
end

function WeReadPlugin:showDownloads()
    local downloads = self.settings:get("downloads", {})
    local count = 0
    for _ in pairs(downloads) do
        count = count + 1
    end
    self:showInfo(T(_("Download queue entries: %1\n\nChapter caching UI is scaffolded; content decoding will be implemented next."), tostring(count)))
end

function WeReadPlugin:showSyncStatus()
    local sync = self.settings:get("sync")
    local pull_on_open = sync.pull_on_open and _("on") or _("off")
    local upload_on_close = sync.upload_on_close and _("on") or _("off")
    self:showInfo(T(_("Pull on open: %1\nUpload on close: %2\nUpload interval: %3 minutes"), pull_on_open, upload_on_close, tostring(sync.upload_interval_minutes)))
end

function WeReadPlugin:showCurrentBookDetails()
    self:showInfo(_("Current-book WeRead metadata is not linked yet. Open a parsed WeRead book from the plugin cache first."))
end

function WeReadPlugin:showNotes()
    self:showInfo(_("Read-only WeRead notes are planned for V1 after the book list screen is connected."))
end

function WeReadPlugin:onShowWeRead()
    self:showAccountStatus()
end

function WeReadPlugin:onWeReadSyncProgress()
    local books = self.settings:get("books", {})
    local book_id, book
    for id, item in pairs(books) do
        book_id, book = id, item
        break
    end
    if not book_id then
        self:showInfo(_("Parse a WeRead reader URL before testing progress sync."))
        return
    end
    local payload = WeRead.make_read_payload{
        book_id = book_id,
        chapter_uid = book.chapter_uid or 0,
        chapter_idx = book.chapter_idx or 0,
        chapter_offset = book.chapter_offset or 0,
        progress = book.progress or 0,
        summary = book.summary or "",
        app_id = book.app_id or self.settings:get("curl_payload", {}).appId,
        psvts = book.psvts or self.settings:get("curl_payload", {}).ps,
        pclts = book.pclts or self.settings:get("curl_payload", {}).pc,
        token = book.token,
    }
    UIManager:show(ConfirmBox:new{
        text = T(_("Upload local progress to WeRead?\n\nBook: %1\nProgress: %2%%\nChapter offset: %3"), book.title or book_id, tostring(payload.pr), tostring(payload.co)),
        ok_text = _("Upload"),
        ok_callback = self:safeCallback(_("Upload"), function()
            self:runNetworkAction(_("Sync progress"), function()
                local result = self.client:report_read(payload, book.reader_url)
                if result and result.succ then
                    return _("WeRead progress synced.")
                end
                return _("Progress request sent, but response did not include succ=1.")
            end)
        end),
    })
end

function WeReadPlugin:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

return WeReadPlugin
