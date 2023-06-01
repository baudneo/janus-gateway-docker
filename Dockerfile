ARG JANUS_REPO_OWNER=meetecho
ARG JANUS_VERSION=master
ARG S6_ARCH=x86_64
ARG GH_REPO=meetecho/janus-gateway

# S6 Overlay
FROM alpine:latest as s6dl
ARG S6_ARCH
WORKDIR /s6dl

RUN set -x \
    && S6_OVERLAY_VERSION=$(wget --no-check-certificate -qO - https://api.github.com/repos/just-containers/s6-overlay/releases/latest | awk '/tag_name/{print $4;exit}' FS='[""]') \
    && S6_OVERLAY_VERSION=${S6_OVERLAY_VERSION:1} \
    && wget -O /tmp/s6-overlay-arch.tar.xz "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" \
    && wget -O /tmp/s6-overlay-noarch.tar.xz "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" \
    && mkdir -p /tmp/s6 \
    && tar -Jxvf /tmp/s6-overlay-noarch.tar.xz -C /tmp/s6 \
    && tar -Jxvf /tmp/s6-overlay-arch.tar.xz -C /tmp/s6 \
    && cp -r /tmp/s6/* .

# CRLF to LF
FROM alpine:latest as rootfs-converter
WORKDIR /rootfs

RUN set -x \
    && apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community/ \
        dos2unix

COPY rootfs .
RUN set -x \
    && find . -type f -print0 | xargs -0 -n 1 -P 4 dos2unix \
    && chmod -R +x *


#######################################
# Build Janus
#######################################
FROM debian:bullseye-slim as builder

ARG JANUS_REPO_OWNER
ARG JANUS_VERSION

ENV DEBIAN_FRONTEND=noninteractive

RUN set -x \
    && apt-get -y update \
	&& apt-get install -y --no-install-recommends \
	    ca-certificates \
        gnupg \
        autoconf \
        cmake \
        libavutil-dev \
        duktape-dev \
        gtk-doc-tools \
        libavcodec-dev \
        libavformat-dev \
        libcollection-dev \
        libconfig-dev \
        libevent-dev \
        libpcap-dev \
        libglib2.0-dev \
        libgirepository1.0-dev \
        liblua5.3-dev \
        libjansson-dev \
        libmicrohttpd-dev \
        libmount-dev \
        libnanomsg-dev \
        libogg-dev \
        libopus-dev \
        librabbitmq-dev \
        libsofia-sip-ua-dev \
        libssl-dev \
        libtool \
        libvorbis-dev \
        ninja-build \
        openssl \
		libcurl4-openssl-dev \
		libconfig-dev \
		pkg-config \
		gengetopt \
		automake \
		build-essential \
		wget \
		git \
		python3 \
		python3-dev \
		python3-pip \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

# if amd64 add $amd64_libdir=' --libdir=/usr/lib64'
RUN set -x \
    && pip3 install --upgrade pip \
    && pip3 install setuptools meson wheel \
    && if [ $(uname -m) = x86_64 ]; then export amd64_libdir=' --libdir=/usr/lib64'; echo "exported amd64_libdir as '$amd64_libdir'"; fi \
    && rm -rf /root/.cache \
    && mkdir -p /tmp/deps


# libcurl fixed RTSP auth in 8.2.0-DEV, build and install
RUN set -x \
    && git clone  https://github.com/curl/curl.git curl-src \
    && cd curl-src \
    && autoreconf -fi \
    && ./configure --with-openssl --prefix=/tmp/curl \
    && make

# install and link
RUN set -x \
    && cd curl-src \
    && dpkg --remove --force-depends libcurl4 \
    && make install \
    && echo "/tmp/curl/lib" > /etc/ld.so.conf.d/libcurl \
    && ldconfig

RUN ls -alh /tmp/curl/lib/pkgconfig \
    && cat /etc/ld.so.conf.d/libcurl \
    && ldconfig \
    && ldconfig -p | grep curl \
    && cp -r /tmp/curl/lib/* /usr/lib/x86_64-linux-gnu/

# libwebsockets (uses libcurl.so.4, test if linking works)
RUN set -x \
    && cd /tmp \
    && git clone https://github.com/warmcat/libwebsockets lws \
    && cd lws \
    && mkdir -p build \
    && cd build \
    # Force linker to use new curl
    && cmake -Wl,-rpath -Wl,/tmp/curl/lib -DCMAKE_INSTALL_PREFIX:PATH=/tmp/deps -DLWS_WITH_STATIC=OFF -DLWS_WITHOUT_CLIENT=ON -DLWS_WITHOUT_TESTAPPS=ON -DLWS_WITHOUT_TEST_SERVER=ON -DLWS_WITH_HTTP2=OFF .. \
    && make -j$(nproc) \
    && make install

# libnice NEW
RUN set -x \
    && git clone --depth 1 --quiet -b master https://gitlab.freedesktop.org/libnice/libnice.git libnice \
    && cd libnice \
    && meson setup -Dprefix=/tmp/deps -Dlibdir=lib -Dc_args="$LNICE_CFLAGS" -Ddebug=false -Doptimization=0 -Dexamples=disabled -Dgtk_doc=disabled -Dgupnp=disabled -Dgstreamer=disabled -Dtests=disabled build \
    && ninja -C build \
    && ninja -C build install

# build libsrtp,
RUN set -x \
    && cd /tmp \
	&& git clone https://github.com/cisco/libsrtp libsrtp \
	&& cd libsrtp \
    && ./configure --prefix=/tmp/deps --enable-openssl \
	&& make shared_library -j$(nproc) \
	&& make install

# add sctplab for Data Channels
RUN set -x \
    && cd /tmp \
    && git clone https://github.com/sctplab/usrsctp \
    && cd usrsctp \
    && ./bootstrap \
    && ./configure --prefix=/tmp/deps --disable-programs --disable-debug --disable-inet --disable-inet6 \
    && make -j$(nproc) \
    && make install

# PAHO MQTT
RUN set -x \
    && cd /tmp \
    && git clone https://github.com/eclipse/paho.mqtt.c paho \
    && cd paho \
    && cmake -DCMAKE_INSTALL_PREFIX:PATH=/tmp/deps -DPAHO_WITH_SSL=TRUE -DPAHO_BUILD_SAMPLES=FALSE -DPAHO_BUILD_DOCUMENTATION=FALSE . \
    && make -j$(nproc) \
    && make install \
    # Copy the deps to /usr so they can be used for building janus
    && cp -r /tmp/deps/* /usr

# Build janus
RUN cd /tmp \
    && mkdir janus \
    && git clone https://github.com/${JANUS_REPO_OWNER}/janus-gateway.git janus \
    && cd janus \
    && git checkout $JANUS_VERSION \
	&& sh autogen.sh \
	&& ./configure --enable-docs --enable-post-processing --enable-plugin-lua \
        --enable-plugin-duktape --enable-plugin-mqtt --enable-json-logger \
        --prefix=/opt/janus \
	&& make -j$(nproc) \
	&& make install \
	&& make configs \
    && cd / \
    && rm -rf /tmp/janus

###########################################

###########################################
FROM debian:bullseye-slim as final-image

ARG GH_REPO

RUN apt-get -y update && \
	apt-get install -y \
	    nano wget curl ca-certificates gettext-base tree \
	    libduktape205 \
		libmicrohttpd12 \
		libavutil-dev \
		libavformat-dev \
		libavcodec-dev \
		libjansson4 \
		libssl1.1 \
		libsofia-sip-ua0 \
		libglib2.0-0 \
		libopus0 \
		libogg0 \
		libcurl4 \
		liblua5.3-0 \
		lua-json \
		libconfig9 \
		libnanomsg5 \
		librabbitmq4 \
		libpcap0.8 \
		openssl \
	&& mkdir -p /opt/janus \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*
	# FIXME: may need to bring the other libs over as well, use DESTDIR or CMAKE_PREFIX_PATH

# All the installed janus dependencies from build image
COPY --from=builder /tmp/deps /usr
# Copy the janus install from build image
COPY --from=builder /opt/janus /opt/janus

RUN set -x \
    && useradd -MUou 911 -s /bin/bash janus \
    && groupmod -o -g 911 janus

RUN set -x \
    && mkdir -p \
        /janus/js \
        /janus/config \
        /log \
    && chown -R janus:janus \
        /janus \
        /opt/janus \
    && chmod -R 755 \
        /log \
        /janus \
    && chown -R nobody:nogroup \
        /log

RUN set -x \
    && apt-get -y update \
    && apt-get install -y --no-install-recommends \
        procps \
        apache2 \
        lua-ansicolors \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN set -x \
    && dpkg --remove --force-depends libcurl4 \
    && dpkg --remove --force-depends curl
 \
    # Copy libcurl from build image
COPY --from=builder /tmp/curl /usr
# Link new libcurl.so.4
# Output Should be 8.2.0-DEV +
RUN set -x \
    && ldconfig \
    && curl --version

# Install s6 overlay
COPY --from=s6dl /s6dl /
# Install rootfs
COPY --from=rootfs-converter /rootfs /

RUN set -x \
    # janus logs -> std.out
    && ln -sf /proc/self/fd/1 /opt/janus/access.log \
    && ln -sf /proc/self/fd/1 /opt/janus/error.log \
    # apache logs -> std.out
    && ln -sf /proc/self/fd/1 /var/log/apache2/access.log \
    && ln -sf /proc/self/fd/1 /var/log/apache2/error.log \
    # disable default site
    && a2dissite 000-default \
    # enable janus site
    && a2ensite janus

ENV \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_FIX_ATTRS_HIDDEN=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    MAX_LOG_SIZE_BYTES=1000000 \
    MAX_LOG_NUMBER=10 \
    # USER VARS
    TZ="America/Chicago" \
    JANUS_REST_HTTP=8088 \
    JANUS_REST_HTTPS=8089 \
    JANUS_ADMIN_HTTP=7088 \
    JANUS_ADMIN_HTTPS=7889

LABEL org.opencontainers.image.source = "https://github.com/${GH_REPO}" \
        org.opencontainers.image.vendor = "Meetecho" \
        org.opencontainers.image.description = "Janus WebRTC Gateway" \
        org.opencontainers.image.url = "https://janus.conf.meetecho.com/" \
        org.opencontainers.image.documentation = "https://janus.conf.meetecho.com/docs/"

# Cloudflare Argo tunnel ports, configure janus to use these ports if behind argo tunnel
# For ZM only the REST API needs to be exposed
# HTTP
EXPOSE 8080
EXPOSE 8880
EXPOSE 2052
EXPOSE 2082
EXPOSE 2086
EXPOSE 2095
# HTTPS
EXPOSE 443
EXPOSE 2053
EXPOSE 2083
EXPOSE 2087
EXPOSE 2096
EXPOSE 8443

# apache2 and CF Argo tunnel
EXPOSE 5020

# RTP/RTCP (not all of them)
EXPOSE 10000-10500/udp
# SIP / RTP / NoSIP
EXPOSE 20000-40000
# Janus API /janus by default
## HTTP
EXPOSE 8088
## HTTPS
EXPOSE 8080
## WebSockets
EXPOSE 8188
## WebSockets Secure
EXPOSE 8989
# Admin API /admin by default.
## HTTP
EXPOSE 7088
## HTTPS
EXPOSE 7889
## WebSockets
EXPOSE 7888
## WebSockets Secure
EXPOSE 7989
# Misc.
EXPOSE 8090-8097
# Streaming DEMO - External Video/Audio
## a:5002 v:5004
EXPOSE 5002
EXPOSE 5004
# Multi Stream DEMO
## a:5102 v:5104 v2:5106
EXPOSE 5102
EXPOSE 5104
EXPOSE 5106

CMD ["/init"]