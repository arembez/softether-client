FROM --platform=$TARGETPLATFORM softethervpn/vpnclient:latest
COPY entrypoint.sh /entrypoint.sh
ENV SE_VERSION=0.9.3
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]