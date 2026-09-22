# Built locally instead of pulled (no published image exists) and instead of
# a plain git build context against apache/age-viewer's own Dockerfile: that
# Dockerfile pins node:14-alpine3.16, matching package.json's declared
# "node": "^14.16.0" engine, but the repo ships no lockfile, so `npm install`
# resolves several transitive dependencies (e.g. colorspace, via winston) to
# versions published after that Node 14 pin that use syntax (`||=`) Node 14
# can't parse. A newer Node runs the exact same source fine.
FROM node:20-alpine

RUN apk add --no-cache git

RUN npm install -g pm2

WORKDIR /src

ARG AGE_VIEWER_REF=main
RUN git clone --branch "${AGE_VIEWER_REF}" --depth 1 https://github.com/apache/age-viewer.git .

RUN npm run setup

# backend/package.json uses @babel/plugin-transform-runtime but never lists
# its @babel/runtime peer as an actual dependency. npm 6 (the node:14 image
# upstream's own Dockerfile uses) happened to hoist it in anyway; npm 10
# (bundled with node:20) doesn't, so it's missing at runtime without this.
# Pinned to the 7.x line: the rest of the toolchain is Babel 7 (see the
# ^7.12.15 devDependency on @babel/plugin-transform-runtime below), and
# unpinned installs Babel 8, which dropped the deep `@babel/runtime/regenerator`
# import the compiled backend code still uses.
RUN cd backend && npm install --no-save '@babel/runtime@^7'

# frontend's webpack 4 (via react-scripts) calls Node's crypto.createHash("md4"),
# which OpenSSL 3 (Node 17+) no longer supports by default.
ENV NODE_OPTIONS=--openssl-legacy-provider

CMD ["npm", "run", "start"]

EXPOSE 3000
