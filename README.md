# 🚀 WordPress with Docker, Nginx and SSL

Automated system to deploy WordPress with Docker, including Nginx as reverse proxy and automatic SSL certificates.

## ⚙️ Prerequisites
- Ubuntu Server 24.04 LTS
- Root access
- Domain pointing to server

## 🛠️ Configuration
You only need to modify two variables in `init.sh`:
```bash
DOMAIN="your-domain.com"
APP_PATH="/installation/path"
```

## 🚀 Installation
```bash
chmod +x init.sh
./init.sh
```

## ✨ Features
- Latest WordPress
- MySQL 5.7
- Latest Nginx as reverse proxy
- Automatic SSL certificates with Let's Encrypt
- Automatic SSL renewal
- Configurable environment variables

## 🔍 Tested on
- DigitalOcean Droplet
- Ubuntu Server 24.04 LTS

## 📝 Notes
- SSL renewal is scheduled for the 1st and 15th of each month
- SSL renewal logs are located at `/var/log/le-renew.log`
- WordPress and MySQL data persist in Docker volumes

## 🔐 Security
- Automatic HTTP to HTTPS redirection
- Free and automatic SSL certificates
- Secure Nginx configuration
