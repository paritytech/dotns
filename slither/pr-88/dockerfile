FROM --platform=linux/amd64 debian:trixie-slim

ARG TAG=polkadot-stable2512-1
ARG BIN=eth-rpc

RUN apt-get update && apt-get install -y ca-certificates curl libssl3 && rm -rf /var/lib/apt/lists/*

RUN curl -L -o /usr/local/bin/${BIN} \
  https://github.com/paritytech/polkadot-sdk/releases/download/${TAG}/${BIN} \
  && chmod +x /usr/local/bin/${BIN}

ENTRYPOINT ["eth-rpc"]
