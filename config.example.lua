-- Copy this file to config.lua and fill in your own values.
-- config.lua is ignored by git and loaded automatically by the plugin.

return {
    -- Optional but recommended. Enables shelf, search, progress read, and notes.
    api_key = "",

    -- Recommended. Paste the full cURL copied from a browser request to:
    -- https://weread.qq.com/web/book/read
    --
    -- The plugin will extract:
    -- - cookies
    -- - original request payload fields such as appId, ps, pc
    curl = [[
]],

    -- Alternative to curl. Paste only the raw Cookie header value here.
    -- Used only when curl is empty.
    cookie = [[
]],

    -- Optional defaults.
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
}
