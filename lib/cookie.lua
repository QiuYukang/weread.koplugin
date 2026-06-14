local Cookie = {}

function Cookie.parse_cookie_header(header)
    local cookies = {}
    if not header or header == "" then
        return cookies
    end
    header = header:gsub("^%s*[Cc]ookie:%s*", "")
    for part in header:gmatch("([^;]+)") do
        local key, value = part:match("^%s*([^=]+)=(.-)%s*$")
        if key and value then
            cookies[key] = value
        end
    end
    return cookies
end

function Cookie.extract_from_curl(curl)
    if not curl or curl == "" then
        return "", nil
    end

    -- Match the value inside *matching* single/double quotes: capture the opening
    -- quote and require the same quote to close it (back-reference %1). A plain
    -- ['\"](.-)['\"] stops at the first internal quote, so a JSON payload like
    -- --data-raw '{"appId":"…"}' was captured as just "{".
    local function quoted(pattern)
        local _opening_quote, value = curl:match(pattern)
        return value
    end

    local cookie = quoted("%-H%s+(['\"])[Cc]ookie:%s*(.-)%1")
        or quoted("%-b%s+(['\"])(.-)%1")
        or quoted("%-%-cookie%s+(['\"])(.-)%1")
    local data = quoted("%-%-data%-raw%s+(['\"])(.-)%1")
        or quoted("%-%-data%s+(['\"])(.-)%1")
        or quoted("%-d%s+(['\"])(.-)%1")

    return cookie or curl, data
end

function Cookie.to_header(cookies)
    local parts = {}
    for key, value in pairs(cookies or {}) do
        table.insert(parts, key .. "=" .. value)
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

function Cookie.merge_set_cookie(cookies, set_cookie)
    if not set_cookie or set_cookie == "" then
        return cookies
    end
    cookies = cookies or {}
    local allowed = {
        ptcz = true,
        RK = true,
        pgv_pvid = true,
    }
    for pair in set_cookie:gmatch("([^;,\r\n]+=[^;,\r\n]+)") do
        local name, value = pair:match("^%s*([%w_]+)=([^;,\r\n]+)")
        if name and value and (name:match("^wr_") or allowed[name]) then
            cookies[name] = value
        end
    end
    return cookies
end

function Cookie.has_login_cookie(cookies)
    return cookies and cookies.wr_skey and #cookies.wr_skey >= 8
end

return Cookie
