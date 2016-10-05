# lua-resty-query

wrapper for lua-resty-mysql

# Requirements
Same as lua-resty-mysql

# Synopsis
```
local single_query = require"lua.resty.query".single
local multi_query = require"lua.resty.query".multiple
local encode = require"cjson".encode

local res, err = single_query "select * from user;"
if not res then
    ngx.print(err)
else
    ngx.print(encode(res))
end

local res, err = single_query "select * from user where id=1;select * from user where id=2;"
if not res then
    ngx.print(err)
else
    ngx.print(encode(res))
end

```
