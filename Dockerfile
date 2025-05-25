ARG BUILD_FROM
FROM ${BUILD_FROM}

# Install Python and pip
RUN apk add --no-cache python3 py3-pip curl

# Install required Python packages
RUN pip3 install --no-cache-dir requests

# Copy main script
COPY main.py /main.py

# Set as foreground process
CMD [ "python3", "/main.py" ]
