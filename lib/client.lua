local ltn12 = require("ltn12")
local Cookie = require("lib.cookie")
local WeRead = require("lib.weread")

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local Client = {}
Client.__index = Client

local function header_value(headers, name)
    if not headers then
        return nil
    end
    local target = name:lower()
    for key, value in pairs(headers) do
        if tostring(key):lower() == target then
            return value
        end
    end
    return nil
end

local function absolute_url(base_url, location)
    if not location or location == "" then
        return nil
    end
    if location:match("^https?://") then
        return location
    end
    local scheme, host = base_url:match("^(https?)://([^/]+)")
    if not scheme then
        return location
    end
    if location:sub(1, 1) == "/" then
        return scheme .. "://" .. host .. location
    end
    local prefix = base_url:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
    return prefix .. location
end

function Client:new(settings)
    return setmetatable({
        settings = settings,
    }, self)
end

function Client:json_encode(data)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(data)
    end
    return json:encode(data)
end

function Client:json_decode(text)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(text)
    end
    return json:decode(text)
end

function Client:request(opts)
    local body = opts.body
    local response = {}
    local headers = opts.headers or {}
    headers["User-Agent"] = headers["User-Agent"] or WeRead.USER_AGENT
    headers["Accept"] = headers["Accept"] or "application/json, text/plain, */*"

    if body then
        headers["Content-Length"] = tostring(#body)
    end

    local transport = opts.url:match("^https:") and https or http
    if opts.url:match("^https:") and not ok_https then
        error("ssl.https is not available")
    elseif not transport and not ok_http then
        error("socket.http is not available")
    end

    local _, code, resp_headers, status = transport.request({
        url = opts.url,
        method = opts.method or (body and "POST" or "GET"),
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response),
    })

    return table.concat(response), tonumber(code), resp_headers or {}, status
end

function Client:request_follow(opts, max_redirects)
    max_redirects = max_redirects or 5
    local url = opts.url
    for redirect_index = 1, max_redirects + 1 do
        opts.url = url
        local text, code, resp_headers, status = self:request(opts)
        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            local location = header_value(resp_headers, "location")
            if not location then
                return text, code, resp_headers, status
            end
            url = absolute_url(url, location)
            opts.method = "GET"
            opts.body = nil
            opts.headers = opts.headers or {}
            opts.headers["Content-Length"] = nil
        else
            return text, code, resp_headers, status
        end
    end
    error("Too many redirects")
end

function Client:post_json(url, data, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Content-Type"] = "application/json;charset=UTF-8",
        ["Origin"] = "https://weread.qq.com",
        ["Referer"] = opts.referer or "https://weread.qq.com/",
    }
    local cookie_header = Cookie.to_header(cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "POST",
        headers = headers,
        body = self:json_encode(data),
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return self:json_decode(text), code, resp_headers
    end
    error(("HTTP %s: %s"):format(tostring(code), text or ""))
end

function Client:get_text(url, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = opts.accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Referer"] = opts.referer or "https://weread.qq.com/",
        ["Cookie"] = Cookie.to_header(cookies),
    }
    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = headers,
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return text
    end
    error(("HTTP %s: %s"):format(tostring(code), text or ""))
end

function Client:get_public_text(url, opts)
    opts = opts or {}
    local text, code, resp_headers = self:request_follow({
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = opts.accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = opts.referer or "https://mp.weixin.qq.com/",
        },
    })
    if code and code >= 200 and code < 300 then
        return text, {
            code = code,
            content_type = header_value(resp_headers, "content-type"),
            length = #(text or ""),
            url = url,
        }
    end
    error(("HTTP %s: %s"):format(tostring(code), text and text:sub(1, 200) or ""))
end

function Client:get_binary(url, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = opts.accept or "*/*",
        ["Referer"] = opts.referer or "https://weread.qq.com/",
        ["Cookie"] = Cookie.to_header(cookies),
    }
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end
    local text, code, resp_headers = self:request_follow({
        url = url,
        method = "GET",
        headers = headers,
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return text, code, resp_headers
    end
    error(("HTTP %s: %s"):format(tostring(code), text or ""))
end

function Client:renew_cookie()
    return self:post_json("https://weread.qq.com/web/login/renewal", {
        rq = "%2Fweb%2Fbook%2Fread",
        ql = false,
    })
end

function Client:gateway(api_name, params)
    params = params or {}
    params.api_name = api_name
    params.skill_version = params.skill_version or WeRead.SKILL_VERSION
    local api_key = self.settings:get("api_key", "")
    if api_key == "" then
        error("WeRead API key is not configured")
    end
    return self:post_json("https://i.weread.qq.com/api/agent/gateway", params, {
        headers = {
            ["Authorization"] = "Bearer " .. api_key,
        },
    })
end

function Client:get_book_info(book_id)
    return self:gateway("/book/info", { bookId = book_id })
end

function Client:get_progress(book_id)
    return self:gateway("/book/getprogress", { bookId = book_id })
end

function Client:get_mp_articles(book_id, max_idx, count, wr_ticket)
    local url = "https://weread.qq.com/web/mp/articles?bookId="
        .. WeRead.urlencode(book_id)
        .. "&maxIdx=" .. tostring(max_idx or 0)
        .. "&count=" .. tostring(count or 100)
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = "https://weread.qq.com/",
        ["Cookie"] = Cookie.to_header(cookies),
    }
    if wr_ticket and wr_ticket ~= "" then
        headers["x-wr-ticket"] = wr_ticket
    end
    local wrpa = self.settings:get("wr_wrpa", "")
    if wrpa ~= "" then
        headers["x-wrpa-0"] = wrpa
    end
    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = headers,
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        local data = self:json_decode(text)
        if data.errCode and data.errCode ~= 0 then
            return nil, data.errCode
        end
        return data, nil
    end
    error(("HTTP %s: %s"):format(tostring(code), text or ""))
end

function Client:get_mp_content(review_id, opts)
    opts = opts or {}
    local url = "https://weread.qq.com/web/mp/content?reviewId="
        .. WeRead.urlencode(review_id)
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = "text/html,application/xhtml+xml,*/*",
        ["Referer"] = opts.referer or "https://weread.qq.com/",
        ["Cookie"] = Cookie.to_header(cookies),
    }
    if not opts.skip_mp_auth_headers then
        local wr_ticket = self.settings:get("wr_ticket", "")
        if wr_ticket ~= "" then
            headers["x-wr-ticket"] = wr_ticket
        end
        local wrpa = self.settings:get("wr_wrpa", "")
        if wrpa ~= "" then
            headers["x-wrpa-0"] = wrpa
        end
    end
    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = headers,
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return text, {
            code = code,
            content_type = header_value(resp_headers, "content-type"),
            length = #(text or ""),
            url = url,
        }
    end
    error(("HTTP %s: %s"):format(tostring(code), text and text:sub(1, 200) or ""))
end

function Client:report_read(payload, referer)
    return self:post_json("https://weread.qq.com/web/book/read", payload, {
        referer = referer or "https://weread.qq.com/",
    })
end

return Client
