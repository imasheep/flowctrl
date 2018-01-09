-- udp 发送日志到rsyslog
local function fc_log(log_level_flag, content)
	if content == ngx.null or content == nil then
		content = ''
	end
    sock = ngx.socket.udp()
    local ok, err = sock:setpeername(log_receive_host, log_receive_port)
    if not ok then
        ngx.log(ngx.ERR, 'failed to set udp peer')
        return
    end
	local current_timeflag = os.date("%Y%m%d-%H:%M:%S")

    ok, err = sock:send("[" .. log_prefix_flag .. "] [" .. log_level_flag .. "] [" .. current_timeflag .. "] [" .. content .. "]")
    if not ok then
        ngx.log(ngx.ERR, 'failed to send log: ' .. content)
        sock:close()
        return
    end

    sock:close()
end

-- 连接 redis
local function new_redis()

    local sock_file
    local red = redis:new()

    red:set_timeout(1000)

	sock_file = "unix:" .. redis_sock_file

	-- 失败重连
	math.randomseed(os.time())
	local redis_id = math.random(0, 2)
	for con_count = 1, redis_connect_retry_max do
		local ok, err = red:connect(sock_file .. redis_id)
		if ok then
			return red
		end
		redis_id = (redis_id + 1) % 3
		fc_log("ERROR", "Connect redis " .. sock_file .. redis_id .. " failed: " .. err .. ", trycount: " .. con_count)
	end
    return nil
end



-- list转table
local function list_to_table(list)

    local res = {}

    for idx = 1, #(list), 2 do
        res[list[idx]] = list[idx + 1]
    end

    return res
end

-- key 配置获取
local function get_key_config(key)

    local res, err = red:hgetall(key)

    if not res or #res == 0 then
        return nil
    end

    local conf = list_to_table(res)
    return conf
end
-- redis key 值获取
local function get_value(key)
	local res, err = red:get(key)
	if res == ngx.null  then
		return nil
	else
		return res
	end
end

-- req limit 模块
local function fc_req_limit()

	-- req limit 开关
	if tonumber(flowctrl_conf.switch) == 1 then

		-- key
		local req_limit_key = ctrl_key
		-- 限流速率 漏斗算法
		local req_limit_rate = tonumber(flowctrl_conf.rate) or req_limit_default_rate
		-- 漏斗容量
		local req_limit_burst = tonumber(flowctrl_conf.burst) or req_limit_default_burst
		-- 获取limit对象
		local req_limit, err = limit_req.new(req_limit_store, req_limit_rate, req_limit_burst)
		-- 断言,抛出异常
		assert(req_limit, err)

		-- 接收请求,返回delay关键字
		local req_limit_delay, err = req_limit:incoming(req_limit_key, true)

		if not req_limit_delay then
			if err == "rejected" then
				-- 命中req limit 流控
				fc_log("WARNNING", "rejected : \"" .. req_limit_key .. "\" hit req limit ctrl ( rate : " .. req_limit_rate .. "; burst: " .. req_limit_burst .. " )")
				ngx.var.limit_status = "req_rejected"
				if degrade_conf and degrade_conf.switch == "2" then
					ngx.var.degrade_status = "auto"
					ngx.say(degrade_conf.content)
					ngx.exit(200)
				else
					return ngx.exit(req_error_status)
				end
			else
				ngx.exit(500)
			end
		end
		-- 进入漏斗
		if req_limit_delay >= 0.001 then
			-- nodelay 开关
			if nodelay_switch then
				-- 直接处理
			else
				-- 进入漏斗delay等待.
				ngx.var.limit_status = "req_delayed"
				-- fc_log("INFO", "delayed: \"" .. req_limit_key .. "\" hit req limit ctrl ( rate : " .. req_limit_rate .. "; burst: " .. req_limit_burst .. " )")
				ngx.sleep(req_limit_delay)
			end
		end
	end
end

