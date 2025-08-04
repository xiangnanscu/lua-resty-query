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
local ngx           = ngx


---@class QueryOpts
---@field DATABASE? string
---@field HOST? string the host to connect to (default: "127.0.0.1")
---@field PORT? number|string the port to connect to (default: "5432")
---@field USER? string the database username to authenticate (default: "postgres")
---@field PASSWORD? string password for authentication, may be required depending on server configuration
---@field POOL_NAME? string OpenResty only, name of pool to use when using OpenResty cosocket (default: "#{host}:#{port}:#{database}:#{user}")
---@field POOL_SIZE? number OpenResty only, Passed directly to OpenResty cosocket connect function
---@field SSL? boolean enable SSL
---@field SSL_VERIFY? boolean verify server certificate
---@field SSL_REQUIRED? boolean abort if the server does not support SSL connections
---@field SSL_VERSION? string efaults to highest available, no less than TLS v1.1
---@field CONNECT_TIMEOUT? number set the timeout value in milliseconds for subsequent socket operations (connect, receive, and iterators returned from receiveuntil).
---@field MAX_IDLE_TIMEOUT? number can be used to specify the maximal idle timeout (in milliseconds) for the current connection. If omitted, the default setting in the lua_socket_keepalive_timeout config directive will be used. If the 0 value is given, then the timeout interval is unlimited
---@field SOCKET_TYPE? string the type of socket to use, one of: "nginx", "luasocket", cqueues (default: "nginx" if in nginx, "luasocket" otherwise)
---@field APPLICATION_NAME? string
---@field BACKLOG? number OpenResty only, specify the size of the connection pool. If omitted and no backlog option was provided, no pool will be created. If omitted but backlog was provided, the pool will be created with a default size equal to the value of the lua_socket_pool_size directive
---@field DEBUG? boolean|function

---@class ConnOpts
---@field database string
---@field host string
---@field port number|string
---@field user string
---@field password? string
---@field pool_name? string OpenResty only, name of pool to use when using OpenResty cosocket (default: "#{host}:#{port}:#{database}:#{user}")
---@field pool_size? number OpenResty only, Passed directly to OpenResty cosocket connect function
---@field ssl? boolean enable SSL
---@field ssl_verify? boolean verify server certificate
---@field ssl_required? boolean abort if the server does not support SSL connections
---@field ssl_version? string defaults to highest available, no less than TLS v1.1
---@field connect_timeout? number set the timeout value in milliseconds for subsequent socket operations (connect, receive, and iterators returned from receiveuntil).
---@field max_idle_timeout number can be used to specify the maximal idle timeout (in milliseconds) for the current connection. If omitted, the default setting in the lua_socket_keepalive_timeout config directive will be used. If the 0 value is given, then the timeout interval is unlimited
---@field socket_type string the type of socket to use, one of: "nginx", "luasocket", cqueues (default: "nginx" if in nginx, "luasocket" otherwise)
---@field application_name string set the name of the connection as displayed in pg_stat_activity. (default: "pgmoon")
---@field backlog number OpenResty only, specify the size of the connection pool. If omitted and no backlog option was provided, no pool will be created. If omitted but backlog was provided, the pool will be created with a default size equal to the value of the lua_socket_pool_size directive
---@field debug boolean|function

---@class PgmoonConn
---@field sock_type string
---@field query fun(self: PgmoonConn, statement: string): table, number, table, string[]
---@field keepalive fun(self: PgmoonConn, max_idle_timeout: number): boolean, string
---@field disconnect fun(self: PgmoonConn): boolean, string
---@field compact? boolean

---@param options QueryOpts
---@return ConnOpts
local function get_connect_table(options)
  local res = {
    host = options.HOST or ENV_CONFIG.PGHOST or "127.0.0.1",
    port = options.PORT or tonumber(ENV_CONFIG.PGPORT) or 5432,
    database = options.DATABASE or ENV_CONFIG.PGDATABASE or "postgres",
    user = options.USER or ENV_CONFIG.PGUSER or "postgres",
    password = options.PASSWORD or ENV_CONFIG.PGPASSWORD,
    ssl = options.SSL or ENV_CONFIG.PG_SSL == "true" or false,
    ssl_verify = options.SSL_VERIFY or ENV_CONFIG.PG_SSL_VERIFY or nil,
    ssl_required = options.SSL_REQUIRED or ENV_CONFIG.PG_SSL_REQUIRED or nil,
    pool_name = options.POOL_NAME or ENV_CONFIG.PG_POOL_NAME or nil,
    pool_size = options.POOL_SIZE or tonumber(ENV_CONFIG.PG_POOL_SIZE) or 100,
    connect_timeout = options.CONNECT_TIMEOUT or tonumber(ENV_CONFIG.PG_CONNECT_TIMEOUT) or 10000,
    max_idle_timeout = options.MAX_IDLE_TIMEOUT or tonumber(ENV_CONFIG.PG_MAX_IDLE_TIMEOUT) or 10000,
    socket_type = options.SOCKET_TYPE,
    application_name = options.APPLICATION_NAME,
    backlog = options.BACKLOG,
    debug = options.DEBUG,
  }
  if not res.pool_name then
    res.pool_name = tostring(res.host) ..
        ":" .. tostring(res.port) ..
        ":" .. tostring(res.database) ..
        ":" .. tostring(res.user)
  end
  return res
