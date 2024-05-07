#
# NOTE: THIS DOCKERFILE IS GENERATED FROM "Dockerfile.template" VIA
# `./generate_dockerfiles.sh`
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#

# Use it as a common base.
FROM python:3.11-slim-bookworm as builder

WORKDIR /build

# Common dependencies
RUN apt-get update && \
    apt-get install -y git ninja-build cmake curl zlib1g-dev zstd libzstd-dev

# The following are needed because we are going to change some autoconf scripts,
# both for libnghttp2 and curl.
RUN apt-get install -y autoconf automake autotools-dev pkg-config libtool git

# Dependencies for downloading and building nghttp2
RUN apt-get install -y bzip2

# Dependencies for downloading and building curl
RUN apt-get install -y xz-utils

# Dependencies for downloading and building BoringSSL
RUN apt-get install -y g++ golang-go unzip

# Download and compile libbrotli
ARG BROTLI_VERSION=1.0.9
RUN curl -L https://github.com/google/brotli/archive/refs/tags/v${BROTLI_VERSION}.tar.gz -o brotli-${BROTLI_VERSION}.tar.gz && \
    tar xf brotli-${BROTLI_VERSION}.tar.gz
RUN cd brotli-${BROTLI_VERSION} && \
    mkdir build && cd build && \
    cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=./installed .. && \
    cmake --build . --config Release --target install

# BoringSSL doesn't have versions. Choose a commit that is used in a stable
# Chromium version.
ARG BORING_SSL_COMMIT=d24a38200fef19150eef00cad35b138936c08767
RUN curl -L https://github.com/google/boringssl/archive/${BORING_SSL_COMMIT}.zip -o boringssl.zip && \
    unzip boringssl && \
    mv boringssl-${BORING_SSL_COMMIT} boringssl

# Compile BoringSSL.
# See https://boringssl.googlesource.com/boringssl/+/HEAD/BUILDING.md
COPY patches/boringssl.patch boringssl/
RUN cd boringssl && \
    for p in $(ls boringssl.patch); do patch -p1 < $p; done && \
    mkdir build && cd build && \
    cmake \
        -DCMAKE_C_FLAGS="-Wno-error=array-bounds -Wno-error=stringop-overflow" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=on -GNinja .. && \
    ninja

# Fix the directory structure so that curl can compile against it.
# See https://everything.curl.dev/source/build/tls/boringssl
RUN mkdir boringssl/build/lib && \
    ln -s ../crypto/libcrypto.a boringssl/build/lib/libcrypto.a && \
    ln -s ../ssl/libssl.a boringssl/build/lib/libssl.a && \
    cp -R boringssl/include boringssl/build

ARG NGHTTP2_VERSION=nghttp2-1.56.0
ARG NGHTTP2_URL=https://github.com/nghttp2/nghttp2/releases/download/v1.56.0/nghttp2-1.56.0.tar.bz2

# Download nghttp2 for HTTP/2.0 support.
RUN curl -o ${NGHTTP2_VERSION}.tar.bz2 -L ${NGHTTP2_URL}
RUN tar xf ${NGHTTP2_VERSION}.tar.bz2

# Compile nghttp2
RUN cd ${NGHTTP2_VERSION} && \
    ./configure --prefix=/build/${NGHTTP2_VERSION}/installed --with-pic --disable-shared && \
    make && make install

# Download curl.
ARG CURL_VERSION=curl-8.5.0
RUN curl -o ${CURL_VERSION}.tar.xz https://curl.se/download/${CURL_VERSION}.tar.xz
RUN tar xf ${CURL_VERSION}.tar.xz

# Patch curl and re-generate the configure script
COPY patches/curl-*.patch ${CURL_VERSION}/
RUN cd ${CURL_VERSION} && \
    for p in $(ls curl-*.patch); do patch -p1 < $p; done && \
    autoreconf -fi

