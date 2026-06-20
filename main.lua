local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local DownloadDialog = require("lib.download_dialog")
local ProgressbarDialog = require("ui/widget/progressbardialog")
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
    version = "0.1.0",
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
    local rr = self.settings:get("read_report")
    if rr.enabled and rr.mode == "manual" and rr.book_id ~= "" and not rr.report_on_open then
        self:startReadReport(true)
    end
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

    local mp_source = config.mp_curl or config.curl
    if type(mp_source) == "string" then
        local ticket = mp_source:match("%-H%s+['\"][Xx]%-[Ww][Rr]%-[Tt]icket:%s*(.-)['\"]")
        if ticket and ticket ~= "" then
            self.settings:set("wr_ticket", ticket)
        end
        local wrpa = mp_source:match("%-H%s+['\"][Xx]%-[Ww][Rr][Pp][Aa]%-0:%s*(.-)['\"]")
        if wrpa and wrpa ~= "" then
            self.settings:set("wr_wrpa", wrpa)
        end
    end
    if type(config.wr_ticket) == "string" and config.wr_ticket:match("%S") then
        self.settings:set("wr_ticket", config.wr_ticket)
    end
    if type(config.mp_curl) == "string" and config.mp_curl:match("%S") then
        local mp_cookie = Cookie.extract_from_curl(config.mp_curl)
        if mp_cookie and mp_cookie:match("%S") then
            local cookies = Cookie.parse_cookie_header(mp_cookie)
            if Cookie.has_login_cookie(cookies) then
                self.settings:set("cookies", cookies)
            end
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
            text = _("Reading time report"),
            sub_item_table_func = function()
                return self:getReadReportMenuItems()
            end,
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
            text = _("Sync progress now") .. "  (" .. _("WIP") .. ")",
            enabled_func = function() return false end,
        })
        table.insert(items, 2, {
            text = _("Book details") .. "  (" .. _("WIP") .. ")",
            enabled_func = function() return false end,
        })
        table.insert(items, 3, {
            text = _("Notes") .. "  (" .. _("WIP") .. ")",
            enabled_func = function() return false end,
        })
    end

    return items
end

function WeReadPlugin:getSettingsMenuItems()
    return {
        {
            text = T(_("About (v%1)"), self.version),
            keep_menu_open = true,
            separator = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("WeRead Plugin v%1\n\nDisclaimer: This project is for personal learning and technical research only, not for commercial use. All consequences arising from the use of this project (including but not limited to account bans, data loss, etc.) are borne by the user. The project author assumes no responsibility. Please comply with WeRead's user agreement and applicable laws and regulations.\n\nhttps://github.com/qiuyukang/weread.koplugin"), self.version),
                })
            end,
        },
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
            text = _("Download book/article images"),
            checked_func = function()
                return self.settings:get("cache").download_images
            end,
            callback = self:safeCallback(_("Download book/article images"), function()
                local cache = self.settings:get("cache")
                cache.download_images = not cache.download_images
                self.settings:set("cache", cache)
                self.settings:flush()
            end),
        },
        {
            text = _("Bookshelf sort order"),
            sub_item_table_func = function()
                return self:getShelfSortMenuItems()
            end,
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
        {
            text = _("Cache management"),
            callback = self:safeCallback(_("Cache management"), function()
                self:showCacheManagement()
            end),
        },
    }
end

function WeReadPlugin:getShelfSortMenuItems()
    local sort_options = {
        { key = "time_desc", label = _("Last read time (newest first)") },
        { key = "time_asc",  label = _("Last read time (oldest first)") },
        { key = "name_asc",  label = _("Title A-Z") },
        { key = "name_desc", label = _("Title Z-A") },
        { key = "default",   label = _("Default order") },
    }
    local items = {}
    for _i, opt in ipairs(sort_options) do
        table.insert(items, {
            text = opt.label,
            checked_func = function()
                return self.settings:get("shelf").sort_order == opt.key
            end,
            callback = function()
                local shelf = self.settings:get("shelf")
                shelf.sort_order = opt.key
                self.settings:set("shelf", shelf)
                self.settings:flush()
            end,
        })
    end
    return items
end

