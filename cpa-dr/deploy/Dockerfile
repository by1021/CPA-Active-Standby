FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates coreutils findutils grep sed gawk jq tar rsync openssh-client openssh-server util-linux sqlite3 curl nginx fcgiwrap spawn-fcgi \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/ssh/ssh_host_* \
 && passwd -d root \
 && mkdir -p /run/sshd
WORKDIR /opt/cpa-dr
COPY bin ./bin
COPY lib ./lib
COPY cgi ./cgi
COPY www ./www
COPY scripts ./scripts
COPY start.sh ./start.sh
COPY deploy ./deploy
COPY deploy/Dockerfile ./Dockerfile
COPY deploy/compose.yaml ./compose.yaml
COPY deploy/.env.example ./.env.example
COPY .dockerignore ./.dockerignore
RUN chmod +x bin/* cgi/* start.sh \
 && find scripts -type f -name "*.sh" -exec chmod +x {} +
ENV CPA_ROOT=/opt/cpa-dr CPA_STATE_DIR=/state CPA_ALLOWED_ROOT=/data
EXPOSE 8787 22
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 CMD curl --fail --silent http://127.0.0.1:8787/healthz >/dev/null || exit 1
ENTRYPOINT ["/opt/cpa-dr/scripts/entrypoint.sh"]
