#!/bin/bash
# To manually release the public version of Taskpony

# Check we've been called with the version number as first parameter
ver="$1"

if [[ -z "$ver" ]]; then
  echo "Error: missing version number string as first argument" >&2
  echo "Value should be the version number, eg: $0 'v.0.2'" >&2
  exit 1
fi

# 1. Fetch latest from local repo
echo "Fetching latest from local repo..."
cd /opt/taskpony
git pull

echo "Press any key to continue, or Ctrl+C to abort..."
read -r -n 1 -s

# 2. Create git tag for this version
echo "Tagging version for $ver and updating gitea"
git tag -a "$ver" -m "Release $ver"
git push origin "$ver"

echo "Press any key to continue, or Ctrl+C to abort..."
read -r -n 1 -s

# 3. Build the TaskPony Docker image
echo "Building Docker image for $ver..."
docker build -t taskpony:$ver -t digdilem/taskpony:$ver -t digdilem/taskpony:latest .

echo "Press any key to continue, or Ctrl+C to abort..."
read -r -n 1 -s

# 4. Push to Docker Hub
# Prompt user for Yes/No and exit if No

read -r -p "Next steps will update public github and Docker Hub repositories.  Do you want to Continue? [y/N] " a && [[ $a =~ ^([yY][eE][sS]|[yY])$ ]] || exit 1

# 5. Looks like we're ready to go public, 
# Update github public repo

echo "Pushing to github..."
git push github main --force

echo "Press any key to continue, or Ctrl+C to abort..."
read -r -n 1 -s

# 6. Push new images to Docker Hub

echo "Pushing Docker image to Docker Hub for versions $ver and latest..."
docker push digdilem/taskpony:$ver
docker push digdilem/taskpony:latest


echo "To confirm upload, check it at:  https://hub.docker.com/repositories/digdilem"

echo "Completed."


# End of file
