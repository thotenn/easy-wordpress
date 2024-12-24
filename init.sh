#!/bin/bash
# This is for a Ubuntu 24.04 LTS server
# This script you can use to setup a WordPress site with Docker, just one time

# Vars
DOMAIN="mysite.com"
APP_PATH="/home/apps/wordpress"

echo "=== Starting WordPress with Docker installation process ==="

echo "Step 1: Creating necessary directories..."
if [ ! -d "$APP_PATH" ]; then
    echo "Creating directory $APP_PATH"
    mkdir -p $APP_PATH
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create $APP_PATH"
        exit 1
    fi
fi

mkdir -p $APP_PATH/{nginx,db_data,wp_data,certbot/conf,certbot/www}
echo "✓ Directories created successfully"

echo "Step 2: Creating SSL renewal script..."
cat > $APP_PATH/ssl-renew.sh << 'EOL'
#!/bin/bash
docker-compose -f $APP_PATH/docker-compose.yml run --rm certbot renew
docker-compose -f $APP_PATH/docker-compose.yml restart webserver
EOL
echo "✓ SSL renewal script created"

echo "Step 3: Creating initial Nginx configuration..."
cat > $APP_PATH/nginx/default.conf << EOL
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 64M;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        proxy_pass http://wordpress_wordpress_1;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
    }
}
EOL
echo "✓ Nginx configuration created"

echo "Step 4: Copying configuration files..."
cp docker-compose.yml $APP_PATH/
cp .env $APP_PATH/
cp .restart.sh $APP_PATH/
echo "✓ Configuration files copied"

echo "Step 5: Updating system packages..."
apt update && apt upgrade -y

echo "Step 6: Installing dependencies..."
apt install -y apt-transport-https ca-certificates curl gnupg lsb-release

echo "Step 7: Adding Docker repository..."
# Add GPG docker key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Add repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "Step 8: Installing Docker and required packages..."
apt update
apt install -y docker-ce docker-ce-cli docker-compose containerd.io certbot python3-certbot-nginx

echo "Step 9: Verifying Docker installation..."
docker --version

echo "Step 10: Configuring firewall..."
sudo ufw allow 80/tcp
ufw allow 443/tcp
ufw enable

echo "Step 11: Checking and stopping conflicting services..."
sudo lsof -i :80
sudo systemctl stop apache2
sudo systemctl stop nginx

echo "Step 12: Starting Docker containers..."
cd $APP_PATH
docker-compose up -d

echo "Step 13: Waiting for containers to be ready..."
while [ "$(docker ps -q --filter name=wordpress_webserver_1 | xargs docker inspect -f '{{.State.Running}}' 2>/dev/null)" != "true" ]; do
    echo "Waiting for webserver container to be running..."
    sleep 5
done
echo "✓ Containers are ready"

echo "Step 14: Configuring SSL settings..."
cat > $APP_PATH/nginx/default.conf << EOL
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    client_max_body_size 64M;

    location / {
        proxy_pass http://wordpress:80;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
    }
}
EOL
echo "✓ SSL configuration created"

echo "Step 15: Obtaining SSL certificate..."
docker-compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot -d $DOMAIN

echo "Step 16: Setting up SSL auto-renewal..."
chmod +x $APP_PATH/ssl-renew.sh
(crontab -l 2>/dev/null; echo "0 12 1,15 * * $APP_PATH/ssl-renew.sh >> /var/log/le-renew.log 2>&1") | crontab -

echo "Step 17: Creating systemd service for auto-restart..."
cat > /etc/systemd/system/wordpress-restart.service << EOL
[Unit]
Description=WordPress Docker Restart Service
After=docker.service network.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$APP_PATH/restart.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOL

echo "Step 18: Configuring systemd service..."
chmod +x $APP_PATH/restart.sh
chmod 644 /etc/systemd/system/wordpress-restart.service
systemctl daemon-reload
systemctl enable wordpress-restart.service
systemctl start wordpress-restart.service

echo "=== Installation completed! ==="
echo "Your WordPress site should be available at https://$DOMAIN"
echo "SSL certificates will automatically renew on the 1st and 15th of each month"
echo "The application will automatically restart on system reboot"