#!/bin/bash

source "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/load_env.sh"
load_env

echo "Step 1: Checking and stopping conflicting services..."
sudo lsof -i :80
sudo systemctl stop apache2
sudo systemctl stop nginx

echo "Step 2: Restarting Docker containers..."
cd "$APP_PATH" || exit 1
docker-compose down 2>/dev/null || true  # Ensure that any existing containers are stopped

PROFILES="--profile always"
if [ "$USE_WEBSERVER" = "true" ]; then
    PROFILES="--profile always --profile webserver"
    if [ "$USE_SSL" = "true" ]; then
        PROFILES="$PROFILES --profile ssl"
    fi
fi

docker-compose $PROFILES up -d

if [ "$USE_WEBSERVER" = "true" ]; then
    echo "Step 13: Waiting for containers to be ready..."
    while [ "$(docker ps -q --filter name=wordpress_webserver_1 | xargs docker inspect -f '{{.State.Running}}' 2>/dev/null)" != "true" ]; do
        echo "Waiting for webserver container to be running..."
        sleep 5
    done
fi
echo "✓ Containers are ready"
echo "✓ Application is ready"