local resty_mlcache = require "resty.mlcache"


local type    = type
local max     = math.max
local ngx_log = ngx.log
local ngx_now = ngx.now
local ERR     = ngx.ERR
local NOTICE  = ngx.NOTICE
local DEBUG   = ngx.DEBUG


--[[
Hypothesis
----------

Item size:        1024 bytes
Max memory limit: 500 MiBs

LRU size must be: (500 * 2^20) / 1024 = 512000
Floored: 500.000 items should be a good default
--]]
local LRU_SIZE = 5e5


-------------------------------------------------------------------------------
-- NOTE: the following is copied from lua-resty-mlcache:                     --
------------------------------------------------------------------------ cut --
local cjson = require "cjson.safe"


local fmt = string.format
local now = ngx.now


local TYPES_LOOKUP = {
  number  = 1,
  boolean = 2,
  string  = 3,
  table   = 4,
}


local marshallers = {
  shm_value = function(str_value, value_type, at, ttl)
      return fmt("%d:%f:%f:%s", value_type, at, ttl, str_value)
  end,

  shm_nil = function(at, ttl)
      return fmt("0:%f:%f:", at, ttl)
  end,

  [1] = function(number) -- number
      return tostring(number)
  end,

  [2] = function(bool)   -- boolean
      return bool and "true" or "false"
  end,

  [3] = function(str)    -- string
      return str
  end,

  [4] = function(t)      -- table
      local json, err = cjson.encode(t)
      if not json then
          return nil, "could not encode table value: " .. err
      end

      return json
  end,
}

----------------------------------------------------------------
--- name:     marshall_for_shm
--- function: 推断为缓存数据格式化，待考证
--- param:    value    table     批量查找的key         M
---           ttl      number    缓存到期时间
---           neg_ttl  number    未命中缓存到期时间
--- return:   res     格式化后的数据
---           nil     表示未命中返回错误
----------------------------------------------------------------

local function marshall_for_shm(value, ttl, neg_ttl)
  local at = now()

  -- 格式化字符串0：当前时间：miss失效时间
  if value == nil then
      return marshallers.shm_nil(at, neg_ttl), nil, true -- is_nil
  end

  -- serialize insertion time + Lua types for shm storage
  -- value_type = 1,2,3,4
  local value_type = TYPES_LOOKUP[type(value)]

  -- 判断是否是缓存类型
  if not marshallers[value_type] then
      error("cannot cache value of type " .. type(value))
  end

  local str_marshalled, err = marshallers[value_type](value)
  if not str_marshalled then
      return nil, "could not serialize value for lua_shared_dict insertion: "
                  .. err
  end
  -- 返回格式化的数据
  return marshallers.shm_value(str_marshalled, value_type, at, ttl)
end
------------------------------------------------------------------------ end --


local _init


local function log(lvl, ...)
  return ngx_log(lvl, "[DB cache] ", ...)
end


local _M = {}
local mt = { __index = _M }


function _M.new(opts)
  if _init then
    error("kong.cache was already created", 2)
  end

  -- opts validation

  opts = opts or {}

  if not opts.cluster_events then
    error("opts.cluster_events is required", 2)
  end

  if not opts.worker_events then
    error("opts.worker_events is required", 2)
  end

  if opts.propagation_delay and type(opts.propagation_delay) ~= "number" then
    error("opts.propagation_delay must be a number", 2)
  end

  if opts.ttl and type(opts.ttl) ~= "number" then
    error("opts.ttl must be a number", 2)
  end

  if opts.neg_ttl and type(opts.neg_ttl) ~= "number" then
    error("opts.neg_ttl must be a number", 2)
  end

  if opts.cache_pages and opts.cache_pages ~= 1 and opts.cache_pages ~= 2 then
    error("opts.cache_pages must be 1 or 2", 2)
  end

  if opts.resty_lock_opts and type(opts.resty_lock_opts) ~= "table" then
    error("opts.resty_lock_opts must be a table", 2)
  end

  local mlcaches = {}
  local shm_names = {}
  -- 通过三元法给变量命名
  -- 如果是db-less，cache_pages=2，那么mlcaches={mlcache1,mlcache2},shm_names={"kong_db_cache","kong_db_cache_2"}
  for i = 1, opts.cache_pages or 1 do
    local channel_name  = (i == 1) and "mlcache"            or "mlcache_2"
    local shm_name      = (i == 1) and "kong_db_cache"      or "kong_db_cache_2"
    local shm_miss_name = (i == 1) and "kong_db_cache_miss" or "kong_db_cache_miss_2"

    if ngx.shared[shm_name] then
      local mlcache, err = resty_mlcache.new(shm_name, shm_name, {
        shm_miss         = shm_miss_name,                               -- 未命中记录的缓存目录lua_shared_dict2
        shm_locks        = "kong_locks",                                -- 一种lua_shared_dict，用来存放lua-resty-lock的锁
        shm_set_retries  = 3,                                           -- lua_shared_dict.set操作的重试次数
        lru_size         = LRU_SIZE,                                    -- 定义L1的缓存大小
        ttl              = max(opts.ttl     or 3600, 0),            -- 缓存到期时间
        neg_ttl          = max(opts.neg_ttl or 300,  0),            -- 指定缓存未命中过期时间，也就是L3回调函数返回nil，未触发缓存
        resurrect_ttl    = opts.resurrect_ttl or 30,
        resty_lock_opts  = opts.resty_lock_opts,                        -- 确保单个worker在运行L3的回调函数
        ipc = {
          register_listeners = function(events)
            for _, event_t in pairs(events) do
              opts.worker_events.register(function(data)
                event_t.handler(data)
              end, channel_name, event_t.channel)
            end
          end,
          broadcast = function(channel, data)
            local ok, err = opts.worker_events.post(channel_name, channel, data)
            if not ok then
              log(ERR, "failed to post event '", channel_name, "', '",
                       channel, "': ", err)
            end
          end
        }
      })
      if not mlcache then
        return nil, "failed to instantiate mlcache: " .. err
      end
      mlcaches[i] = mlcache
      shm_names[i] = shm_name
    end
  end

  local self          = {
    propagation_delay = max(opts.propagation_delay or 0, 0),
    cluster_events    = opts.cluster_events,
    mlcache           = mlcaches[1],
    mlcaches          = mlcaches,
    shm_names         = shm_names,
    curr_mlcache      = 1,
  }

  local ok, err = self.cluster_events:subscribe("invalidations", function(key)
    log(DEBUG, "received invalidate event from cluster for key: '", key, "'")
    self:invalidate_local(key)
  end)
  if not ok then
    return nil, "failed to subscribe to invalidations cluster events " ..
                "channel: " .. err
  end

  _init = true

  return setmetatable(self, mt)
