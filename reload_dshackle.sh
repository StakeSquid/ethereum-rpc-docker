#!/bin/bash

docker ps -q -f "name=dshackle" | xargs -r docker kill --signal=HUP
