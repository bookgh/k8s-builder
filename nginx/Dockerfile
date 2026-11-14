# syntax=docker/dockerfile:1
# -----------------------------------------------------------------------------
# nginx-builder: 多阶段编译 stream 专用 nginx 二进制。
#
# 校验方式（nginx 官方支持的完整性校验）：
#   - 下载源码包及其 PGP 签名 (.tar.gz.asc)；
#   - 导入 nginx 官方开发者公钥（Roman Arutyunyan, arutyunyan@f5.com）；
#   - gpg --verify 校验签名通过后再解压编译。
#   - 不在本文件中固定 SHA256 摘要；版本号由构建参数 NGINX_VERSION 传入。
# -----------------------------------------------------------------------------
FROM rockylinux:9 AS nginx-builder

ARG NGINX_VERSION=1.30.6
ARG NGINX_KEY_URL=https://nginx.org/keys/arut.key

# Rocky Linux 9 基础镜像预装 curl-minimal，避免与 curl 软件包冲突。
RUN dnf -y install \
      gcc \
      make \
      glibc-devel \
      gnupg2 \
    && dnf clean all \
    && rm -rf /var/cache/dnf

WORKDIR /usr/local/src
RUN set -eux; \
    curl --fail --location --retry 4 --retry-all-errors \
      "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
      --output nginx.tar.gz; \
    curl --fail --location --retry 4 --retry-all-errors \
      "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz.asc" \
      --output nginx.tar.gz.asc; \
    curl --fail --location --retry 4 --retry-all-errors \
      "${NGINX_KEY_URL}" --output nginx_signing.key; \
    gpg --batch --import nginx_signing.key; \
    gpg --batch --verify nginx.tar.gz.asc nginx.tar.gz; \
    tar -xzf nginx.tar.gz; \
    cd "nginx-${NGINX_VERSION}"; \
    ./configure \
      --prefix=/usr/local/nginx \
      --sbin-path=/usr/local/nginx/sbin/nginx \
      --conf-path=/etc/nginx/nginx.conf \
      --pid-path=/run/nginx-k8s-api.pid \
      --error-log-path=/var/log/nginx-k8s-api/error.log \
      --without-http \
      --with-stream \
      --with-threads \
      --with-cc-opt="-O2 -fstack-protector-strong" \
      --with-ld-opt="-Wl,-z,relro -Wl,-z,now"; \
    make -j"$(nproc)"; \
    make install; \
    mkdir -p /out; \
    cp /usr/local/nginx/sbin/nginx /out/nginx; \
    chmod 0755 /out/nginx; \
    /out/nginx -V

FROM scratch AS artifact
COPY --from=nginx-builder /out/nginx /nginx
CMD ["/nginx", "-V"]
