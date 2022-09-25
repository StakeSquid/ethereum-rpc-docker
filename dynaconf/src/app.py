import copy
from dataclasses import dataclass
from flask import Flask, request, render_template, jsonify
from flask_sqlalchemy import SQLAlchemy
import json


app = Flask(__name__)
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///database/config.db'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = 'False'
app.config['SECRET_KEY'] = "random"
db = SQLAlchemy(app)


@dataclass
class Database(db.Model):
    name: str
    ip: str
    name = db.Column(db.String(30), primary_key=True)
    ip = db.Column(db.String(16), unique=True)

    def __init__(self, name, ip):
        self.name = name
        self.ip = ip


@app.route('/')
def index():
    return render_template('index.html', db_entries=Database.query.all())


@app.route('/create', methods=['POST'])
def create():
    if request.method == 'POST':
        json_post = json.loads(request.data)
        data = Database(json_post['name'], json_post['ip'])
        db.session.add(data)
        db.session.commit()
        return jsonify(data)


@app.route('/update', methods=['POST'])
def update():
    if request.method == 'POST':
        json_post = json.loads(request.data)
        old_value = copy.deepcopy(Database.query.get(json_post['name']))
        Database.query.filter_by(name=json_post['name']).update(dict(ip=json_post['ip']))
        db.session.commit()
        return jsonify(old=old_value, new=json_post)


@app.route('/delete', methods=['POST'])
def delete():
    if request.method == 'POST':
        json_post = json.loads(request.data)
        query = Database.query.get(json_post['name'])
        db.session.delete(query)
        db.session.commit()
        return jsonify(json_post)


@app.route('/storage', methods=['GET'])
def storage():
    db_entries = Database.query.all()
    return jsonify(db_entries)


if __name__ == '__main__':
    db.create_all()
    app.run(host="0.0.0.0", debug=True)
