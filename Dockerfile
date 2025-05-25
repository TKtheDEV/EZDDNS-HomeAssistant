ARG BUILD_FROM
FROM ${BUILD_FROM}

# Install Python and pip
RUN apk add --no-cache python3 python3-requests curl

# Copy main script
COPY main.py /main.py

# Set as foreground process
CMD [ "python3", "/main.py" ]
