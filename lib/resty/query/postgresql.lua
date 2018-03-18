local driver = require "pgmoon"
local type = type
local tostring = tostring
local setmetatable = setmetatable
local table_concat = table.concat
local string_format = string.format

local version = "2.0"

local CONNECT_TIMEOUT = 1000
local MAX_IDLE_TIMEOUT = 10000
local POOL_SIZE = 100
local function get_connect_table(options)
    return { 
        host         = options.HOST or "127.0.0.1", 
        port         = options.PORT or 5432, 
        database     = options.DATABASE or "test", 
        user         = options.USER or 'postgres', 
        password     = options.PASSWORD or '', 
        ssl          = options.SSL or false,
        ssl_verify   = options.SSL_VERIFY or nil,
        ssl_required = options.SSL_REQUIRED or nil,
        socket_type  = options.SOCKET_TYPE or nil,
        pool         = options.POOL or nil,
    }
end


local function Query(options)
    options = options or {}
    local connect_table = get_connect_table(options)
    local connect_timeout = options.CONNECT_TIMEOUT or CONNECT_TIMEOUT
    local max_idle_timeout = options.MAX_IDLE_TIMEOUT or MAX_IDLE_TIMEOUT
    local pool_size = options.POOL_SIZE or POOL_SIZE
    
    local function _query(statement)
        -- ngx.log(ngx.ERR, statement)
        local db, ok, err, a, b, c, d, e -- pgmoon strange api design
        db = driver.new(connect_table) 
        db:settimeout(connect_timeout) 
        ok, err = db:connect()
        if not ok then
            return nil, err
        end
        -- https://github.com/leafo/pgmoon/blob/master/pgmoon/init.lua#L335
        -- nil,    err_msg,     result,       num_queries, notifications
        -- result, num_queries, notifications
        a, b, c, d, e =  db:query(statement) 
        if a ~= nil then
            ok, err = db:keepalive(idle_timeout, pool_size)
            if not ok then
                return nil, 'fail to set_keepalive:'..err
            end
        end
        return a, b, c, d, e
    end
    -- local function __call(statement)
    --     if type(statement) == 'string' then
    --         return _query(statement)
    --     else
    --         return _query(table_concat(statement, ';'))
    --     end
    -- end    
    return _query
end

return Query