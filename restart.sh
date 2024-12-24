#!/bin/bash

APP_PATH="/home/apps/wordpress"

echo "Step 1: Checking and stopping conflicting services..."
sudo lsof -i :80
sudo systemctl stop apache2
sudo systemctl stop nginx

echo "Step 2: Restarting Docker containers..."
cd $APP_PATH
docker-compose down
docker-compose up -d

echo "Step 13: Waiting for containers to be ready..."
while [ "$(docker ps -q --filter name=wordpress-webserver-1 | xargs docker inspect -f '{{.State.Running}}' 2>/dev/null)" != "true" ]; do
    echo "Waiting for webserver container to be running..."
    sleep 5
done
echo "✓ Containers are ready"
echo "✓ Application is ready"