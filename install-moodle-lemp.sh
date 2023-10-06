#!/bin/sh
set -eu

randpw(){ < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-16};echo;}

ADMIN_USER=admin
ADMIN_PASSWORD=Pa55word
ADMIN_EMAIL=$ADMIN_USER@$(hostname -f)


MOODLE_VERSION=MOODLE_401_STABLE
#MOODLE_REPO=git://git.moodle.org/moodle.git
MOODLE_REPO=https://github.com/SuperLearningSeries/moodle.git

PHP_VERSION=8.1

DB_HOST=localhost
DB_NAME=moodle
DB_USER=moodleuser
DB_PASSWORD=$(randpw)

SITE_FULLNAME='SuperLearningSeries'
SITE_SHORTNAME='SuperLearningSeries' 
SITE_SUMMARY='WELCOME TO SUPER LEARNING'

WEB_ROOT=http://$(hostname -f)



# bool function to test if the user is root or not
is_user_root () { [ "${EUID:-$(id -u)}" -eq 0 ]; }


update_packages() {
	# Add PHP package store to allow explicit version of PHP to be installed

	# import Sury's repo PHP GPG key.
	curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
	# Add Sury's PHP repository.
	sh -c 'echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'

	# Add the official Nginx package repository signing key
	curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

	# Add the official Nginx package repository
	echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/debian `lsb_release -cs` nginx" | tee /etc/apt/sources.list.d/nginx.list

	# Ensure everything is up to date
	apt update && apt upgrade -y
}


install_required_prereqs() {
	# Add a few needed packages
	apt install -y wget curl joe ufw software-properties-common dirmngr apt-transport-https gnupg2 ca-certificates lsb-release debian-archive-keyring unzip git

	# Configure Firewall
	ufw allow http
	ufw allow https

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

	# Install Nginx
	apt install nginx -y

	# Make the webroot folder
	if [ ! -d /var/www/html/moodle ]; then
		mkdir -p /var/www/html/moodle
	fi

	# Configure nginx moodle website
	tee /etc/nginx/conf.d/default.conf << 'EOF2' > /dev/null
server {
#       listen       443 ssl http2;
#       listen       [::]:443 ssl http2;
        listen       80 default_server;
        listen       [::]:80 default_server;
#       server_name  vm1.development.4mation.co.uk.local;
    
        root /var/www/html/moodle;

        index index.php index.html;

        location ~ [^/]\.php(/|$) {
                fastcgi_split_path_info ^(.+?\.php)(/.*)$;
                if (!-f $document_root$fastcgi_script_name) {
                        return 404;
                }

                # Mitigate https://httpoxy.org/ vulnerabilities
                fastcgi_param HTTP_PROXY "";

                fastcgi_pass unix:/run/php/php8.1-fpm.sock;
                fastcgi_index index.php;

                # include the fastcgi_param setting
                include fastcgi_params;

                fastcgi_param   PATH_INFO       $fastcgi_path_info;
                fastcgi_param  SCRIPT_FILENAME   $document_root$fastcgi_script_name;
        }
        
        location /images/ {
        	root /var/www/html;
        	sendfile on;
        	sendfile_max_chunk 1m;
        	tcp_nodelay       on;
		keepalive_timeout 65;
        }

}

# enforce HTTPS
#server {
#       listen       80;
#       listen       [::]:80;
#       server_name  vm1.development.4mation.co.uk.local;
#       return 301   https://$host$request_uri;
#}

EOF2

	# Start Nginx
	systemctl start nginx

	# Increase some PHP limits (fpm)
	sed -i 's/post_max_size = 8M/post_max_size = 50M/' /etc/php/$PHP_VERSION/fpm/php.ini
	sed -i 's/upload_max_filesize = 2M/upload_max_filesize = 50M/' /etc/php/$PHP_VERSION/fpm/php.ini
	sed -i 's/memory_limit = 128M/memory_limit = 256M/' /etc/php/$PHP_VERSION/fpm/php.ini
	sed -i '/^;max_input_vars =.*/a max_input_vars = 6000' /etc/php/$PHP_VERSION/fpm/php.ini
	
	sed -i 's/www-data/nginx/' /etc/php/$PHP_VERSION/fpm/pool.d/www.conf
	
	# Increase some PHP limits (cli[B)
	sed -i '/^;max_input_vars =.*/a max_input_vars = 6000' /etc/php/$PHP_VERSION/cli/php.ini

	systemctl restart php$PHP_VERSION-fpm

	# Configure Opcache
	apt install php$PHP_VERSION-opcache -y

	# Add additional packages and PHP extensions
	apt install php$PHP_VERSION-common php$PHP_VERSION-mbstring php$PHP_VERSION-curl openssl php$PHP_VERSION-soap php$PHP_VERSION-zip php$PHP_VERSION-gd php$PHP_VERSION-xml php$PHP_VERSION-intl php$PHP_VERSION-mysql -y
}



