set -ex
ls -la

cd proxy-cache-advanced-1.0.0
luarocks make
cd -

cd grpc-web-advanced-1.0.0
luarocks make
cd -

cd grpc-gateway-advanced-1.0.0
luarocks make
cd -