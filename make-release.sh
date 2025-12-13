#!/bin/bash
# To manually release the public version of Taskpony
# Run on dev machine

# 1. Fetch latest from local repo
git pull

# 2. Update github repo
# # git remote add github https://github.com/digdilem/taskpony

git push github main

# Build the TaskPony Docker image

# To be run on docker-host

cd /docker-data/taskpony/my-scripts/taskpony

git pull

docker build -t taskpony:latest .

#docker login

docker tag taskpony:latest digdilem/taskpony:latest

# docker push digdilem/taskpony:latest

# To confirm upload, check it at:  https://hub.docker.com/repositories/digdilem

# End of file
