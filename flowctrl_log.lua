-- con_limit 对象 的 leave 方法 连接数计数控制
local function fc_con_limit_leave()
	local ctx = ngx.ctx
	local con_limit = ctx.con_limit
	-- 拿到上文的con_limit对象
	if con_limit then
		local con_latency = tonumber(ngx.var.request_time) - tonumber(ctx.con_limit_delay)
		local con_limit_key = ctx.con_limit_key
		assert(con_limit_key)
		-- 调用con_limit对象的leaving方法, 操作并发数计数 
		local con, err = con_limit:leaving(con_limit_key, con_latency)
		if not con then
			ngx.log(ngx.ERR,
					"failed to record the connection leaving ",
					"request: ", err)
			return
		end
	end
end


-- start here 

fc_con_limit_leave()
