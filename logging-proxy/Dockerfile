FROM python:3.12-slim

WORKDIR /app

RUN pip install flask requests

COPY proxy.py .

EXPOSE 8545

CMD ["python", "proxy.py"]
