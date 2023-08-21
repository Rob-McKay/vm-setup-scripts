#!/bin/sh
set -eu

randpw(){ < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-16};echo;}


PHP_VERSION=8.1

DB_HOST=localhost
DB_NAME=moodle
DB_USER=moodleuser
DB_PASSWORD=$(randpw)

WEB_ROOT=http://$(hostname -f)

# bool function to test if the user is root or not
is_user_root () { [ "${EUID:-$(id -u)}" -eq 0 ]; }

if ! is_user_root; then
	echo 'This needs admin rights. Run with sudo or as root' >&2
	exit 1
fi

set -eux

if true ; then
# Ensure everything is up to date
apt update && apt upgrade

# Add a few needed packages
apt install wget curl joe ufw software-properties-common dirmngr apt-transport-https gnupg2 ca-certificates lsb-release debian-archive-keyring unzip git -y

# Configure Firewall
ufw allow http
ufw allow https


# Add PHP package store to allow explicit version of PHP to be installed

# import Sury's repo PHP GPG key.
curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
# Add Sury's PHP repository.
sh -c 'echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'
# Update the system repository list.
apt update

# Install PHP 8.1 (Latest version supported by Moodle 4.1 LTS)
apt install php$PHP_VERSION-fpm php8.1-cli -y

# Install MariaDB
apt install mariadb-server -y

# Run the MariaDB secure install script supplying answers to remove the bits we do not reqire.
mysql_secure_installation << EOF

n
n
y
y
y
y
EOF

# Add the official Nginx package repository signing key
curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

# Add the official Nginx package repository
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/debian `lsb_release -cs` nginx" | tee /etc/apt/sources.list.d/nginx.list

apt update

# Install Nginx
apt install nginx -y

# Make the webroot folder
if [ ! -d /var/www/html/moodle ]; then
	mkdir -p /var/www/html/moodle
fi

# Configure nginx moodle website
tee /etc/nginx/conf.d/default.conf << 'EOF2' > /dev/null
server {
#	listen       443 ssl http2;
#	listen       [::]:443 ssl http2;
	listen       80;
	listen       [::]:80;
	server_name  vm1.development.4mation.co.uk.local;
    
	root /var/www/html/moodle;

	index index.php index.html;

	location / {
		try_files $uri $uri/ /index.php?$query_string;
	}

	# Pass PHP Scripts To FastCGI Server
	location ~ \.php$ {
		fastcgi_split_path_info ^(.+\.php)(/.+)$;
		fastcgi_pass unix:/run/php/php8.1-fpm.sock; #depends on PHP versions
		fastcgi_index index.php;
		fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
		include fastcgi_params;
	}

	location ~ /\.(?!well-known).* {
		deny all;
	}
	
	location /dataroot/ {
		internal;
		alias /var/moodle/moodledata/; # ensure the path ends with /
	}
}

# enforce HTTPS
#server {
#	listen       80;
#	listen       [::]:80;
#	server_name  vm1.development.4mation.co.uk.local;
#	return 301   https://$host$request_uri;
#}

EOF2

# Start Nginx
systemctl start nginx

# Increase some PHP limits
sed -i 's/post_max_size = 8M/post_max_size = 50M/' /etc/php/$PHP_VERSION/fpm/php.ini
sed -i 's/upload_max_filesize = 2M/upload_max_filesize = 50M/' /etc/php/$PHP_VERSION/fpm/php.ini
sed -i 's/memory_limit = 128M/memory_limit = 256M/' /etc/php/$PHP_VERSION/fpm/php.ini
sed -i '/^;max_input_vars =.*/a max_input_vars = 6000' /etc/php/$PHP_VERSION/fpm/php.ini
sed -i '/^;max_input_vars =.*/a max_input_vars = 6000' /etc/php/$PHP_VERSION/cli/php.ini

