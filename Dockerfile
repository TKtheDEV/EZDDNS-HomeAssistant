FROM ghcr.io/home-assistant/base:latest

# Copy data for add-on
RUN apk add --no-cache bash jq curl
COPY run.sh /
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
