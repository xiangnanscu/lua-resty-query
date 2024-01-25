# lua-resty-query
convenient wrapper for pgmoon

# Requirements
- [lua-resty-dotenv](https://github.com/xiangnanscu/lua-resty-dotenv)
- [pgmoon](https://github.com/xiangnanscu/pgmoon)

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
  POOL_SIZE = 50,
}
-- now use this function in your controllers
local res, err = query('select * from usr')
if res == nil then
  return err
end
```
