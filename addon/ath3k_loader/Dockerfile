FROM ghcr.io/home-assistant/base:latest

RUN apk add --no-cache kmod

COPY run.sh /
RUN chmod 0755 /run.sh

CMD ["/run.sh"]
