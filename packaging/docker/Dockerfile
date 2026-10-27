# Roomy CLI container. Mount the home you want cleaned and a policy; metrics on :9477.
#
#   docker build -t roomy -f packaging/docker/Dockerfile .
#   docker run --rm -v /home/agent:/home/agent -v /etc/roomy:/etc/roomy:ro roomy scan --home /home/agent
#   docker run -d -p 9477:9477 -v /home/agent:/home/agent -v /etc/roomy:/etc/roomy:ro roomy fleet serve --listen 0.0.0.0:9477
#
# Note: Docker-in-container probes need /var/run/docker.sock mounted; otherwise the Docker category is skipped.
FROM swift:6.1-noble AS build
WORKDIR /src
COPY RoomyCore/Package.swift RoomyCore/Package.resolved ./RoomyCore/
RUN cd RoomyCore && swift package resolve
COPY RoomyCore ./RoomyCore
RUN cd RoomyCore && swift build -c release --product roomy --static-swift-stdlib -Xswiftc -Osize \
 && strip .build/release/roomy

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates coreutils git tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /etc/roomy /var/log/roomy
COPY --from=build /src/RoomyCore/.build/release/roomy /usr/bin/roomy
COPY packaging/config/policy.agent-host.json /etc/roomy/policy.json
ENV ROOMY_POLICY=/etc/roomy/policy.json
EXPOSE 9477 9478
ENTRYPOINT ["/usr/bin/roomy"]
CMD ["--help"]
