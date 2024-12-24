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
while [ "$(docker-compose ps -q wordpress_webserver_1 | xargs docker inspect -f '{{.State.Running}}')" != "true" ]; do
    echo "Waiting wordpress_webserver_1 container to be running..."
    sleep 5
done
echo "✓ Containers are ready"
echo "✓ Application is ready"