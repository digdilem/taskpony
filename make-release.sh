#!/bin/bash
# To manually release the public version of Taskpony

# 1. Fetch latest from local repo
echo "Fetching latest from local repo..."
cd /opt/taskpony
git pull

# 2. Update github repo
# # git remote add github https://github.com/digdilem/taskpony

echo "Pushing to github..."
git push github main

# Build the TaskPony Docker image

echo "Building Docker image..."
docker build -t taskpony:latest .
docker tag taskpony:latest digdilem/taskpony:latest

echo "Pushing Docker image to Docker Hub..."
docker push digdilem/taskpony:latest

echo "To confirm upload, check it at:  https://hub.docker.com/repositories/digdilem"

# End of file