end

---@param statement Xodel|table
---@return string
local function process_statement_table(statement)
  if type(statement.statement) == 'function' then
    ---@cast statement Xodel
    return statement:statement()
  elseif statement[1] then
    ---@cast statement table
    local statements = {}
    for _, query in ipairs(statement) do
      if type(query) == 'string' then
        if query ~= "" then
          statements[#statements + 1] = query
        end
      elseif type(query) == 'table' and type(query.statement) == 'function' then
        statements[#statements + 1] = query:statement()
      else
        error(string_format("invalid type '%s' for statements passing to query", type(query)))
      end
    end
    return table_concat(statements, ";")
  else
    error("empty table passed to query")
  end
end

---@class ConnProxy
---@field conn PgmoonConn
---@field options ConnOpts
local ConnProxy = {}
ConnProxy.__index = ConnProxy

ConnProxy.__call = function(self, attrs)
  return self:new(attrs or {})
end

function ConnProxy:new(attrs)
  return setmetatable(attrs or {}, self)
end

function ConnProxy:release()
  local ok, err
  if self.conn.sock_type == "nginx" then
    ok, err = self:keepalive()
  else
    ok, err = self:disconnect()
  end
  if not ok then
    ngx.log(ngx.ERR, err)
  end
  return ok, err
end

function ConnProxy:keepalive()
  return self.conn:keepalive(self.options.max_idle_timeout)
end

function ConnProxy:disconnect()
  return self.conn:disconnect()
end

---@param statement string|table
---@param compact? boolean
---@return table result query result table
---@return number num_queries number of queries
---@return table notifications notifications
---@return string[] notices notices
function ConnProxy:query(statement, compact)
  if type(statement) == 'table' then
    statement = process_statement_table(statement)
  end
  if self.options.debug then
    if type(self.options.debug) ~= 'function' then
      print(statement)
    else
      self.options.debug(statement)
    end
  end
  self.conn.compact = compact
  local result, num_queries, notifications, notices = self.conn:query(statement)
  if result == nil then
    -- ignore the rest return values when error
    error(num_queries)
  else
    return result, num_queries, notifications, notices
  end
end

function ConnProxy:begin()
  return self:query("BEGIN")
end

function ConnProxy:commit()
  return self:query("COMMIT")
end

function ConnProxy:savepoint(name)
  return self:query("SAVEPOINT " .. name)
end

function ConnProxy:rollback()
  return self:query("ROLLBACK")
end

function ConnProxy:rollback_to(name)
  return self:query("ROLLBACK TO SAVEPOINT " .. name)
end

-- function ConnProxy:release(name)
--   return self:query("RELEASE SAVEPOINT " .. name)
-- end

---@param options? QueryOpts
local function Query(options)
  options = options or {}
  local connect_table = get_connect_table(options)
  local connect_timeout = connect_table.connect_timeout
  -- local max_idle_timeout = connect_table.max_idle_timeout
  -- local pool_size = connect_table.pool_size

  ---@return ConnProxy
  local function make_conn()
    local conn = pgmoon.new(connect_table)
    conn:settimeout(connect_timeout)
    local ok, err = conn:connect()
    if not ok then
      error(err)
    end
    return ConnProxy:new { conn = conn, options = connect_table }
  end

  local function get_conn()
    local conn = ngx and ngx.ctx._transaction_conn
    if conn then
      return conn, true
    end
    return make_conn(), false
  end


  ---@param statement string|table
  ---@param compact? boolean
  ---@return table result query result table
  ---@return number num_queries number of queries
  ---@return table notifications notifications
  ---@return string[] notices notices
  local function send_query(statement, compact)
    -- https://github.com/xiangnanscu/pgmoon/blob/master/pgmoon/init.lua#L545
    -- nil,  err_msg, result, num_queries, notifications, notices
    -- result, num_queries, notifications, notices
    -- loger(connect_table)
    local conn, is_transaction = get_conn()
    local result, num_queries, notifications, notices = conn:query(statement, compact)
    if not is_transaction then
      conn:release()
    end
    return result, num_queries, notifications, notices
  end


  local function transaction(callback)
    if ngx and ngx.ctx._transaction_conn then
      return nil, "transaction already started"
    end
    local conn = make_conn()
    conn:begin()
    if ngx then
      ngx.ctx._transaction_conn = conn
    end
    local ok, cb_res, cb_err, cb_status = pcall(callback, conn)
    if ngx then
      ngx.ctx._transaction_conn = nil
    end
    if not ok then
      conn:rollback()
      return nil, cb_res
    end
    conn:commit()
    conn:release()
    return cb_res, cb_err, cb_status
  end


  return setmetatable({
    query = send_query,
    transaction = transaction
  }, {
    __call = function(t, ...)
      return send_query(...)
    end
  })
end

return Query
