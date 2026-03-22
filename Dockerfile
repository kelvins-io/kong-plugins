FROM golang:1.24.4 as go-build-stage
COPY . /app
RUN go env -w GO111MODULE=on
RUN go env -w GOPROXY=https://goproxy.cn,direct
RUN cd /app/go-hello && go build -o go-hello
RUN cd /app/go-log && go build -o go-log

FROM kong:3.4.2 as prod
USER root
COPY . /tmp/repo
RUN cd /tmp/repo && sh install.sh

COPY proxy-cache-advanced-1.0.0/kong/plugins/proxy-cache-advanced /usr/local/share/lua/5.1/kong/plugins/proxy-cache-advanced
COPY grpc-web-advanced-1.0.0/kong/plugins/grpc-web-advanced /usr/local/share/lua/5.1/kong/plugins/grpc-web-advanced
COPY grpc-gateway-advanced-1.0.0/kong/plugins/grpc-gateway-advanced /usr/local/share/lua/5.1/kong/plugins/grpc-gateway-advanced
COPY response-gzip-1.0.0/kong/plugins/response-gzip /usr/local/share/lua/5.1/kong/plugins/response-gzip

COPY --from=go-build-stage /app/go-hello/go-hello /usr/local/bin/go-hello
COPY --from=go-build-stage /app/go-log/go-log /usr/local/bin/go-log
RUN cd /usr/local/bin && ls -l
RUN cd / && rm -rf /tmp/repo

ENV KONG_PLUGINSERVER_NAMES="go-hello,go-log"
ENV KONG_PLUGINSERVER_GO_HELLO_START_CMD="/usr/local/bin/go-hello"
ENV KONG_PLUGINSERVER_GO_LOG_START_CMD="/usr/local/bin/go-log"
ENV KONG_PLUGINSERVER_GO_HELLO_QUERY_CMD="/usr/local/bin/go-hello -dump"
ENV KONG_PLUGINSERVER_GO_LOG_QUERY_CMD="/usr/local/bin/go-log -dump"


ENV KONG_NGINX_HTTP_LUA_SHARED_DICT="tracing_buffer 512m"
ENV KONG_MEM_CACHE_SIZE="512m"
ENV KONG_PLUGINS="bundled,go-hello,go-log,proxy-cache-advanced,grpc-web-advanced,grpc-gateway-advanced,response-gzip"
ENV KONG_LUA_PACKAGE_PATH="/home/kong/.luarocks/share/lua/5.1/?.lua;./?.lua;./?/init.lua;"
USER kong
CMD ["kong","docker-start"]
