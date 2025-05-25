ARG BUILD_FROM
FROM ${BUILD_FROM}

RUN apk add --no-cache python3 py3-pip curl
RUN pip install requests

COPY main.py /main.py

CMD ["python3", "/main.py"]
