local debug = debug
local string = string
local setmetatable = setmetatable

local function _classname()
    local ret = {}
    local function _sub(w)
        ret[#ret + 1] = w
    end
    local info = debug.getinfo(2, "S")
    string.gsub(info.short_src, '[^%/]+', _sub)
    return string.sub(ret[#ret], 1, -5)
end

return function(super, meta)
    local cls = {}
    if type(super) == "table" then
        meta = meta or {}
        meta.__index = super -- 既有原表又有父类,则__index优先使用父类
        cls = setmetatable(cls, meta)
        cls.super = super
    elseif meta then
        cls = setmetatable(cls, meta)
    end

    cls.__cname = _classname()
    cls.__index = cls
    cls.ctor = cls.ctor or function()
    end

    function cls.new(...)
        local instance = setmetatable({
            __class = cls,
        }, cls)
        instance:ctor(...)
        return instance
    end

    return cls
end
