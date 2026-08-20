# Build image for the portable-core checks. The stock swift image carries
# libsqlite3.so.0 but no sqlite3.h, so RuleStore cannot be type-checked against
# it. apt cannot run at check time because the containers are started with
# --user and therefore have no root, so the dependency is baked in here.
FROM swift:6.0-noble
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*
