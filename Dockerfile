FROM --platform=$TARGETPLATFORM softethervpn/vpnclient:latest
RUN apk add --no-cache curl
COPY entrypoint.sh /entrypoint.sh
ENV SE_VERSION=0.9.4
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]