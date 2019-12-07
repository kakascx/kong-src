# kong-src
kong源码分析
# nginx-kong.conf


```
charset UTF-8;

error_log syslog:server=kong-hf.konghq.com:61828 error;

error_log logs/error.log notice;


client_max_body_size 0;
proxy_ssl_server_name on;
underscores_in_headers on;

lua_package_path './?.lua;./?/init.lua;;;';
lua_package_cpath ';;';
lua_socket_pool_size 30;
lua_max_running_timers 4096;
lua_max_pending_timers 16384;
lua_shared_dict kong                5m;
lua_shared_dict kong_db_cache       128m;
lua_shared_dict kong_db_cache_miss 12m;
lua_shared_dict kong_locks          8m;
lua_shared_dict kong_process_events 5m;
lua_shared_dict kong_cluster_events 5m;
lua_shared_dict kong_healthchecks   5m;
lua_shared_dict kong_rate_limiting_counters 12m;
lua_socket_log_errors off;
lua_ssl_verify_depth 1;

# injected nginx_http_* directives
lua_shared_dict prometheus_metrics 5m;

-- 后缀是by_lua_block的都代表nginx处理请求的一个执行阶段，每个阶段都会执行相应的kong代码。

-- 发生在master进程启动阶段。这里会对数据访问层进行初始化，加载插件的代码，构造路由规则表。
init_by_lua_block {
    Kong = require 'kong'
    Kong.init()
}

-- 发生在worker进程启动阶段。这里会开启数据同步机制，执行每个插件的init_worker方法。
init_worker_by_lua_block {
    Kong.init_worker()
}


upstream kong_upstream {
    server 0.0.0.1;
    balancer_by_lua_block {
    -- kong在这里会把上一阶段找到的服务节点设置给nginx的load balancer。如果设置了重试次数，此阶段可能会被执行
        Kong.balancer()
    }
    keepalive 60;
}

server {
    server_name kong;
    listen 0.0.0.0:8000;
    listen 0.0.0.0:8443 ssl;
    error_page 400 404 408 411 412 413 414 417 494 /kong_error_handler;
    error_page 500 502 503 504 /kong_error_handler;

    access_log logs/access.log;
    error_log logs/error.log notice;

    client_body_buffer_size 8k;

    ssl_certificate /usr/local/kong/ssl/kong-default.crt;
    ssl_certificate_key /usr/local/kong/ssl/kong-default.key;
    ssl_protocols TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_certificate_by_lua_block {
        Kong.ssl_certificate()
    }

    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256;


    real_ip_header     X-Real-IP;
    real_ip_recursive  off;

    # injected nginx_proxy_* directives

    location / {
        default_type                     '';

        set $ctx_ref                     '';
        set $upstream_host               '';
        set $upstream_upgrade            '';
        set $upstream_connection         '';
        set $upstream_scheme             '';
        set $upstream_uri                '';
        set $upstream_x_forwarded_for    '';
        set $upstream_x_forwarded_proto  '';
        set $upstream_x_forwarded_host   '';
        set $upstream_x_forwarded_port   '';

        -- 这里可以对请求做一些修改。kong在这里会把处理代理给插件的rewrite方法。
        rewrite_by_lua_block {
            Kong.rewrite()
        }

        -- kong在这里对请求进行路由匹配，找到后端的upstream服务的节点
        access_by_lua_block {
            Kong.access()
        }

        proxy_http_version 1.1;
        proxy_set_header   Host              $upstream_host;
        proxy_set_header   Upgrade           $upstream_upgrade;
        proxy_set_header   Connection        $upstream_connection;
        proxy_set_header   X-Forwarded-For   $upstream_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $upstream_x_forwarded_proto;
        proxy_set_header   X-Forwarded-Host  $upstream_x_forwarded_host;
        proxy_set_header   X-Forwarded-Port  $upstream_x_forwarded_port;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_pass_header  Server;
        proxy_pass_header  Date;
        proxy_ssl_name     $upstream_host;
        proxy_pass         $upstream_scheme://kong_upstream$upstream_uri;

        --  这里可以对响应头做一些处理。kong在这里会把处理代理给插件的header_filter方法。
        header_filter_by_lua_block {
            Kong.header_filter()
        }

        -- 这里可以对响应体做一些处理。kong在这里会把处理代理给插件的body_filter方法。
        body_filter_by_lua_block {
            Kong.body_filter()
        }
        
        -- kong在这里会通过插件异步记录日志和一些metrics数据。
        log_by_lua_block {
            Kong.log()
        }
    }

    location = /kong_error_handler {
        internal;
        uninitialized_variable_warn off;

        content_by_lua_block {
            Kong.handle_error()
        }

        header_filter_by_lua_block {
            Kong.header_filter()
        }

        body_filter_by_lua_block {
            Kong.body_filter()
        }

        log_by_lua_block {
            Kong.log()
        }
    }
}

server {
    server_name kong_admin;
    listen 127.0.0.1:8001;
    listen 127.0.0.1:8444 ssl;

    access_log logs/admin_access.log;
    error_log logs/error.log notice;

    client_max_body_size 10m;
    client_body_buffer_size 10m;

    ssl_certificate /usr/local/kong/ssl/admin-kong-default.crt;
    ssl_certificate_key /usr/local/kong/ssl/admin-kong-default.key;
    ssl_protocols TLSv1.1 TLSv1.2 TLSv1.3;

    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256;

    # injected nginx_admin_* directives

    location / {
        default_type application/json;
        content_by_lua_block {
            Kong.serve_admin_api()
        }
    }

    location /nginx_status {
        internal;
        access_log off;
        stub_status;
    }

    location /robots.txt {
        return 200 'User-agent: *\nDisallow: /';
    }
}

```
