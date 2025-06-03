FROM ubuntu:22.04

ENV WASMTIME_HOME=/runner
WORKDIR /runner
RUN apt-get -y update && apt-get --yes install \
  curl \
  xz-utils
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
  apt-get install -y nodejs
RUN curl https://wasmtime.dev/install.sh -sSf | bash
COPY ./scripts ./
VOLUME /usercontent
RUN groupadd -r runner && useradd -r -g runner runner -d /runner
RUN chown -R runner:runner /runner
ENV PORT=8080
ENTRYPOINT [ "/runner/docker-entrypoint.sh" ]

CMD ["/runner/bin/wasmtime", "main.wasm"]