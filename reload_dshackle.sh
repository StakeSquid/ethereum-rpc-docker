#!/bin/bash

docker ps -q -f "name=dshackle" | xargs -r docker kill --signal=HUP
docker ps -q -f "name=dshackle-free" | xargs -r docker kill --signal=HUP