sed -i 's/www-data/nginx/' /etc/php/$PHP_VERSION/fpm/pool.d/www.conf

systemctl restart php$PHP_VERSION-fpm

# Configure Opcache
apt install php$PHP_VERSION-opcache -y

# Add additional packages and PHP extensions
apt install php$PHP_VERSION-common php$PHP_VERSION-mbstring php$PHP_VERSION-curl openssl php$PHP_VERSION-soap php$PHP_VERSION-zip php$PHP_VERSION-gd php$PHP_VERSION-xml php$PHP_VERSION-intl php$PHP_VERSION-mysql -y

#systemctl restart nginx


# Install moodle files from the moodle git repo
cd /var/www/html

if [ -d moodle ]; then
	rm -rf moodle
fi

#if [ ! -d moodle ]; then
git clone -b MOODLE_401_STABLE git://git.moodle.org/moodle.git
git config --global --add safe.directory /var/www/html/moodle
#else
#cd moodle
#git pull
#cd ..
#fi


fi

chown -R root:nginx /var/www/html/moodle
chmod -R 0755 /var/www/html/moodle

# Create the moodle data directory
mkdir -p /var/moodle/moodledata
chmod 0777 /var/moodle/moodledata
chown nginx:nginx /var/moodle/moodledata


# Crete the moodle database
mysql << SQL
DROP DATABASE IF EXISTS $DB_NAME;
DROP USER IF EXISTS $DB_USER;
CREATE DATABASE $DB_NAME DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER $DB_USER IDENTIFIED BY '$DB_PASSWORD';
GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,CREATE TEMPORARY TABLES,DROP,INDEX,ALTER ON $DB_NAME.* TO $DB_USER;
quit
SQL

chown nginx /var/www/html/moodle
cd /var/www/html/moodle/admin/cli


# Run the moodle installer in command line mode
#
# Parameters
# --lang=CODE           Installation and default site language.
# --wwwroot=URL         Web address for the Moodle site,
#                       required in non-interactive mode.
# --dataroot=DIR        Location of the moodle data folder,
#                       must not be web accessible. Default is moodledata
#                       in the parent directory.
# --dbtype=TYPE         Database type. Default is mysqli
# --dbhost=HOST         Database host. Default is localhost
# --dbname=NAME         Database name. Default is moodle
# --dbuser=USERNAME     Database user. Default is root
# --dbpass=PASSWORD     Database password. Default is blank
# --dbport=NUMBER       Use database port.
# --dbsocket=PATH       Use database socket, 1 means default. Available for some databases only.
# --prefix=STRING       Table prefix for above database tables. Default is mdl_
# --fullname=STRING     The fullname of the site
# --shortname=STRING    The shortname of the site
# --summary=STRING      The summary to be displayed on the front page
# --adminuser=USERNAME  Username for the moodle admin account. Default is admin
# --adminpass=PASSWORD  Password for the moodle admin account,
#                       required in non-interactive mode.
# --adminemail=STRING   Email address for the moodle admin account.
# --sitepreset=STRING   Admin site preset to be applied during the installation process.
# --supportemail=STRING Email address for support and help.
# --upgradekey=STRING   The upgrade key to be set in the config.php, leave empty to not set it.
# --non-interactive     No interactive questions, installation fails if any
#                       problem encountered.
# --agree-license       Indicates agreement with software license,
#                       required in non-interactive mode.

runuser -u nginx -- /usr/bin/php install.php --lang=en --wwwroot=$WEB_ROOT --dataroot=/var/moodle/moodledata \
	--dbtype=mariadb --dbhost=$DB_HOST --dbuser=$DB_USER --dbpass=$DB_PASSWORD \
	--adminuser=admin --adminpass=Pa55word \
	--fullname='Super Learning Series' --shortname=SLS \
	--agree-license --non-interactive


runuser -u nginx -- /usr/bin/php build_theme_css.php --themes=boost

chown -R root /var/www/html/moodle