function WeReadPlugin:showCacheManagement()
    local lfs = require("libs/libkoreader-lfs")
    local books = self.settings:get("books", {})
    local cache_dir = self.settings.cache_dir
    local items = {}
    local total_size = 0

    for book_id, book in pairs(books) do
        if book.cached_file or book.cached_chapters then
            local book_dir = cache_dir .. "/" .. book_id
            local size = 0
            local file_count = 0
            local ok, iter, dir_obj = pcall(lfs.dir, book_dir)
            if ok then
                for entry in iter, dir_obj do
                    if entry ~= "." and entry ~= ".." then
                        local attr = lfs.attributes(book_dir .. "/" .. entry)
                        if attr and attr.mode == "file" then
                            size = size + (attr.size or 0)
                            file_count = file_count + 1
                        end
                    end
                end
            end
            if file_count > 0 then
                total_size = total_size + size
                local size_str = size < 1024 * 1024
                    and string.format("%.0f KB", size / 1024)
                    or string.format("%.1f MB", size / 1024 / 1024)
                table.insert(items, {
                    text = book.title or book_id,
                    post_text = T(_("%1 files, %2"), tostring(file_count), size_str),
                    callback = self:safeCallback(book.title or book_id, function()
                        self:confirmClearBookCache(book_id, book.title or book_id)
                    end),
                })
            end
        end
    end

    local total_str = total_size < 1024 * 1024
        and string.format("%.0f KB", total_size / 1024)
        or string.format("%.1f MB", total_size / 1024 / 1024)
    table.insert(items, {
        text = T(_("Clear all cache (%1)"), total_str),
        callback = self:safeCallback(_("Clear all cache"), function()
            UIManager:show(ConfirmBox:new{
                text = _("Clear all cache? Downloaded books and articles will be deleted."),
                ok_text = _("Clear"),
                ok_callback = function()
                    self:clearAllCache()
                    self:showTransientInfo(_("Cache cleared"))
                    self:showCacheManagement()
                end,
            })
        end),
    })

    self:showList(_("Cache management"), items, _("No cached books"))
end

function WeReadPlugin:confirmClearBookCache(book_id, title)
    UIManager:show(ConfirmBox:new{
        text = T(_("Clear cache for \"%1\"?"), title),
        ok_text = _("Clear"),
        ok_callback = function()
            self:clearBookCache(book_id)
            self:showTransientInfo(_("Cache cleared"))
            self:showCacheManagement()
        end,
    })
end

function WeReadPlugin:clearBookCache(book_id)
    local cache_dir = self.settings.cache_dir .. "/" .. book_id
    os.execute("rm -rf " .. string.format("%q", cache_dir))
    local books = self.settings:get("books", {})
    if books[book_id] then
        books[book_id].cached_file = nil
        books[book_id].cached_chapters = nil
        self.settings:set("books", books)
        self.settings:flush()
    end
end

function WeReadPlugin:clearAllCache()
    local cache_dir = self.settings.cache_dir
    os.execute("rm -rf " .. string.format("%q", cache_dir))
    os.execute("mkdir -p " .. string.format("%q", cache_dir))
    local books = self.settings:get("books", {})
    for _, book in pairs(books) do
        book.cached_file = nil
        book.cached_chapters = nil
    end
    self.settings:set("books", books)
    self.settings:flush()
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

function WeReadPlugin:getReadReportMenuItems()
    local rr = self.settings:get("read_report")
    return {
        {
            text = _("Enable reading time report"),
            checked_func = function()
                return self.settings:get("read_report").enabled
            end,
            callback = self:safeCallback(_("Enable reading time report"), function()
                local cur = self.settings:get("read_report")
                cur.enabled = not cur.enabled
                self.settings:set("read_report", cur)
                self.settings:flush()
                if cur.enabled then
                    if cur.mode == "auto" then
                        self:maybeStartReadReport()
                    elseif cur.book_id == "" then
                        self:showTransientInfo(_("Please select a target book"), 2)
                        self:showReadReportBookPicker()
                    else
                        self:maybeStartReadReport()
                    end
                else
                    self:stopReadReport()
                end
            end),
        },
        {
            text = _("Only report when reading"),
            checked_func = function()
                return self.settings:get("read_report").report_on_open
            end,
            callback = self:safeCallback(_("Only report when reading"), function()
                local cur = self.settings:get("read_report")
                cur.report_on_open = not cur.report_on_open
                self.settings:set("read_report", cur)
                self.settings:flush()
                if cur.enabled then
                    local has_book = cur.mode == "auto" and self._auto_report_book_id or cur.book_id ~= ""
                    if has_book then
                        if cur.report_on_open and not self.ui.document then
                            self:stopReadReport()
                        else
                            self:maybeStartReadReport()
                        end
                    end
                end
            end),
        },
        {
            text = _("Select target book"),
            post_text = rr.mode == "auto" and _("Auto-associate")
                or (rr.book_title ~= "" and T(_("Manual: %1"), rr.book_title) or _("Not configured")),
            sub_item_table_func = function()
                return self:getReportTargetMenuItems()
            end,
        },
        {
            text = _("Report status"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Report status"), function()
                local cur = self.settings:get("read_report")
                local target
                if cur.mode == "auto" then
                    local auto_title = self._auto_report_book_title
                    target = auto_title and T(_("Auto: %1"), auto_title) or _("Auto-associate")
                else
                    target = cur.book_title ~= "" and cur.book_title or _("Not configured")
                end
                local status = self._report_task and _("Running") or _("Stopped")
                local count = self._report_count or 0
                local last = self._report_last_time
                    and os.date("%H:%M:%S", self._report_last_time) or "--"
                local err = self._report_last_error or ""
                local msg = T(_("Report book: %1\nStatus: %2"), target, status)
                    .. "\n" .. T(_("Reported: %1 times, last: %2"), tostring(count), last)
                if err ~= "" then
                    msg = msg .. "\n" .. T(_("Last error: %1"), err)
                end
                self:showInfo(msg)
            end),
        },
    }