download_moodle()
{
	# Install moodle files from the moodle git repo
	cd /var/www/html

	if [ -d moodle ]; then
		rm -rf moodle
	fi

	git clone $MOODLE_REPO --branch $MOODLE_VERSION --single-branch
	# Add repo as a safe directory because it is owned by root!
	git config --global --add safe.directory /var/www/html/moodle

	chown -R root:nginx /var/www/html/moodle
	chmod -R 0755 /var/www/html/moodle
}


update_moodle()
{
	# Install moodle files from the moodle git repo
	cd /var/www/html/moodle

	git checkout $MOODLE_VERSION
	git pull

	chown -R root:nginx /var/www/html/moodle
	chmod -R 0755 /var/www/html/moodle
}



install_moodle() {
	# Install moodle files from the moodle git repo
	cd /var/www/html

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

	# Change the moodle code to be owned by nginx to allow the install script to complete properly

	chown nginx /var/www/html/moodle
	cd /var/www/html/moodle/admin/cli

	# Run the moodle installer in command line mode
	#
	# Parameters
	# --lang=CODE           Installation and default site language.
	# --wwwroot=URL         Web address for the Moodle site, required in non-interactive mode.
	# --dataroot=DIR        Location of the moodle data folder, must not be web accessible. Default is moodledata in the parent directory.
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
	# --adminpass=PASSWORD  Password for the moodle admin account, required in non-interactive mode.
	# --adminemail=STRING   Email address for the moodle admin account.
	# --sitepreset=STRING   Admin site preset to be applied during the installation process.
	# --supportemail=STRING Email address for support and help.
	# --upgradekey=STRING   The upgrade key to be set in the config.php, leave empty to not set it.
	# --non-interactive     No interactive questions, installation fails if any problem encountered.
	# --agree-license       Indicates agreement with software license, required in non-interactive mode.

	runuser -u nginx -- /usr/bin/php install.php --lang=en --wwwroot=$WEB_ROOT --dataroot=/var/moodle/moodledata \
		--dbtype=mariadb --dbhost=$DB_HOST --dbuser=$DB_USER --dbpass=$DB_PASSWORD \
		--adminuser=$ADMIN_USER --adminpass=$ADMIN_PASSWORD --adminemail=$ADMIN_EMAIL \
		--fullname="$SITE_FULLNAME" --shortname="$SITE_SHORTNAME" --summary="$SITE_SUMMARY" \
		--agree-license --non-interactive

	# Install the adaptable moodle theme
	cd /var/www/html/moodle/theme
	curl https://moodle.org/plugins/download.php/29152/theme_adaptable_moodle41_2022112306.zip -o ~/theme_adaptable_moodle.zip
	unzip ~/theme_adaptable_moodle.zip

	cd /var/www/html/moodle/admin/cli
	php cfg.php --name=theme --set=adaptable
	php cfg.php --name=sitedefaultlicense --set='allrightsreserved'
	php cfg.php --name=additionalhtmltopofbody --set='<audio id="PnA_player"></audio>'
	php cfg.php --name=hiddenuserfields --set='description,email,city,country,moodlenetprofile,timezone,firstaccess,lastaccess,lastip,mycourses,groups,suspended'
	php cfg.php --name=showuseridentity --set=''
	php cfg.php --name=defaultrequestcategory --set=2
	php cfg.php --name=locale --set='en_GB.UTF-8'
	php cfg.php --name=defaulthomepage --set=0
	php cfg.php --name=navshowfullcoursenames --set=1
	php cfg.php --name=navadduserpostslinks --set=0
	php cfg.php --name=allowguestmymoodle --set=0
	php cfg.php --name=frontpage --set='6,0'
	php cfg.php --name=frontpageloggedin --set='5,6'
	php cfg.php --name=coursecontact --set=''
	php cfg.php --name=enableblogs --set=0
	php cfg.php --name=docroot --set=''
		
	php cfg.php --component=quiz --name=browsersecurity --set='securewindow'
	php cfg.php --component=quiz --name=decimalpoints --set='0'
	php cfg.php --component=quiz --name=shuffleanswers --set='0'
	
	php cfg.php --component=theme_adaptable --name=maincolor --set='#03BE07'
	php cfg.php --component=theme_adaptable --name=backcolor --set='#FFFEEDB'
	php cfg.php --component=theme_adaptable --name=regionmaincolor --set='#FFEEDB'
	php cfg.php --component=theme_adaptable --name=linkhover --set='#05005A'
	php cfg.php --component=theme_adaptable --name=selectionbackground --set='#05005A'
	php cfg.php --component=theme_adaptable --name=loadingcolor --set='#69B4FC'
	php cfg.php --component=theme_adaptable --name=msgbadgecolor --set='#FF7014'
	php cfg.php --component=theme_adaptable --name=messagingbackgroundcolor --set='#FFEEDB'
	php cfg.php --component=theme_adaptable --name=headerbkcolor --set='#1000A5'
	php cfg.php --component=theme_adaptable --name=headerbkcolor2 --set='#69B4FC'
	php cfg.php --component=theme_adaptable --name=rendereroverlaycolor --set='#A0D7FD'
	php cfg.php --component=theme_adaptable --name=enableavailablecourses --set='hide'
	php cfg.php --component=theme_adaptable --name=tickertext1 --set='Download free spelling worksheets'
	php cfg.php --component=theme_adaptable --name=tabbedlayoutcoursepage --set='0-2-1'
	php cfg.php --component=theme_adaptable --name=tabbedlayoutdashboard --set='0-2-1'
	php cfg.php --component=theme_adaptable --name=buttoncolor --set='#020D82'
	php cfg.php --component=theme_adaptable --name=buttonhovercolor --set='#55BBFB'
	php cfg.php --component=theme_adaptable --name=buttoncolorscnd --set='#020D82'
	php cfg.php --component=theme_adaptable --name=buttonhovercolorscnd --set='#55BBFB'
	php cfg.php --component=theme_adaptable --name=categoryhavecustomheader --set=2
	php cfg.php --component=theme_adaptable --name=enableticker --set=''
	php cfg.php --component=theme_adaptable --name=enabletickermy --set=''
	php cfg.php --component=theme_adaptable --name=tickertext1 --set='<p><a href="/mod/folder/view.php?id=8">Download free spelling worksheets</a></p>'
	php cfg.php --component=theme_adaptable --name=moodledocs --set=0
	php cfg.php --component=theme_adaptable --name=gdprbutton --set=''
	php cfg.php --component=theme_adaptable --name=marketlayoutrow1 --set='12-0-0-0'
	php cfg.php --component=theme_adaptable --name=market1 --set='<h1 style="text-align: center;"><a href="mod/folder/view.php?UKSpellingWorksheets.pdf"><strong>Download our free worksheets</strong></a></h1>'
	#php cfg.php --component=theme_adaptable --name=frontpagemarketenabled --set=1
	php cfg.php --component=theme_adaptable --name=frontpagemarketenabled --set='1'
	php cfg.php --component=theme_adaptable --name=fontname --set='Urbanist'
	php cfg.php --component=theme_adaptable --name=customcss --set='@font-face { font-family: Urbanist; src: url(fonts/urbanist.ttf);}'
	php cfg.php --component=theme_adaptable --name=fontheadername --set='Urbanist'
	php cfg.php --component=theme_adaptable --name=fonttitlename --set='Urbanist'
	
	php mysql_compressed_rows.php --fix
	
	runuser -u nginx -- /usr/bin/php build_theme_css.php --themes=adaptable

	# Site defaults may be changed via local/defaults.php
	runuser -u nginx -- /usr/bin/php upgrade.php --non-interactive
	
	# Reset owner
	chown -R root /var/www/html/moodle
	
	# Setup cron
	# Delete any existing entry
	(crontab -u nginx -l 2>/dev/null || echo "" | sed '\/var/www/html/moodle/admin/cli/cron.php\d'; echo '* * * * * /usr/bin/php /var/www/html/moodle/admin/cli/cron.php 2>&1 | /usr/bin/logger -tMoodleCron') | crontab -u nginx -
}


if ! is_user_root; then
	echo 'This needs admin rights. Run with sudo or as root' >&2
	exit 1
fi



set -eux

update_packages
install_required_prereqs

download_moodle
#update_moodle

install_moodle

