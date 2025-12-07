#!/bin/bash
# Build the TaskPony Docker image

# To be run on docker-host

cd /docker-data/taskpony/my-scripts/taskpony

git pull

docker build -t taskpony:latest .

docker login

docker tag taskpony:latest digdilem/taskpony:latest

docker push digdilem/taskpony:latest

# To confirm upload, check it at:  https://hub.docker.com/repositories/digdilem

