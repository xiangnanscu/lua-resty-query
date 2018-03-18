# lua-resty-query
Wrapper for querying mysql and postgresql database in Openresty. Just config database -> Give sql string -> get data

# Requirements
Same as [lua-resty-mysql](https://github.com/openresty/lua-resty-mysql) or [pgmoon](https://github.com/leafo/pgmoon)

# Synopsis
```
local Query = require"resty.query".postgresql

-- config your database and get a query function
local query = Query{
    HOST = 'localhost',
    PORT = 5432,
    USER = 'postgres',
    PASSWORD = '111111',
    DATABASE = 'test',
    POOL_SIZE = 50,
}
-- now use this function in your controllers
local res, err = query('select * from "user"')
if err then
    return err
end

```
