local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local Settings = {}
Settings.__index = Settings

local defaults = {
    api_key = "",
    cookies = {},
    curl_payload = {},
    books = {},
    downloads = {},
    sync = {
        pull_on_open = true,
        upload_on_close = true,
        ask_on_conflict = true,
        upload_interval_minutes = 0,
    },
    cache = {
        download_images = true,
        max_size_mb = 1024,
    },
    advanced = {
        developer_logs = false,
    },
    config_loaded = false,
}

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    return out
end

local function ensure_dir(path)
    if not lfs.attributes(path, "mode") then
        lfs.mkdir(path)
    end
end

function Settings:new()
    local data_dir = DataStorage:getFullDataDir() .. "/weread"
    ensure_dir(data_dir)
    local obj = {
        data_dir = data_dir,
        cache_dir = data_dir .. "/cache",
        settings_file = DataStorage:getSettingsDir() .. "/weread.lua",
    }
    ensure_dir(obj.cache_dir)
    obj.store = LuaSettings:open(obj.settings_file)
    return setmetatable(obj, self)
end

function Settings:get(key, default)
    if default == nil then
        default = defaults[key]
    end
    return self.store:readSetting(key, deepcopy(default))
end

function Settings:set(key, value)
    self.store:saveSetting(key, value)
end

function Settings:flush()
    self.store:flush()
end

function Settings:get_all()
    local all = {}
    for key in pairs(defaults) do
        all[key] = self:get(key)
    end
    return all
end

function Settings:reset_account()
    self:set("api_key", "")
    self:set("cookies", {})
    self:set("curl_payload", {})
    self:flush()
end

function Settings:is_cookie_configured()
    local cookies = self:get("cookies", {})
    return cookies.wr_skey ~= nil and #cookies.wr_skey >= 8
end

function Settings:is_api_configured()
    return self:get("api_key", "") ~= ""
end

function Settings:apply_config(config)
    if type(config) ~= "table" then
        return false, "config must return a table"
    end
    if type(config.api_key) == "string" and config.api_key ~= "" then
        self:set("api_key", config.api_key)
    end
    if type(config.sync) == "table" then
        local sync = self:get("sync")
        for key, value in pairs(config.sync) do
            sync[key] = value
        end
        self:set("sync", sync)
    end
    if type(config.cache) == "table" then
        local cache = self:get("cache")
        for key, value in pairs(config.cache) do
            cache[key] = value
        end
        self:set("cache", cache)
    end
    self:set("config_loaded", true)
    self:flush()
    return true
end

return Settings
