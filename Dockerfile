# syntax=docker/dockerfile:1
FROM --platform=$TARGETPLATFORM softethervpn/vpnclient:latest

ENV SE_VERSION=0.9.6

RUN apk add --no-cache curl

COPY --chmod=755 entrypoint.sh /entrypoint.sh
COPY --chmod=755 healthcheck.sh /healthcheck.sh
COPY --chmod=755 addroute.sh /addroute.sh

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]