# Compile curl with nghttp2, libbrotli and boringssl.
# Enable keylogfile for debugging of TLS traffic.
RUN cd ${CURL_VERSION} && \
    ./configure --prefix=/build/install \
                --enable-static \
                --disable-shared \
                --enable-websockets \
                --with-nghttp2=/build/${NGHTTP2_VERSION}/installed \
                --with-brotli=/build/brotli-${BROTLI_VERSION}/build/installed \
                --with-zstd \
                --enable-ech \
                --with-openssl=/build/boringssl/build \
                LIBS="-pthread" \
                CFLAGS="-I/build/boringssl/build" \
                USE_CURL_SSLKEYLOGFILE=true && \
    make && make install

RUN mkdir out && \
    cp /build/install/bin/curl-impersonate-chrome out/ && \
    ln -s curl-impersonate-chrome out/curl-impersonate && \
    cp /build/install/bin/curl-impersonate-chrome-config out/ && \
    ln -s curl-impersonate-chrome-config out/curl-impersonate-config && \
    strip out/curl-impersonate

# Verify that the resulting 'curl' has all the necessary features.
RUN ./out/curl-impersonate -V | grep -q zlib && \
    ./out/curl-impersonate -V | grep -q brotli && \
    ./out/curl-impersonate -V | grep -q nghttp2 && \
    ./out/curl-impersonate -V | grep -q -e BoringSSL

RUN ./out/curl-impersonate-config --version | grep -q libcurl && \
    ./out/curl-impersonate-config --libs | grep -q -e brotli -e bghttp2 && \
    ./out/curl-impersonate-config --static-libs | grep -q -e brotli -e bghttp2 && \
    ./out/curl-impersonate-config --prefix | grep -q \/build\/install && \
    ./out/curl-impersonate-config --cflags | grep -q CURL_STATICLIB

# Verify that the resulting 'curl' is really statically compiled
RUN ! (ldd ./out/curl-impersonate | grep -q -e libcurl -e nghttp2 -e brotli -e ssl -e crypto)

RUN rm -Rf /build/install
RUN rm -Rf /build/install/bin

# Re-compile libcurl dynamically
RUN cd ${CURL_VERSION} && \
    ./configure --prefix=/build/install \
                --with-nghttp2=/build/${NGHTTP2_VERSION}/installed \
                --with-brotli=/build/brotli-${BROTLI_VERSION}/build/installed \
                --with-zstd \
                --enable-ech \
                --with-openssl=/build/boringssl/build \
                LIBS="-pthread" \
                CFLAGS="-I/build/boringssl/build" \
                USE_CURL_SSLKEYLOGFILE=true && \
    make clean && make && make install

# Copy libcurl-impersonate and symbolic links
RUN cp -d /build/install/lib/libcurl-impersonate* /build/out

RUN ver=$(readlink -f ${CURL_VERSION}/lib/.libs/libcurl-impersonate-chrome.so | sed 's/.*so\.//') && \
    major=$(echo -n $ver | cut -d'.' -f1) && \
    ln -s "libcurl-impersonate-chrome.so.$ver" "out/libcurl-impersonate.so.$ver" && \
    ln -s "libcurl-impersonate.so.$ver" "out/libcurl-impersonate.so" && \
    strip "out/libcurl-impersonate.so.$ver"

# Verify that the resulting 'libcurl' is really statically compiled against its
# dependencies.
RUN ! (ldd ./out/curl-impersonate | grep -q -e nghttp2 -e brotli -e ssl -e crypto)

# Wrapper scripts
COPY curl_chrome* curl_edge* curl_safari* out/
RUN chmod +x out/curl_*

# Create a final, minimal image with the compiled binaries only.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# Copy curl-impersonate from the builder image
COPY --from=builder /build/install /usr/local
# Update the loader's cache
RUN ldconfig
# Copy to /build/out as well for backward compatibility with previous versions.
COPY --from=builder /build/out /build/out
# Wrapper scripts
COPY --from=builder /build/out/curl_* /usr/local/bin/

