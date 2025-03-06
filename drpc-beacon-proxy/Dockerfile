FROM python:3.11-slim

WORKDIR /app

RUN pip install flask requests

COPY proxy.py /app/

CMD ["python", "proxy.py"]
