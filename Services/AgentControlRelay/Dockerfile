FROM swift:6.2-noble AS build
WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources Sources
RUN swift build -c release --static-swift-stdlib --product agentcontrol-relay

FROM ubuntu:noble
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libatomic1 libcurl4 libxml2 && rm -rf /var/lib/apt/lists/*
RUN useradd --system --uid 10001 --create-home relay
COPY --from=build /build/.build/release/agentcontrol-relay /usr/local/bin/agentcontrol-relay
USER relay
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/agentcontrol-relay"]