end

function WeReadPlugin:getReportTargetMenuItems()
    local rr = self.settings:get("read_report")
    return {
        {
            text = _("Auto-associate with WeRead book"),
            checked_func = function()
                return self.settings:get("read_report").mode == "auto"
            end,
            callback = self:safeCallback(_("Auto-associate with WeRead book"), function()
                local cur = self.settings:get("read_report")
                cur.mode = "auto"
                cur.book_id = ""
                cur.book_title = ""
                self.settings:set("read_report", cur)
                self.settings:flush()
                if cur.enabled then
                    self:maybeStartReadReport()
                end
            end),
        },
        {
            text = _("Manually set report book"),
            checked_func = function()
                return self.settings:get("read_report").mode == "manual"
            end,
            post_text = rr.mode == "manual" and rr.book_title ~= "" and rr.book_title or "",
            callback = self:safeCallback(_("Manually set report book"), function()
                local cur = self.settings:get("read_report")
                cur.mode = "manual"
                self.settings:set("read_report", cur)
                self.settings:flush()
                self:showReadReportBookPicker()
            end),
        },
    }
end

function WeReadPlugin:detectWeReadBook()
    if not self.ui.document then
        return nil
    end
    local file = self.ui.document.file
    if not file then
        return nil
    end
    local cache_dir = self.settings.cache_dir
    if file:sub(1, #cache_dir) == cache_dir then
        local rest = file:sub(#cache_dir + 2)
        local book_id = rest:match("^([^/]+)")
        return book_id
    end
    return nil
end

function WeReadPlugin:showReadReportBookPicker()
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
        self:closeBusy()
        local all_books = result.books or {}
        local items = {}
        for i, book in ipairs(all_books) do
            if not WeRead.is_mp_book(book.bookId) then
                table.insert(items, {
                    text = book.title or book.bookId or _("Untitled"),
                    post_text = book.author or "",
                    callback = self:safeCallback(book.title or _("Select target book"), function()
                        local rr = self.settings:get("read_report")
                        rr.book_id = book.bookId
                        rr.book_title = book.title or book.bookId
                        self.settings:set("read_report", rr)
                        self.settings:flush()
                        if self._picker_menu then
                            UIManager:close(self._picker_menu)
                            self._picker_menu = nil
                        end
                        self:showTransientInfo(T(_("Target book set: %1"), rr.book_title))
                        self:maybeStartReadReport()
                    end),
                })
            end
        end
        if not items or #items == 0 then
            self:showInfo(_("Your WeRead shelf is empty."))
            return
        end
        self._picker_menu = Menu:new{
            title = _("Select a book to report reading time"),
            item_table = items,
            is_borderless = true,
            title_bar_fm_style = true,
        }
        UIManager:show(self._picker_menu)
    end)
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
        local all_books = result.books or {}
        self.shelf_regular = {}
        self.shelf_mp = {}
        for _i, book in ipairs(all_books) do
            if WeRead.is_mp_book(book.bookId) then
                table.insert(self.shelf_mp, book)
            else
                table.insert(self.shelf_regular, book)
            end
        end
        self.shelf_books = self.shelf_regular
        self:closeBusy()
        if #self.shelf_mp > 0 then
            self:showShelfTabs()
        else
            self:showShelfPage()
        end
    end)
