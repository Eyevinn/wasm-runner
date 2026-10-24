FROM ubuntu:22.04

WORKDIR /runner
RUN apt-get -y update && apt-get --yes install \
  curl \
  xz-utils \
  git
# Pinned to the Node 24.x line for CVE-2026-111497 (Brotli decoder RCE).
# The build fails if the installed Node is below 24.22.1, the fixed release.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
  apt-get install -y nodejs && \
  node -e 'const [M,m,p]=process.versions.node.split(".").map(Number); if (M!==24||m<22||(m===22&&p<1)) { console.error("Node "+process.versions.node+" is below 24.22.1 (CVE-2026-111497)"); process.exit(1) }' && \
  node --version
RUN curl -sSf https://raw.githubusercontent.com/WasmEdge/WasmEdge/master/utils/install.sh | bash -s -- -p /runner
COPY ./scripts ./
COPY ./api ./api
RUN cd /runner/api && \
  npm install --unsafe-perm
VOLUME /usercontent
RUN groupadd -r runner && useradd -r -g runner runner -d /runner
RUN chown -R runner:runner /runner
ENV PORT=8080
ENTRYPOINT [ "/runner/docker-entrypoint.sh" ]

CMD ["node", "/runner/api/server.js"]