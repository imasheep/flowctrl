-- import packages
redis = require 'resty.redis'
limit_con = require 'resty.limit.conn'
limit_req = require 'resty.limit.req'
math = require 'math'
os = require 'os'


-- define globle vars 

-- redis 配置信息
redis_sock_file = "/data/logs/redis_logs/redis.sock"
-- 定义内存共享区域
req_limit_store = "req_limit_store"
con_limit_store = "con_limit_store"
-- 定义redis最大尝试连接次数
redis_connect_retry_max = 3 -- redis connect max retry time 
-- 定义命中流控状态码 req : 598, con : 599
req_error_status = 598
con_error_status = 599
-- 定义需要不需要不延迟处理
nodelay_swtich = false
-- req key 默认配置定义
req_limit_default_rate = 100000
req_limit_default_burst = math.floor(req_limit_default_rate/2)
-- con key 默认配置定义
con_limit_default_rate = 1000
con_limit_default_burst = math.floor(con_limit_default_rate/2)
con_limit_standard_default_delay = 0.5
-- 日志 receiver
log_receive_host = 127.0.0.1
log_receive_port = 514
-- 日志 prefix
log_prefix_flag = "FlowCtrl"