end

local function sortBooks(books, sort_order)
    if sort_order == "default" or not sort_order then
        return books
    end
    local sorted = {}
    for i, book in ipairs(books) do
        sorted[i] = book
    end
    if sort_order == "time_desc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) > (b.readUpdateTime or 0)
        end)
    elseif sort_order == "time_asc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) < (b.readUpdateTime or 0)
        end)
    elseif sort_order == "name_asc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") < (b.title or "")
        end)
    elseif sort_order == "name_desc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") > (b.title or "")
        end)
    end
    return sorted
end

function WeReadPlugin:showShelfPage()
    local books = self.shelf_books or {}
    local sort_order = self.settings:get("shelf").sort_order
    books = sortBooks(books, sort_order)
    local items = {}
    for _i, book in ipairs(books) do
        local right_text
        if book.finishReading == 1 then
            right_text = _("Done")
        elseif book.readUpdateTime and book.readUpdateTime > 0 then
            right_text = os.date("%Y-%m-%d", book.readUpdateTime)
        else
            right_text = ""
        end
        table.insert(items, {
            text = book.title or book.bookId or _("Untitled"),
            mandatory = right_text,
            callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                self:showBookRecord(book)
            end),
        })
    end
    self:showList(_("WeRead Bookshelf"), items, _("Your WeRead shelf is empty."))
end

function WeReadPlugin:showBookRecord(book)
    local books = self.settings:get("books", {})
    local book_id = book.book_id or book.bookId
    if WeRead.is_mp_book(book_id) then
        self:showMPAccount(book)
        return
    end
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
    local saved = books[book_id] or book
    self:showBusy(_("Loading book info..."))
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local ok, err = pcall(function()
            local info = self.client:get_book_info(book_id)
            if info then
                saved.intro = info.intro
                saved.publisher = info.publisher
                saved.isbn = info.isbn
                saved.wordCount = info.wordCount
                saved.newRating = info.newRating
                saved.newRatingCount = info.newRatingCount
                saved.translator = info.translator
                saved.categoryName = info.categoryName or info.category
                books[book_id] = saved
                self.settings:set("books", books)
                self.settings:flush()
            end
            local progress_result = self.client:get_progress(book_id)
            if progress_result and progress_result.book then
                saved.progress = progress_result.book.progress or 0
            end
        end)
        self:closeBusy()
        if not ok then
            self:showInfo(T(_("%1 failed:\n%2"), _("Book info"), tostring(err)))
            return
        end
        self:showBookMenu(saved)
    end)
end

