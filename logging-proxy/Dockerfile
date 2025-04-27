FROM python:3.12-slim

WORKDIR /app

RUN pip install flask requests Flask-Sockets gevent gevent-websocket websocket-client

COPY proxy.py .

EXPOSE 8545

CMD ["python", "proxy.py"]
