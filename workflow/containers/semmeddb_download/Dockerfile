FROM debian:bookworm-20260918-slim
LABEL version="0.1.0"
LABEL description="curl+tar environment for downloading the SemMedDB-KGX uncapped archive"

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl --version >/dev/null && tar --version >/dev/null && bash --version >/dev/null
