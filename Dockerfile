ARG BUILD_FROM
FROM $BUILD_FROM

# Set environment variables
ENV CONFIG_FILE=config.sh
ENV CLOUDFLARE_API_FILE=cloudflare_api.sh
ENV UPDATE_DNS_FILE=update_dns.sh
ENV MAIN_FILE=main.sh

# Copy data for add-on
COPY ${CONFIG_FILE} /scripts/${CONFIG_FILE}
COPY ${CLOUDFLARE_API_FILE} /scripts/${CLOUDFLARE_API_FILE}
COPY ${UPDATE_DNS_FILE} /scripts/${UPDATE_DNS_FILE}
COPY ${MAIN_FILE} /scripts/${MAIN_FILE}

# Ensure scripts are executable
RUN chmod a+x /scripts/${CONFIG_FILE} /scripts/${CLOUDFLARE_API_FILE} /scripts/${UPDATE_DNS_FILE} /scripts/${MAIN_FILE}

# Run the main script
CMD [ "/scripts/main.sh" ]
