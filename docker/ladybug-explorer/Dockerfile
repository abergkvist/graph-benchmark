# Ladybug Explorer built against the same Ladybug version as the lbug shell.
#
# The published ghcr.io/ladybugdb/explorer image lags behind lbug: its 0.19.1
# reads storage version 43, while lbug 0.20.4 writes version 47 and the image
# refuses to open the database. This builds upstream at a pinned commit with
# @ladybugdb/core bumped to LBUG_VERSION. Keep LBUG_VERSION equal to `lbug --version`.
#
# Mirrors upstream's Dockerfile, minus grammar generation (the parser is checked
# in) and the example datasets.

FROM node:20-trixie-slim

ARG EXPLORER_REF=cc507f0cbbeec7691044c0d65a2bf5a87b3a26c7
ARG LBUG_VERSION=0.20.4

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y libatomic1 openssl ca-certificates libpq5 git \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/LadybugDB/explorer.git /home/node/app \
    && git -C /home/node/app checkout "$EXPLORER_REF"

RUN mkdir -p /database /data \
    && chown -R node:node /home/node/app /database /data

USER node
WORKDIR /home/node/app

RUN npm pkg set "dependencies.@ladybugdb/core=$LBUG_VERSION" \
        "dependencies.@ladybugdb/wasm-core=$LBUG_VERSION" \
    && npm install \
    && rm -rf node_modules/@ladybugdb/core/prebuilt node_modules/@ladybugdb/core/lbug-source

# parallel: false, because one webpack worker per CPU core ran the build out of
# memory in Docker Desktop's VM.
RUN sed -i 's/transpileDependencies: true,/transpileDependencies: true,\n  parallel: false,/' vue.config.js \
    && grep -q 'parallel: false' vue.config.js \
    && NODE_OPTIONS="--max-old-space-size=4096" npm run build

EXPOSE 8000

ENV NODE_ENV=production
ENV PORT=8000
ENV LBUG_DIR=/database
ENV LBUG_WASM=false

ENTRYPOINT ["node", "src/server/index.js"]