function WeReadPlugin:showBookMenu(book)
    local book_id = book.book_id or book.bookId
    local items = {}

    if book.author and book.author ~= "" then
        table.insert(items, { text = _("Author"), mandatory = book.author })
    end
    if book.translator and book.translator ~= "" then
        table.insert(items, { text = _("Translator"), mandatory = book.translator })
    end
    if book.publisher and book.publisher ~= "" then
        table.insert(items, { text = _("Publisher"), mandatory = book.publisher })
    end
    if book.categoryName and book.categoryName ~= "" then
        table.insert(items, { text = _("Category"), mandatory = book.categoryName })
    end
    if book.wordCount and book.wordCount > 0 then
        local wc = book.wordCount >= 10000
            and string.format("%.1f%s", book.wordCount / 10000, _("w words"))
            or tostring(book.wordCount)
        table.insert(items, { text = _("Word count"), mandatory = wc })
    end
    if book.newRating and book.newRating > 0 then
        local score = string.format("%.1f", book.newRating / 100)
        local count = book.newRatingCount and tostring(book.newRatingCount) or "0"
        table.insert(items, { text = _("Rating"), mandatory = T(_("%1 (%2 ratings)"), score, count) })
    end
    if book.isbn and book.isbn ~= "" then
        table.insert(items, { text = "ISBN", mandatory = book.isbn })
    end
    if book.progress and book.progress > 0 then
        table.insert(items, { text = _("Reading progress"), mandatory = tostring(book.progress) .. "%" })
    end
    if book.intro and book.intro ~= "" then
        table.insert(items, {
            text = _("Introduction"),
            callback = function()
                UIManager:show(InfoMessage:new{ text = book.intro })
            end,
        })
    end

    if #items > 0 then
        items[#items].separator = true
    end

    table.insert(items, {
        text = _("Chapter list"),
        post_text = book.chapters and T(_("%1 chapters"), tostring(#book.chapters)) or _("Not loaded"),
        callback = self:safeCallback(_("Chapter list"), function()
            self:showChapterList(book)
        end),
    })
    if book.cached_file then
        table.insert(items, {
            text = _("Clear book cache"),
            callback = self:safeCallback(_("Clear book cache"), function()
                self:confirmClearBookCache(book_id, book.title or book_id)
            end),
        })
    end
    table.insert(items, {
        text = _("Open cached book"),
        post_text = book.cached_file and _("Cached") or _("Not cached"),
        callback = self:safeCallback(_("Open cached book"), function()
            self:openCachedBook(book)
        end),
    })
    table.insert(items, {
        text = _("Download full book"),
        post_text = _("EPUB"),
        callback = self:safeCallback(_("Download full book"), function()
            self:confirmDownloadAllChapters(book)
        end),
    })

    self:showList(book.title or _("Book details"), items, _("No actions."))
end

function WeReadPlugin:showShelfTabs()
    local items = {
        {
            text = _("Books"),
            post_text = T(_("%1 books"), tostring(#self.shelf_regular)),
            callback = self:safeCallback(_("Books"), function()
                self.shelf_books = self.shelf_regular
                self:showShelfPage()
            end),
        },
        {
            text = _("Public Accounts"),
            post_text = T(_("%1 accounts"), tostring(#self.shelf_mp)),
            callback = self:safeCallback(_("Public Accounts"), function()
                self:showMPShelfPage()
            end),
        },
    }
    self:showList(_("WeRead Bookshelf"), items, _("Your WeRead shelf is empty."))
end

function WeReadPlugin:showMPShelfPage()
    local books = self.shelf_mp or {}
    local sort_order = self.settings:get("shelf").sort_order
    books = sortBooks(books, sort_order)
    local items = {}
    for _i, book in ipairs(books) do
        table.insert(items, {
            text = book.title or book.bookId or _("Untitled"),
            post_text = book.author or "",
            callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                self:showMPAccount(book)
            end),
        })
    end
    self:showList(_("Public Accounts"), items, _("No items."))
end

function WeReadPlugin:showMPAccount(book)
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before loading articles."))
        return
    end
    local book_id = book.book_id or book.bookId
    local cached = self:getCachedMPArticles(book_id)
    if cached and #cached > 0 then
        self:showMPArticleList(book, cached)
        return
    end
    self:fetchMPArticles(book, nil)
end

function WeReadPlugin:fetchMPArticles(book, wr_ticket)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        self:showBusy(_("Loading articles..."))
        local book_id = book.book_id or book.bookId
        local ticket = wr_ticket or self.settings:get("wr_ticket", "")
        if ticket == "" then ticket = nil end
        local ok, result, err_code = pcall(function()
            return self.client:get_mp_articles(book_id, 0, 100, ticket)
        end)
        self:closeBusy()
        if not ok then
            self:showInfo(T(_("Load articles failed:\n%1"), tostring(result)))
            return
        end
        if not result and (err_code == -2041 or err_code == -2012) then
            local saved_ticket = self.settings:get("wr_ticket", "")
            if saved_ticket ~= "" then
                self:showInfo(T(_("Load articles failed:\n%1"), "wr_ticket expired, update wr_ticket in config.lua"))
            else
                self:showInfo(_("MP articles require wr_ticket. Set wr_ticket in config.lua, then reload config."))
            end
            return
        end
        if not result then
            self:showInfo(T(_("Load articles failed:\n%1"), "errCode " .. tostring(err_code)))
            return
        end
        local articles = Content.parse_mp_articles(result)
        self:cacheMPArticles(book_id, articles)
        self:showMPArticleList(book, articles)
    end)
end

function WeReadPlugin:showWrTicketDialog(book)
    local dialog
    dialog = InputDialog:new{
        title = _("Provide x-wr-ticket"),
        input = self.settings:get("wr_ticket", ""),
        input_type = "text",
        description = _("MP article list requires a browser token.\n\n1. Open weread.qq.com in a browser\n2. Open an MP account page\n3. Open DevTools (F12) → Network tab\n4. Find the /web/mp/articles request\n5. Copy the x-wr-ticket header value\n\nPaste it here (or paste the full cURL):"),
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
                    text = _("Fetch"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Fetch"), function()
                        local input = dialog:getInputText()
                        UIManager:close(dialog)
                        local ticket = input
                        local extracted = input:match("%-H%s+['\"][Xx]%-[Ww][Rr]%-[Tt]icket:%s*(.-)['\"]")
                        if extracted then
                            ticket = extracted
                        end
                        if not ticket or ticket == "" then
                            self:showInfo(_("No ticket provided."))
                            return
                        end
                        self.settings:set("wr_ticket", ticket)
                        self.settings:flush()
                        self:fetchMPArticles(book, ticket)
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function WeReadPlugin:getCachedMPArticles(book_id)
    local books = self.settings:get("books", {})
    local record = books[book_id]
    if record and record.mp_articles then
        return record.mp_articles
    end
    return nil
end

function WeReadPlugin:cacheMPArticles(book_id, articles)
    local books = self.settings:get("books", {})
    books[book_id] = books[book_id] or {}
    books[book_id].mp_articles = articles
    books[book_id].mp_articles_time = os.time()
    self.settings:set("books", books)
    self.settings:flush()
end

function WeReadPlugin:showMPArticleList(book, articles)
    local items = {}
    for _i, article in ipairs(articles) do
        local cached_path = Content.mp_article_cached_path(self.settings, book, article)
        local is_cached = cached_path ~= nil
        local date_str = ""
        if article.createTime and article.createTime > 0 then
            date_str = os.date("%Y-%m-%d", article.createTime)
        end
        table.insert(items, {
            text = article.title or _("Article"),
            post_text = date_str,
            mandatory = is_cached and _("Cached") or "",
            callback = self:safeCallback(article.title or _("Article"), function()
                if is_cached then
                    self:openFile(cached_path)
                else
                    self:downloadMPArticleAndRead(book, article)
                end
            end),
        })
    end
    table.insert(items, {
        text = _("Refresh article list"),
        callback = self:safeCallback(_("Refresh article list"), function()
            self:showWrTicketDialog(book)
        end),
    })
    self:showList(book.title or _("Public Account"), items, _("No articles."))
end

function WeReadPlugin:downloadMPArticleAndRead(book, article)
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before downloading articles."))
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        self:showBusy(T(_("Downloading article: %1"), article.title or ""))
        local progress_dialog
        local ok, path_or_err = pcall(function()
            return Content.fetch_mp_article_html(self.client, self.settings, book, article, {
                progress = function(current, total)
                    if not progress_dialog then
                        self:closeBusy()
                        progress_dialog = ProgressbarDialog:new{
                            title = T(_("Downloading images: %1"), article.title or ""),
                            progress_max = total,
                        }
                        progress_dialog:show()
                        self:refreshUI()
                    end
                    progress_dialog:reportProgress(current)
                end,
            })
        end)
        if progress_dialog then
            progress_dialog:close()
        else
            self:closeBusy()
        end
        if not ok then
            self:showInfo(T(_("Download failed:\n%1"), tostring(path_or_err)))
            return
        end
        self:openFile(path_or_err)
    end)
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

function WeReadPlugin:showChapterList(book)
    self:loadChapters(book, function(chapters)
        local items = {}
        for _i, chapter in ipairs(chapters) do
            local cached = book.cached_chapters and book.cached_chapters[tostring(chapter.chapterUid)]
            table.insert(items, {
                text = chapter.title or T(_("Chapter %1"), tostring(chapter.chapterUid)),
                post_text = cached and _("Cached") or T(_("%1 words"), tostring(chapter.wordCount or 0)),
                callback = self:safeCallback(chapter.title or _("Chapter"), function()
                    if cached then
                        self:openFile(cached)
                    else
                        self:downloadChapterAndRead(book, chapter)
                    end
                end),
            })
        end
        self:showList(book.title or _("Chapter list"), items, _("No chapters."))
    end)
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
        self:openFile(path_or_err)
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
        self:openFile(path_or_err)
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
        local confirm
        confirm = ConfirmBox:new{
            text = T(_("Download all %1 chapters as one EPUB?"), tostring(#chapters)),
            ok_text = _("Download"),
            ok_callback = self:safeCallback(_("Download full book"), function()
                UIManager:close(confirm)
                self:downloadChaptersAsBook(book, chapters, "full")
            end),
            cancel_text = _("Close"),
        }
        UIManager:show(confirm)
    end)
end

function WeReadPlugin:downloadChaptersAsBook(book, chapters, suffix)
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before downloading book content."))
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local ok_init, err_init = pcall(function()
            Content.ensure_reader_state(self.client, book)
        end)
        if not ok_init then
            self:showInfo(T(_("Download failed:\n%1"), tostring(err_init)))
            return
        end

        local total = #chapters
        local dl = {
            book = book,
            chapters = chapters,
            suffix = suffix or "book",
            index = 1,
            cancelled = false,
            selected = {},
            bodies = {},
            assets = {},
            state = {},
            total = total,
        }

        local progress_dialog = DownloadDialog:new{
            title = T(_("Downloading: %1"), book.title or ""),
            progress_max = total,
            buttons = {{
                {
                    text = _("Cancel download"),
                    callback = function()
                        dl.cancelled = true
                        if dl.progress_dialog then
                            dl.progress_dialog:close()
                            dl.progress_dialog = nil
                        end
                    end,
                },
            }},
        }
        dl.progress_dialog = progress_dialog
        progress_dialog:show()
        self:refreshUI()

        UIManager:scheduleIn(0.1, function()
            self:_downloadStep(dl)
        end)
    end)
end

function WeReadPlugin:_downloadStep(dl)
    if dl.cancelled then
        self:showTransientInfo(_("Download cancelled"), 2)
        return
    end

    if dl.index > dl.total then
        local cover_data
        if dl.book.cover then
            pcall(function() cover_data = self.client:get_binary(dl.book.cover) end)
        end
        local ok, path = pcall(function()
            return Content.save_book_epub(
                self.settings, dl.book, dl.selected, dl.bodies,
                dl.suffix, dl.assets, dl.state.css, cover_data
            )
        end)
        if dl.progress_dialog then
            dl.progress_dialog:close()
            dl.progress_dialog = nil
        end
        local books = self.settings:get("books", {})
        local book_id = dl.book.book_id or dl.book.bookId
        if book_id then
            dl.book.cached_chapters = dl.book.cached_chapters or {}
            for ci, ch in ipairs(dl.selected) do
                dl.book.cached_chapters[tostring(ch.chapterUid or ci)] = ok and path or nil
            end
            if ok then
                dl.book.cached_file = path
            end
            dl.book.reader_url = dl.book.reader_url or WeRead.reader_url(book_id)
            books[book_id] = dl.book
            self.settings:set("books", books)
            self.settings:flush()
        end
        if not ok then
            self:showInfo(T(_("Download failed:\n%1"), tostring(path)))
            return
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("Downloaded %1 chapters.\n\nBook saved:\n%2\n\nRead now?"), tostring(#dl.selected), path),
            ok_text = _("Read now"),
            ok_callback = self:safeCallback(_("Read now"), function()
                self:openFile(path)
            end),
            cancel_text = _("Close"),
        })
        return
    end

    local chapter = dl.chapters[dl.index]
    local ok, xhtml, chapter_assets = pcall(function()
        return Content.fetch_single_chapter_content(
            self.client, self.settings, dl.book, chapter, dl.state
        )
    end)

    if ok then
        local uid = tostring(chapter.chapterUid or dl.index)
        dl.bodies[uid] = xhtml
        table.insert(dl.selected, chapter)
        for _i, asset in ipairs(chapter_assets or {}) do
            table.insert(dl.assets, asset)
        end
    else
        logger.warn("WeRead: chapter download failed:", tostring(xhtml))
    end

    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end

    UIManager:scheduleIn(0.1, function()
        self:_downloadStep(dl)
    end)
end

function WeReadPlugin:pullProgressWithUI(book_id)
    self:runNetworkAction(_("Pull progress"), function()
        local result = self.client:get_progress(book_id)
        local progress = result and result.book and result.book.progress or 0
        return T(_("Remote progress: %1%"), tostring(progress))
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

function WeReadPlugin:onReaderReady()
    local rr = self.settings:get("read_report")
    if rr.mode == "auto" and rr.enabled then
        local book_id = self:detectWeReadBook()
        if book_id then
            self._auto_report_book_id = book_id
            local books = self.settings:get("books", {})
            local book_record = books[book_id]
            self._auto_report_book_title = book_record and book_record.title or book_id
            self:startReadReport(true)
            self:showTransientInfo(T(_("Reading time report started: %1"), self._auto_report_book_title), 2)
        else
            self:showTransientInfo(_("Current book is not from WeRead, reading time not reported"), 1)
        end
    else
        self:maybeStartReadReport()
    end
end

function WeReadPlugin:onCloseDocument()
    local rr = self.settings:get("read_report")
    if rr.mode == "auto" then
        self._auto_report_book_id = nil
        self._auto_report_book_title = nil
        self:stopReadReport()
    elseif rr.report_on_open then
        self:stopReadReport()
    end
end

function WeReadPlugin:maybeStartReadReport()
    local rr = self.settings:get("read_report")
    if not rr.enabled then
        return
    end
    if rr.mode == "auto" then
        if not self._auto_report_book_id then
            return
        end
    elseif rr.book_id == "" then
        return
    end
    if rr.report_on_open and not self.ui.document then
        return
    end
    if not self._report_task then
        self:startReadReport(not rr.report_on_open)
    end
end

function WeReadPlugin:startReadReport(silent)
    self:stopReadReport()
    local rr = self.settings:get("read_report")
    local interval = rr.interval_seconds or 30
    self._report_count = 0
    self._report_last_time = nil
    self._report_last_error = nil
    self._report_task = function()
        local ok, err = pcall(function()
            self:doReadReport()
        end)
        if not ok then
            self._report_last_error = tostring(err)
            logger.warn("WeRead: report task error:", err)
        end
        if self._report_task then
            UIManager:scheduleIn(interval, self._report_task)
        end
    end
    UIManager:scheduleIn(interval, self._report_task)
    logger.info("WeRead: reading time report started, target:", rr.book_title or rr.book_id)
    if not silent then
        self:showTransientInfo(T(_("Reading time report started: %1"), rr.book_title or rr.book_id), 1)
    end
end

function WeReadPlugin:stopReadReport()
    if self._report_task then
        UIManager:unschedule(self._report_task)
        self._report_task = nil
        logger.info("WeRead: reading time report stopped")
    end
end

function WeReadPlugin:doReadReport()
    local rr = self.settings:get("read_report")
    local report_book_id = rr.mode == "auto" and self._auto_report_book_id or rr.book_id
    if not rr.enabled or not report_book_id or report_book_id == "" then
        return
    end
    if not self.settings:is_cookie_configured() then
        logger.warn("WeRead: read report skipped, cookie not configured")
        return
    end
    local curl_payload = self.settings:get("curl_payload", {})
    local now = os.time()
    local ts = now * 1000 + math.random(0, 999)
    local rn = math.random(0, 999)
    local token = WeRead.DEFAULT_READER_TOKEN
    local Crypto = require("lib.crypto")
    local payload = {
        appId = curl_payload.appId or WeRead.web_app_id(),
        b = WeRead.e(report_book_id),
        c = curl_payload.c or WeRead.e(0),
        ci = curl_payload.ci or 27,
        co = curl_payload.co or 389,
        sm = curl_payload.sm or "",
        pr = curl_payload.pr or 74,
        rt = rr.interval_seconds or 30,
        ts = ts,
        rn = rn,
        sg = Crypto.sha256_hex(tostring(ts) .. tostring(rn) .. token),
        ct = now,
        ps = curl_payload.ps or WeRead.e(now - 1),
        pc = WeRead.e(now),
    }
    payload.s = WeRead.sign(WeRead.sorted_query(payload))
    local ok, result = pcall(function()
        return self.client:report_read(payload)
    end)
    if ok and result and result.succ then
        self._report_count = (self._report_count or 0) + 1
        self._report_last_time = os.time()
        self._report_last_error = nil
        logger.info("WeRead: read report success, count:", self._report_count)
        return
    end
    if ok and result and not result.succ then
        logger.info("WeRead: read report no succ, attempting cookie renewal")
        local renew_ok = pcall(function()
            self.client:renew_cookie()
        end)
        if renew_ok then
            local ok2, result2 = pcall(function()
                return self.client:report_read(payload)
            end)
            if ok2 and result2 and result2.succ then
                self._report_count = (self._report_count or 0) + 1
                self._report_last_time = os.time()
                self._report_last_error = nil
                logger.info("WeRead: read report success after renewal, count:", self._report_count)
                return
            end
        end
        self._report_last_error = _("Cookie expired")
        return
    end
    if not ok then
        self._report_last_error = tostring(result)
        logger.warn("WeRead: read report error:", self._report_last_error)
    end
end

function WeReadPlugin:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

return WeReadPlugin
