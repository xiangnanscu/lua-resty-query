local driver = require "resty.mysql"
local type = type
local tostring = tostring
local setmetatable = setmetatable
local table_concat = table.concat
local string_format = string.format

local CONNECT_TIMEOUT = 1000
local MAX_IDLE_TIMEOUT = 10000
local POOL_SIZE = 100
local function get_connect_table(options)
    return { 
        host            = options.HOST or "127.0.0.1", 
        port            = options.PORT or 3306, 
        database        = options.DATABASE or "test", 
        user            = options.USER or 'root', 
        password        = options.PASSWORD or '', 
        charset         = options.CHARSET or 'utf8',
        max_packet_size = options.MAX_PACKET_SIZE or 1024*1024,
        ssl             = options.SSL or false,
        ssl_verify      = options.SSL_VERIFY or false,
        compact_arrays  = options.COMPACT_ARRAYS or false,
        path            = options.PATH or nil,
        pool            = options.POOL or nil,
    }
end

local function Query(options)
    options = options or {}
    local connect_table = get_connect_table(options)
    local connect_timeout = options.CONNECT_TIMEOUT or CONNECT_TIMEOUT
    local max_idle_timeout = options.MAX_IDLE_TIMEOUT or MAX_IDLE_TIMEOUT
    local pool_size = options.POOL_SIZE or POOL_SIZE
    
    local function _query(statement, compact, rows)
        -- ngx.log(ngx.ERR, statement)
        local db, res, ok, err, errno, sqlstate
        db, err = driver:new()
        if not db then
            return nil, err
        end
        db:set_timeout(connect_timeout) 
        res, err, errno, sqlstate = db:connect(connect_table)
        if not res then
            return nil, err, errno, sqlstate
        end
        db.compact = compact
        res, err, errno, sqlstate =  db:query(statement, rows)
        if res ~= nil then
            ok, err = db:set_keepalive(max_idle_timeout, pool_size)
            if not ok then
                return nil, 'fail to set_keepalive:'..err
            end
        end
        return res, err, errno, sqlstate
    end
    
    local function _queries(statements, compact, rows)
        -- https://github.com/openresty/lua-resty-mysql#multi-resultset-support
        local db, res, ok, err, errno, sqlstate, bytes
        db, err = driver:new()
        if not db then
            return nil, err
        end
        db:set_timeout(connect_timeout) 
        res, err, errno, sqlstate = db:connect(connect_table)
        if not res then
            return nil, err, errno, sqlstate
        end
        db.compact = compact
        bytes, err = db:send_query(statements)
        if not bytes then
            return nil, "failed to send query: " .. err
        end
        local t = {}
        while true do
            res, err, errno, sqlstate = db:read_result(rows)
            if not res then
                -- according to official docs, further actions should stop if any error occurs
                return nil, string_format('bad result #%s: %s', #t+1, err), errcode, sqlstate
            end
            t[#t+1] = res
            if err ~= 'again' then
                local ok, err = db:set_keepalive(max_idle_timeout, pool_size)
                if not ok then
                    return nil, 'fail to set_keepalive:'..err
                else
                    return t
                end
            end
        end
        return t
    end

    local function __call(statement, compact, rows)
        if type(statement) == 'string' then
            return _query(statement, compact, rows)
        else
            return _queries(table_concat(statement,';'), compact, rows)
        end
    end

    return __call
end

return Query