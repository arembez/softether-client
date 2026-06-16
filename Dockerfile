FROM --platform=$TARGETPLATFORM softethervpn/vpnclient:latest
RUN apk add --no-cache curl
COPY entrypoint.sh /entrypoint.sh
<<<<<<< Updated upstream
ENV SE_VERSION=0.9.2
=======
ENV SE_VERSION=0.9.4
>>>>>>> Stashed changes
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]