end

----------------------------------------------------------------
--- name:     get
--- function: 执行缓存查找
--- param:    key     string    每个值的key         M
---           opts    table     存储key所需要的值   O
---           cb      function  L3回调函数
--- return:   v       返回命中的值
---           nil     表示未命中
----------------------------------------------------------------
function _M:get(key, opts, cb, ...)
  if type(key) ~= "string" then
    error("key must be a string", 2)
  end

  --log(DEBUG, "get from key: ", key)

  local v, err = self.mlcache:get(key, opts, cb, ...)
  if err then
    return nil, "failed to get from node cache: " .. err
  end

  return v
end

----------------------------------------------------------------
--- name:     get_bulk
--- function: 批量执行缓存查找
--- param:    bulk    table     批量查找的key         M
---           opts    table     查找key所需要的值     O
--- return:   res     以table形式返回批量查找的值
---           nil     表示未命中返回错误
----------------------------------------------------------------

function _M:get_bulk(bulk, opts)
  if type(bulk) ~= "table" then
    error("bulk must be a table", 2)
  end

  if opts ~= nil and type(opts) ~= "table" then
    error("opts must be a table", 2)
  end

  local res, err = self.mlcache:get_bulk(bulk, opts)
  if err then
    return nil, "failed to get_bulk from node cache: " .. err
  end

  return res
end

----------------------------------------------------------------
--- name:     safe_set
--- function: 批量执行缓存查找
--- param:    key           string    批量查找的key
---           value         table     查找key所需要的值
---           shadow_page   boolean   虚拟页标志位
--- return:   res     以table形式返回批量查找的值
---           nil     表示未命中返回错误
----------------------------------------------------------------

function _M:safe_set(key, value, shadow_page)
  local str_marshalled, err = marshall_for_shm(value, self.mlcache.ttl,
                                                      self.mlcache.neg_ttl)
  if err then
    return nil, err
  end

  local page = 1
  -- 如果是db-less模式，#self.mlcaches为2
  -- shadow_page目前看来为true，page为2
  if shadow_page and #self.mlcaches == 2 then
    page = (self.curr_mlcache == 1) and 2 or 1
  end
  -- 如果db模式，shm_name="kong_db_cache",
  -- db-less模式，shm_name="kong_db_cache2"
  local shm_name = self.shm_names[page]
  -- 向共享空间存入数据
  return ngx.shared[shm_name]:safe_set(shm_name .. key, str_marshalled)
end


function _M:probe(key)
  if type(key) ~= "string" then
    error("key must be a string", 2)
  end

  local ttl, err, v = self.mlcache:peek(key)
  if err then
    return nil, "failed to probe from node cache: " .. err
  end

  return ttl, nil, v
end


function _M:invalidate_local(key)
  if type(key) ~= "string" then
    error("key must be a string", 2)
  end

  log(DEBUG, "invalidating (local): '", key, "'")

  local ok, err = self.mlcache:delete(key)
  if not ok then
    log(ERR, "failed to delete entity from node cache: ", err)
  end
end


function _M:invalidate(key)
  if type(key) ~= "string" then
    error("key must be a string", 2)
  end

  self:invalidate_local(key)

  local nbf
  if self.propagation_delay > 0 then
    nbf = ngx_now() + self.propagation_delay
  end

  log(DEBUG, "broadcasting (cluster) invalidation for key: '", key, "' ",
             "with nbf: '", nbf or "none", "'")

  local ok, err = self.cluster_events:broadcast("invalidations", key, nbf)
  if not ok then
    log(ERR, "failed to broadcast cached entity invalidation: ", err)
  end
end

----------------------------------------------------------------
--- name:     purge
--- function: 在L1和L2清除缓存
--- param:    shadow_page    boolean     批量查找的key         M
---           opts    table     查找key所需要的值     O
--- return:   res     以table形式返回批量查找的值
---           nil     表示未命中返回错误
----------------------------------------------------------------
function _M:purge(shadow_page)
  log(NOTICE, "purging (local) cache")

  local page = 1
  if shadow_page and #self.mlcaches == 2 then
    page = (self.curr_mlcache == 1) and 2 or 1
  end

  local ok, err = self.mlcaches[page]:purge()
  if not ok then
    log(ERR, "failed to purge cache: ", err)
  end
end


function _M:flip()
  if #self.mlcaches == 1 then
    return
  end

  log(DEBUG, "flipping current cache")

  self.curr_mlcache = (self.curr_mlcache == 1) and 2 or 1
  self.mlcache = self.mlcaches[self.curr_mlcache]
end


return _M
