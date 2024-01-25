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
  PGHOST = 'localhost',
  PGPORT = 5432,
  PGUSER = 'postgres',
  PGPASSWORD = 'XXXXXX',
  PGDATABASE = 'test',
  POOL_SIZE = 50,
}
-- now use this function in your controllers
local res, err = query('select * from usr')
if res == nil then
  return err
end
```
