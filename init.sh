#!/bin/bash
# This is for a Ubuntu 24.04 LTS server
# This script you can use to setup a WordPress site with Docker, just one time

# Vars
DOMAIN="mysite.com"
APP_PATH="/home/apps/wordpress"

if [ ! -d "$APP_PATH" ]; then
    echo "Creating directory $APP_PATH"
    mkdir -p $APP_PATH
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create $APP_PATH"
        exit 1
    fi
fi

mkdir -p $APP_PATH/{nginx,db_data,wp_data,certbot/conf,certbot/www}

cat > $APP_PATH/ssl-renew.sh << 'EOL'
#!/bin/bash
docker-compose -f $APP_PATH/docker-compose.yml run --rm certbot renew
docker-compose -f $APP_PATH/docker-compose.yml restart webserver
EOL

cat > $APP_PATH/nginx/default.conf << EOL
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_pass http://wordpress:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

cp docker-compose.yml $APP_PATH/
cp .env $APP_PATH/

apt update && apt upgrade -y

# Install dependencies
apt install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Add GPG docker key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Add repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
apt update
apt install -y docker-ce docker-ce-cli docker-compose containerd.io certbot python3-certbot-nginx

# Verify installation
docker --version

# Add user to docker group
ufw allow 443/tcp
ufw enable

cd $APP_PATH
docker-compose up -d
docker-compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot -d $DOMAIN
chmod +x $APP_PATH/ssl-renew.sh
(crontab -l 2>/dev/null; echo "0 12 1,15 * * $APP_PATH/ssl-renew.sh >> /var/log/le-renew.log 2>&1") | crontab -