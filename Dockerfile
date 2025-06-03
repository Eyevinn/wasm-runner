FROM ubuntu:22.04

WORKDIR /runner
RUN apt-get -y update && apt-get --yes install \
  curl \
  xz-utils \
  git
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
  apt-get install -y nodejs
RUN curl -sSf https://raw.githubusercontent.com/WasmEdge/WasmEdge/master/utils/install.sh | bash -s -- -p /runner
COPY ./scripts ./
VOLUME /usercontent
RUN groupadd -r runner && useradd -r -g runner runner -d /runner
RUN chown -R runner:runner /runner
ENV PORT=8080
ENTRYPOINT [ "/runner/docker-entrypoint.sh" ]

CMD ["/runner/bin/wasmedge", "main.wasm"]