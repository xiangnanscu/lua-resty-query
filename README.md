# lua-resty-query

convenient wrapper for pgmoon

# install

```sh
opm get xiangnanscu/lua-resty-query
```

# Requirements

- [pgmoon](https://github.com/xiangnanscu/pgmoon)
- [lua-resty-dotenv](https://github.com/xiangnanscu/lua-resty-dotenv) (optional)

# Synopsis

```lua
local Query = require"resty.query"

-- config your database and get a query function
local query = Query {
  HOST = 'localhost',
  PORT = 5432,
  USER = 'postgres',
  PASSWORD = 'XXXXXX',
  DATABASE = 'test',
  CONNECT_TIMEOUT = 10000, -- 10 seconds
  MAX_IDLE_TIMEOUT = 10000,-- 10 seconds
  POOL = nil,
  POOL_SIZE = 50,
  SSL = false,
  SSL_VERIFY = nil,
  SSL_REQUIRED = nil,
  DEBUG = true,
}
-- now use this function in your controllers
local res, err = query('select * from usr')
if res == nil then
  return err
end
```
