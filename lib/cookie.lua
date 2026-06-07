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

    local cookie = curl:match("%-H%s+['\"][Cc]ookie:%s*(.-)['\"]")
        or curl:match("%-b%s+['\"](.-)['\"]")
        or curl:match("%-%-cookie%s+['\"](.-)['\"]")
    local data = curl:match("%-%-data%-raw%s+['\"](.-)['\"]")
        or curl:match("%-%-data%s+['\"](.-)['\"]")
        or curl:match("%-d%s+['\"](.-)['\"]")

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
