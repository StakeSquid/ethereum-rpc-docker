from python:bullseye


RUN pip install --upgrade pip
RUN pip install flask
RUN pip install flask_sqlalchemy

COPY src src


CMD ["python", "-u", "src/app.py"]