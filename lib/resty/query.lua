local pgmoon = require "pgmoon"
local ENV_CONFIG
do
  local ok, dotenv = pcall(require, "resty.dotenv")
  if ok then
    ENV_CONFIG = dotenv { '.env' }
  else
    ENV_CONFIG = {}
  end
end
local type          = type
local table_concat  = table.concat
local string_format = string.format


---@class QueryOpts
---@field HOST? string
---@field PORT? number|string
---@field USER? string
---@field DATABASE? string
---@field PASSWORD? string
---@field POOL_SIZE? number
---@field CONNECT_TIMEOUT? number
---@field MAX_IDLE_TIMEOUT? number
---@field SSL? boolean
---@field POOL? string
---@field SSL_REQUIRED? boolean
---@field SSL_VERIFY? any
---@field debug? function a function that will be called with the final generated statement


---@param options QueryOpts
---@return table
local function get_connect_table(options)
  return {
    host = options.HOST or ENV_CONFIG.PGHOST or "127.0.0.1",
    port = options.PORT or tonumber(ENV_CONFIG.PGPORT) or 5432,
    database = options.DATABASE or ENV_CONFIG.PGDATABASE or "",
    user = options.USER or ENV_CONFIG.PGUSER or "",
    password = options.PASSWORD or ENV_CONFIG.PGPASSWORD or "",
    ssl = options.SSL or ENV_CONFIG.PG_SSL == "true" or false,
    ssl_verify = options.SSL_VERIFY or ENV_CONFIG.PG_SSL_VERIFY or nil,
    ssl_required = options.SSL_REQUIRED or ENV_CONFIG.PG_SSL_REQUIRED or nil,
    pool = options.POOL or ENV_CONFIG.PG_POOL or nil,
    pool_size = options.POOL_SIZE or tonumber(ENV_CONFIG.PG_POOL_SIZE) or 100,
    connect_timeout = options.CONNECT_TIMEOUT or tonumber(ENV_CONFIG.PG_CONNECT_TIMEOUT) or 10000,
    max_idle_timeout = options.MAX_IDLE_TIMEOUT or tonumber(ENV_CONFIG.PG_MAX_IDLE_TIMEOUT) or 10000,
  }
end

---@param options QueryOpts
---@return fun(statement: string|table, compact?: boolean):table?, string|number?
local function Query(options)
  options = options or {}
  local connect_table = get_connect_table(options)
  local connect_timeout = connect_table.connect_timeout
  local max_idle_timeout = connect_table.max_idle_timeout
  local pool_size = connect_table.pool_size
  ---@param statement string|table
  ---@param compact? boolean
  ---@return table?, string|number?
  local function sql_query(statement, compact)
    local db, ok, err, a, b
    if type(statement) == 'table' then
      if type(statement.statement) == 'function' then
        statement, err = statement:statement()
        if statement == nil then
          return nil, err
        end
      elseif statement[1] then
        local statements = {}
        for _, query in ipairs(statement) do
          local stmt_to_add = nil
          if type(query) == 'string' then
            stmt_to_add = query
          elseif type(query) == 'table' and type(query.statement) == 'function' then
            stmt_to_add, err = query:statement()
            if stmt_to_add == nil then
              return nil, err
            end
          else
            return nil, string_format("invalid type '%s' for statements passing to query", type(query))
          end

          if stmt_to_add and stmt_to_add ~= "" then
            statements[#statements + 1] = stmt_to_add
          end
        end
        statement = table_concat(statements, ";")
        if statement == "" then
          return nil, "empty statements after processing table input"
        end
      else
        return nil, "invalid table format passed to query"
      end
    end
    db = pgmoon.new(connect_table)
    db:settimeout(connect_timeout)
    ok, err = db:connect()
    if not ok then
      return nil, err
    end
    -- https://github.com/xiangnanscu/pgmoon/blob/master/pgmoon/init.lua#L545
    -- nil,  err_msg,   result,     num_queries, notifications
    -- result, num_queries, notifications
    db.compact = compact
    a, b = db:query(statement)
    if options.debug then
      options.debug(statement)
    end
    if db.sock_type == "nginx" then
      if a ~= nil then
        ok, err = db:keepalive(max_idle_timeout, pool_size)
        if not ok then
          return nil, "fail to keepalive:" .. err
        else
          return a, b
        end
      else
        return nil, b
      end
    else
      if a == nil then
        return nil, b
      else
        ok, err = db:disconnect()
        if not ok then
          return nil, "fail to disconnect:" .. err
        else
          return a, b
        end
      end
    end
  end

  return sql_query
end

return Query