-- con limit 模块
local function fc_con_limit()

	-- ngx.log(ngx.ERR, "access con limit" )

	-- con key 定义
	local con_limit_key = ngx.var.remote_addr

	-- con key 配置定义
	-- 并发链接数限制 漏斗算法
	local con_limit_rate = con_limit_default_rate
	-- 并发链接数 漏斗容量
	local con_limit_burst = con_limit_default_burst
	-- 默认单次请求时间 , 会被 con_limit对象的leaving方法动态调整. 只需要初始值
	local con_limit_standard_delay = con_limit_standard_default_delay

	-- 获取con_limit 对象
	local con_limit, err = limit_con.new(con_limit_store, con_limit_rate, con_limit_burst, con_limit_standard_delay)
	-- 断言, 抛出异常
	assert(con_limit, err)

	-- 接收请求,返回delay关键字
	local con_limit_delay, err = con_limit:incoming(con_limit_key, true)

	if not con_limit_delay then
		if err == "rejected" then
			-- 命中 con limit 流控
			fc_log("WARNNING", "rejected : \"" .. con_limit_key .. "\" hit con limit ctrl ( rate : " .. con_limit_rate .. "; burst: " .. con_limit_burst .. " )")
			ngx.var.limit_status = "con_rejected"
			return ngx.exit(con_error_status)
		else
			return ngx.exit(con_error_status)
		end
	end

	-- ngx 各个处理阶段上下文衔接, 从当前处理阶段(access)传递对象变量到 log 阶段
	if con_limit:is_committed() then
		local ctx = ngx.ctx
		ctx.con_limit = con_limit
		ctx.con_limit_key = con_limit_key
		ctx.con_limit_delay = con_limit_delay
	end

	-- 进入漏斗
	if con_limit_delay >= 0.001 then
		if nodelay_switch then
			-- 直接处理
		else
			ngx.var.limit_status = "con_delayed"
			fc_log("INFO", "delayed: \"" .. con_limit_key .. "\"hit con limit ctrl ( rate : " .. con_limit_rate .. "; burst: " .. con_limit_burst .. " )")
			-- 进入漏斗delay等待
			ngx.sleep(con_limit_delay)
		end
	end
end


local function get_ctrl_key()
	if ngx.var.http_host == nil then
        return
    end
    local domain_key = get_value("fc:domainkey:" .. ngx.var.http_host) or "m.davdian.com"
    -- req key 定义
    if ngx.var.uri_key == "" then
        uri_key = ngx.var.uri or "/"
    else
        uri_key = ngx.var.uri_key
    end

    local ctrl_key = domain_key .. uri_key
	return ctrl_key
end

local function get_wbip_ctrl()
	-- remote_addr 作为key
	local ip = ngx.var.remote_addr

	if ip and ip ~= '' then
		-- 获取开关状态  2 : 白名单, 1 : 黑名单 , nil(ngx.null) : 一般ip
		local wbip_switch, err = red:get("fc:wbipctrl:".. ip)

		if wbip_switch == ngx.null then
			return nil
		end
		
		return ip, wbip_switch
	end
end

local function req_forbid()
	ngx.status = 403
	ngx.say("Your IP: " .. ip .. " forbidden.")
	fc_log("INFO"," IP: " .. ip .. " forbidden.")
	return ngx.exit(ngx.HTTP_FORBIDDEN)
end


local function req_degrade()
	ngx.var.degrade_status = "on"
	ngx.say(degrade_conf.content)
	ngx.exit(200)
end

-- start here

-- 	获取redis链接
red = new_redis()
-- redis 链接失败后, 所有策略失效, 但不影响正常请求
if not red then return end

-- 优先处理 ip 黑白名单
ip, wbip_switch = get_wbip_ctrl()

if wbip_switch == "2" then return end  --白名单
if wbip_switch == "1" then req_forbid() end --黑名单


-- 获取全局key 如 m.davdian.com/test
ctrl_key = get_ctrl_key()
if ctrl_key == nil then return end

-- 获取降级配置
degrade_conf = get_key_config("fc:degradectrl:" .. ctrl_key)
if degrade_conf ~= nil then 
	if degrade_conf.switch == "1" then req_degrade() end --主动降级
end

-- 获取流控配置
flowctrl_conf = get_key_config("fc:flowctrl:" .. ctrl_key)
if flowctrl_conf ~= nil then 
	-- req limit
	fc_req_limit()
	-- con limit (阈值较大,基本不会命中)
	fc_con_limit()
end

-- 连接池实现
red:set_keepalive(10000, 1000)