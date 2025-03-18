FROM python:3.11

WORKDIR /app

COPY rpc_sync_checker.py /app/
RUN pip install groq

CMD ["python", "/app/rpc_sync_checker.py"]