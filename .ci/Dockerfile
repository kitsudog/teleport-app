FROM --platform=linux/amd64 nginx:1.22-alpine AS builder
ARG VERSION=v18.7.1
RUN curl https://cdn.teleport.dev/teleport-${VERSION}-linux-amd64-bin.tar.gz -o -|gunzip|tar -C /usr/local/bin --strip-components=1 -xvf -
FROM --platform=linux/amd64 ubuntu:24.04
COPY --from=builder /usr/local/bin /usr/local/bin
RUN apt update && apt -y install curl jq yq socat nginx && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /
COPY app_config.yaml /data/
VOLUME /data/teleport
VOLUME /root/.tsh
ENTRYPOINT /entrypoint.sh
CMD configure
