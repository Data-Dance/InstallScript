#!/bin/bash
################################################################################
# Script for installing Odoo 19 on Ubuntu 24.04 (could be used for other version too)
# Author: Yenthe Van Ginneken
#-------------------------------------------------------------------------------
# This script will install Odoo on your Ubuntu server. It can install multiple Odoo instances
# in one Ubuntu because of the different xmlrpc_ports
#-------------------------------------------------------------------------------
# Make a new file:
# sudo nano odoo-install.sh
# Place this content in it and then make the file executable:
# sudo chmod +x odoo-install.sh
# Execute the script to install Odoo:
# ./odoo-install
################################################################################

OE_USER="odoo"
OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"
# The default port where this Odoo instance will run under (provided you use the command -c in the terminal)
# Set to true if you want to install it, false if you don't need it or have it already installed.
INSTALL_WKHTMLTOPDF="True"
# Set the default Odoo port (you still have to use -c /etc/odoo-server.conf for example to use this.)
OE_PORT="8069"
# Choose the Odoo version which you want to install. For example: 16.0, 15.0, 14.0 or saas-22. When using 'master' the master version will be installed.
# IMPORTANT! This script contains extra libraries that are specifically needed for Odoo 17.0
OE_VERSION="19.0"
# Set this to True if you want to install the Odoo enterprise version!
IS_ENTERPRISE="False"
# Installs postgreSQL V16 instead of defaults (e.g V12 for Ubuntu 20/22) - this improves performance
INSTALL_POSTGRESQL_SIXTEEN="True"
# Set this to True if you want to install Nginx!
INSTALL_NGINX="False"
# Set the superadmin password - if GENERATE_RANDOM_PASSWORD is set to "True" we will automatically generate a random password, otherwise we use this one
OE_SUPERADMIN="admin"
# Set to "True" to generate a random password, "False" to use the variable in OE_SUPERADMIN
GENERATE_RANDOM_PASSWORD="True"
OE_CONFIG="${OE_USER}-server"
# Set the website name. Accepts several space-separated names -- every one is
# put in nginx's server_name and included in the certificate, e.g.
#   WEBSITE_NAME="example.sk www.example.sk example.eu www.example.eu"
# The first name is the primary: it names the vhost file and the certificate.
WEBSITE_NAME="_"
# Clone Odoo's design themes (public repo) and add them to the addons path.
INSTALL_DESIGN_THEMES="True"
# Install a catch-all nginx vhost that refuses hostnames no site claims.
# Strongly recommended when a host serves more than one domain, and required
# if any wildcard DNS record points here -- see the block that installs it.
INSTALL_DEFAULT_DENY="True"
# Set the default Odoo longpolling port (you still have to use -c /etc/odoo-server.conf for example to use this.)
LONGPOLLING_PORT="8072"
# Number of Odoo worker processes. "auto" sizes it from CPU count and RAM;
# set a number to pin it. 0 means single-threaded -- development only.
OE_WORKERS="auto"
# Serve only one database and disable the web database manager. Strongly
# recommended for anything reachable from the internet.
LOCK_DATABASE="True"
# The database this instance serves. Used for db_name/dbfilter when
# LOCK_DATABASE is True; leave empty to skip the restriction.
OE_DB_NAME="$OE_USER"
# Set to "True" to install certbot and have ssl enabled, "False" to use http
ENABLE_SSL="True"
# Provide Email to register ssl certificate
ADMIN_EMAIL="odoo@example.com"

# Helper: pip install with optional --break-system-packages (Ubuntu 24.04 / PEP 668)
pip_install() {
  if pip3 help install 2>/dev/null | grep -q -- '--break-system-packages'; then
    sudo -H pip3 install --break-system-packages "$@"
  else
    sudo -H pip3 install "$@"
  fi
}

# Return true when version $1 is strictly newer than version $2.
#
# Do not write `[ $OE_VERSION > "15.0" ]`: inside [ ], `>` is the shell's
# output REDIRECTION operator, not a comparison. That form silently creates an
# empty file named "15.0" in the current directory and reduces the test to
# `[ $OE_VERSION ]`, i.e. "is the string non-empty" -- always true. It happened
# to pick the right branch for 18.0/19.0 while being wrong for 11.0 and 15.0.
version_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# WEBSITE_NAME may list several names. nginx takes them all in server_name as
# they are, but the vhost filename and certbot need handling:
#   WEBSITE_PRIMARY  - first name; names the vhost file and the certificate
#   CERTBOT_DOMAINS  - "-d a -d b -d c ..." for certbot
WEBSITE_PRIMARY=$(set -- $WEBSITE_NAME; echo "$1")
CERTBOT_DOMAINS=""
for _d in $WEBSITE_NAME; do
    CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $_d"
done
##
###  WKHTMLTOPDF download links
## === Ubuntu Trusty x64 & x32 === (for other distributions please replace these two links,
## in order to have correct version of wkhtmltopdf installed, for a danger note refer to
## https://github.com/odoo/odoo/wiki/Wkhtmltopdf ):
## https://www.odoo.com/documentation/19.0/administration/install.html

# Odoo needs the 0.12.6 build "with patched qt" -- the plain build renders
# headers and footers incorrectly. Two things make this awkward:
#
#   * Ubuntu dropped wkhtmltopdf from its archive; there is no candidate at all
#     on 26.04 (`apt-cache policy wkhtmltopdf` shows none), so "apt install
#     wkhtmltopdf" is not a fallback on current releases.
#   * The upstream project is archived, so jammy (22.04) is the newest Ubuntu
#     build ever published. It installs cleanly on later releases -- its
#     dependencies (xfonts-*, libfontenc1) are all still in the archive.
#
# So: try the build matching this release, then walk back to the newest builds
# that exist. Do NOT pin a single release here -- the previous version tested
# for exactly "24.04" and therefore produced a URL like
# wkhtmltox_0.12.5-1.resolute_amd64.deb on 26.04, which has never existed.
WKHTMLTOPDF_VERSION="0.12.6.1-3"
WKHTMLTOPDF_BASE="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}"
# Verified 2026-08-17: of the 0.12.6.1-3 assets, "jammy" is the only Ubuntu
# build still published (focal and the current codename both 404), so it is the
# single real fallback. Keep the running release first in case a newer build
# ever appears.
WKHTMLTOPDF_CODENAMES="$(lsb_release -c -s) jammy"

#--------------------------------------------------
# Update Server
#--------------------------------------------------
echo -e "\n---- Update Server ----"
# universe package is for Ubuntu 18.x
# sudo add-apt-repository universe
# libpng12-0 dependency for wkhtmltopdf for older Ubuntu versions
# sudo add-apt-repository "deb http://mirrors.kernel.org/ubuntu/ xenial main"
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y libpq-dev

#--------------------------------------------------
# Install PostgreSQL Server
#--------------------------------------------------
echo -e "\n---- Install PostgreSQL Server ----"
if [ "$INSTALL_POSTGRESQL_SIXTEEN" = "True" ]; then
    echo -e "\n---- Installing postgreSQL V16 due to the user it's choise ----"
    sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc|sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
    sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    sudo apt-get update -y
    sudo apt-get install -y postgresql-16
    if [ "$IS_ENTERPRISE" = "True" ]; then
      # Ensure PostgreSQL is running before pgvector setup (Ubuntu 24.04 uses systemd)
      sudo systemctl start postgresql || true
      # pgvector is only needed for Enterprise AI features
      sudo apt-get install -y postgresql-16-pgvector
      # Wait for PostgreSQL to become available
      until sudo -u postgres pg_isready >/dev/null 2>&1; do sleep 1; done
      # Create vector extension using a heredoc to avoid any quoting issues
      sudo -u postgres psql -v ON_ERROR_STOP=1 -d template1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SQL
    fi
else
    echo -e "\n---- Installing the default postgreSQL version based on Linux version ----"
    sudo apt-get install postgresql postgresql-server-dev-all -y
fi


echo -e "\n---- Creating the ODOO PostgreSQL User  ----"
sudo su - postgres -c "createuser -s $OE_USER" 2> /dev/null || true

#--------------------------------------------------
# Install Dependencies
#--------------------------------------------------
echo -e "\n--- Installing Python 3 + pip3 --"
sudo apt-get install -y python3 python3-pip
sudo apt-get install git python3-cffi build-essential wget python3-dev python3-venv python3-wheel libxslt-dev libzip-dev libldap2-dev libsasl2-dev python3-setuptools node-less libpng-dev libjpeg-dev gdebi -y


echo -e "\n---- Installing nodeJS NPM and rtlcss for LTR support ----"
sudo apt-get install nodejs npm -y
sudo npm install -g rtlcss

#--------------------------------------------------
# Install Wkhtmltopdf if needed
#--------------------------------------------------
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
  echo -e "\n---- Install wkhtmltopdf ----"
  _arch=$(dpkg --print-architecture)
  _wkhtml_ok="False"

  for _codename in $WKHTMLTOPDF_CODENAMES; do
    _url="${WKHTMLTOPDF_BASE}/wkhtmltox_${WKHTMLTOPDF_VERSION}.${_codename}_${_arch}.deb"
    echo "  trying ${_url}"
    if sudo wget -q "$_url" -O /tmp/wkhtmltox.deb; then
      # apt-get resolves the dependencies itself; gdebi is not installed on
      # every release and adds nothing here.
      if sudo apt-get install -y /tmp/wkhtmltox.deb; then
        _wkhtml_ok="True"
      fi
    fi
    sudo rm -f /tmp/wkhtmltox.deb
    [ "$_wkhtml_ok" = "True" ] && break
  done

  if [ "$_wkhtml_ok" != "True" ]; then
    echo "  no official build available, falling back to the distribution package"
    sudo apt-get install -y wkhtmltopdf && _wkhtml_ok="True"
  fi

  # Link only what actually exists. The previous version created these
  # unconditionally, so a failed download left dangling symlinks in /usr/bin
  # that made wkhtmltopdf look installed while every PDF report failed with
  # "You need Wkhtmltopdf to print a pdf version of the reports".
  for _bin in wkhtmltopdf wkhtmltoimage; do
    if [ -x "/usr/local/bin/${_bin}" ] && [ ! -e "/usr/bin/${_bin}" ]; then
      sudo ln -s "/usr/local/bin/${_bin}" "/usr/bin/${_bin}"
    fi
  done

  if [ "$_wkhtml_ok" = "True" ] && command -v wkhtmltopdf >/dev/null 2>&1; then
    echo "  installed: $(wkhtmltopdf --version 2>&1 | head -n1)"
  else
    echo "  WARNING: wkhtmltopdf could not be installed. Odoo will start, but"
    echo "           every PDF report (invoices included) will fail."
  fi
else
  echo "Wkhtmltopdf isn't installed due to the choice of the user!"
fi

echo -e "\n---- Create ODOO system user ----"
sudo adduser --system --quiet --shell=/bin/bash --home=$OE_HOME --gecos 'ODOO' --group $OE_USER
#The user should also be added to the sudo'ers group.
sudo adduser $OE_USER sudo

echo -e "\n---- Create Log directory ----"
sudo mkdir /var/log/$OE_USER
sudo chown $OE_USER:$OE_USER /var/log/$OE_USER

#--------------------------------------------------
# Install Dependencies of ODOO
#--------------------------------------------------
echo -e "\n--- Installing Python 3 + pip3 --"
# Path to the virtual environment
venv_path="$OE_HOME/venv"
#Create a new Python virtual environment for Odoo
sudo su $OE_USER -c "python3 -m venv $venv_path"


#--------------------------------------------------
# Install ODOO
#--------------------------------------------------
echo -e "\n==== Installing ODOO Server ===="
sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/odoo $OE_HOME_EXT/

# Activate the virtual environment using sudo
echo -e "\n---- Install python packages/requirements ----"
sudo -H -u "$OE_USER" bash -c "source $venv_path/bin/activate && pip3 install wheel phonenumbers && pip3 install -r $OE_HOME_EXT/requirements.txt && deactivate"

if [ $IS_ENTERPRISE = "True" ]; then
    # Odoo Enterprise install!
    sudo -H -u "$OE_USER" bash -c "source $venv_path/bin/activate && pip3 install psycopg2-binary pdfminer.six && deactivate"
    sudo su $OE_USER -c "mkdir $OE_HOME/enterprise"
    sudo su $OE_USER -c "mkdir $OE_HOME/enterprise/addons"

    GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    while [[ $GITHUB_RESPONSE == *"Authentication"* ]]; do
        echo "------------------------WARNING------------------------------"
        echo "Your authentication with Github has failed! Please try again."
        printf "In order to clone and install the Odoo enterprise version you \nneed to be an offical Odoo partner and you need access to\nhttp://github.com/odoo/enterprise.\n"
        echo "TIP: Press ctrl+c to stop this script."
        echo "-------------------------------------------------------------"
        echo " "
        GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    done

    echo -e "\n---- Added Enterprise code under $OE_HOME/enterprise/addons ----"
    echo -e "\n---- Installing Enterprise specific libraries ----"
    sudo -H -u "$OE_USER" bash -c "source $venv_path/bin/activate && pip3 install num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL && deactivate"
    sudo npm install -g less
    sudo npm install -g less-plugin-clean-css
fi

if [ "$INSTALL_DESIGN_THEMES" = "True" ]; then
    echo -e "\n---- Installing Odoo design themes ----"
    # Public repo, so no credentials needed -- unlike odoo/enterprise above.
    # Roughly 300 MB even shallow, which is why it is optional.
    if [ -d "$OE_HOME/design-themes/.git" ]; then
        echo "  already present at $OE_HOME/design-themes, skipping"
    elif sudo git clone --depth 1 --branch $OE_VERSION \
            https://github.com/odoo/design-themes "$OE_HOME/design-themes"; then
        sudo chown -R $OE_USER:$OE_USER "$OE_HOME/design-themes"
        echo "  themes available: $(ls -1 "$OE_HOME/design-themes" | wc -l)"
    else
        echo "  WARNING: could not clone odoo/design-themes for branch $OE_VERSION."
        echo "           Continuing without them; the addons path will omit the directory."
        INSTALL_DESIGN_THEMES="False"
    fi
fi

echo -e "\n---- Create custom module directory ----"
sudo su $OE_USER -c "mkdir $OE_HOME/custom"
sudo su $OE_USER -c "mkdir $OE_HOME/custom/addons"

echo -e "\n---- Setting permissions on home folder ----"
sudo chown -R $OE_USER:$OE_USER $OE_HOME/*

echo -e "* Create server config file"


sudo touch /etc/${OE_CONFIG}.conf
echo -e "* Creating server config file"
sudo su root -c "printf '[options] \n; This is the password that allows database operations:\n' >> /etc/${OE_CONFIG}.conf"
if [ $GENERATE_RANDOM_PASSWORD = "True" ]; then
    echo -e "* Generating random admin password"
    OE_SUPERADMIN=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
fi
sudo su root -c "printf 'admin_passwd = ${OE_SUPERADMIN}\n' >> /etc/${OE_CONFIG}.conf"
if version_gt "$OE_VERSION" "11.0"; then
    sudo su root -c "printf 'http_port = ${OE_PORT}\n' >> /etc/${OE_CONFIG}.conf"
else
    sudo su root -c "printf 'xmlrpc_port = ${OE_PORT}\n' >> /etc/${OE_CONFIG}.conf"
fi

if version_gt "$OE_VERSION" "15.0"; then
    sudo su root -c "printf 'gevent_port = ${LONGPOLLING_PORT}\n' >> /etc/${OE_CONFIG}.conf"
else
    sudo su root -c "printf 'longpolling_port = ${LONGPOLLING_PORT}\n' >> /etc/${OE_CONFIG}.conf"
fi

sudo su root -c "printf 'logfile = /var/log/${OE_USER}/${OE_CONFIG}.log\n' >> /etc/${OE_CONFIG}.conf"

# Build the addons path once rather than duplicating it per branch. Note the
# enterprise branch previously omitted ${OE_HOME}/custom/addons entirely, so an
# enterprise install could not load any custom module -- it is included for
# both now.
ODOO_ADDONS_PATH="${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons"
if [ $IS_ENTERPRISE = "True" ]; then
    ODOO_ADDONS_PATH="${OE_HOME}/enterprise/addons,${ODOO_ADDONS_PATH}"
fi
if [ "$INSTALL_DESIGN_THEMES" = "True" ]; then
    ODOO_ADDONS_PATH="${ODOO_ADDONS_PATH},${OE_HOME}/design-themes"
fi
sudo su root -c "printf 'addons_path=${ODOO_ADDONS_PATH}\n' >> /etc/${OE_CONFIG}.conf"

# Multiprocessing. Odoo defaults to workers = 0, which is a single-threaded
# process: one slow request blocks every other user, and longpolling/websockets
# share that same process. Any production instance wants workers > 0.
# Odoo's documented rule is (cores * 2) + 1, but that is a CPU ceiling only.
# Cap it by RAM as well: budget ~1 GB per worker and reserve 4 GB for the OS
# and PostgreSQL, which usually shares the box. This errs high for busy
# instances -- pin OE_WORKERS to a number if you want to be conservative.
if [ "$OE_WORKERS" = "auto" ]; then
    _cores=$(nproc 2>/dev/null || echo 1)
    _ram_gb=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')
    _ram_gb=${_ram_gb:-2}
    _by_cpu=$(( _cores * 2 + 1 ))
    _by_ram=$(( _ram_gb > 5 ? _ram_gb - 4 : 1 ))
    OE_WORKERS=$(( _by_cpu < _by_ram ? _by_cpu : _by_ram ))
    echo "* Sizing workers: ${_cores} cores, ${_ram_gb}GB RAM -> workers = ${OE_WORKERS}"
fi
sudo su root -c "printf 'workers = ${OE_WORKERS}\n' >> /etc/${OE_CONFIG}.conf"

# Serve exactly one database and hide the database manager. Without this, the
# instance exposes /web/database/manager to the internet, where the master
# password is the only thing between a visitor and dropping or downloading
# every database on the server.
if [ "$LOCK_DATABASE" = "True" ] && [ -n "$OE_DB_NAME" ]; then
    sudo su root -c "printf 'db_name = ${OE_DB_NAME}\n' >> /etc/${OE_CONFIG}.conf"
    sudo su root -c "printf 'dbfilter = ^${OE_DB_NAME}\$\n' >> /etc/${OE_CONFIG}.conf"
    sudo su root -c "printf 'list_db = False\n' >> /etc/${OE_CONFIG}.conf"
fi

sudo chown $OE_USER:$OE_USER /etc/${OE_CONFIG}.conf
sudo chmod 640 /etc/${OE_CONFIG}.conf

echo -e "* Create startup file"
sudo su root -c "echo '#!/bin/sh' >> $OE_HOME_EXT/start.sh"
sudo su root -c "echo 'sudo -u $OE_USER $OE_HOME_EXT/odoo-bin --config=/etc/${OE_CONFIG}.conf' >> $OE_HOME_EXT/start.sh"
sudo chmod 755 $OE_HOME_EXT/start.sh

#--------------------------------------------------
# Adding ODOO as a deamon (initscript)
#--------------------------------------------------

echo -e "* Create init file"
# cat <<EOF > ~/$OE_CONFIG
# #!/bin/sh
# ### BEGIN INIT INFO
# # Provides: $OE_CONFIG
# # Required-Start: \$remote_fs \$syslog
# # Required-Stop: \$remote_fs \$syslog
# # Should-Start: \$network
# # Should-Stop: \$network
# # Default-Start: 2 3 4 5
# # Default-Stop: 0 1 6
# # Short-Description: Enterprise Business Applications
# # Description: ODOO Business Applications
# ### END INIT INFO
# PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
# DAEMON=$OE_HOME_EXT/odoo-bin
# NAME=$OE_CONFIG
# DESC=$OE_CONFIG
# # Specify the user name (Default: odoo).
# USER=$OE_USER
# # Specify an alternate config file (Default: /etc/openerp-server.conf).
# CONFIGFILE="/etc/${OE_CONFIG}.conf"
# # pidfile
# PIDFILE=/var/run/\${NAME}.pid
# # Additional options that are passed to the Daemon.
# DAEMON_OPTS="-c \$CONFIGFILE"
# [ -x \$DAEMON ] || exit 0
# [ -f \$CONFIGFILE ] || exit 0
# checkpid() {
# [ -f \$PIDFILE ] || return 1
# pid=\`cat \$PIDFILE\`
# [ -d /proc/\$pid ] && return 0
# return 1
# }
# case "\${1}" in
# start)
# echo -n "Starting \${DESC}: "
# start-stop-daemon --start --quiet --pidfile \$PIDFILE \
# --chuid \$USER --background --make-pidfile \
# --exec \$DAEMON -- \$DAEMON_OPTS
# echo "\${NAME}."
# ;;
# stop)
# echo -n "Stopping \${DESC}: "
# start-stop-daemon --stop --quiet --pidfile \$PIDFILE \
# --oknodo
# echo "\${NAME}."
# ;;
# restart|force-reload)
# echo -n "Restarting \${DESC}: "
# start-stop-daemon --stop --quiet --pidfile \$PIDFILE \
# --oknodo
# sleep 1
# start-stop-daemon --start --quiet --pidfile \$PIDFILE \
# --chuid \$USER --background --make-pidfile \
# --exec \$DAEMON -- \$DAEMON_OPTS
# echo "\${NAME}."
# ;;
# *)
# N=/etc/init.d/\$NAME
# echo "Usage: \$NAME {start|stop|restart|force-reload}" >&2
# exit 1
# ;;
# esac
# exit 0
# EOF

# echo -e "* Security Init File"
# sudo mv ~/$OE_CONFIG /etc/init.d/$OE_CONFIG
# sudo chmod 755 /etc/init.d/$OE_CONFIG
# sudo chown root: /etc/init.d/$OE_CONFIG

# echo -e "* Start ODOO on Startup"
# sudo update-rc.d $OE_CONFIG defaults
cat <<EOF > ~/$OE_USER.service
[Unit]
Description=$OE_USER
Requires=postgresql.service
After=network.target postgresql.service
[Service]
Type=simple
SyslogIdentifier=$OE_USER
PermissionsStartOnly=true
User=$OE_USER
Group=$OE_USER
ExecStart=$OE_HOME/venv/bin/python3 $OE_HOME/$OE_CONFIG/odoo-bin -c /etc/$OE_CONFIG.conf
StandardOutput=journal+console
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

sudo mv ~/$OE_USER.service /etc/systemd/system/$OE_USER.service

echo -e "* Start ODOO on Startup"
sudo systemctl daemon-reload
# enable odoo
sudo systemctl enable --now $OE_USER

#--------------------------------------------------
# Install Nginx if needed
#--------------------------------------------------
if [ $INSTALL_NGINX = "True" ]; then
  echo -e "\n---- Installing and setting up Nginx ----"
  sudo apt-get install -y nginx

  if version_gt "$OE_VERSION" "15.0"; then
    cat <<EOF > ~/odoo
upstream $OE_USER {
  server 127.0.0.1:$OE_PORT;
}
upstream $OE_USER-chat {
  server 127.0.0.1:$LONGPOLLING_PORT;
}
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  ''      close;
}

# # http -> https
server {
  listen 80;
  server_name $WEBSITE_NAME;

  # Odoo uploads (attachments, imports, backups) exceed nginx's 1M default.
  client_max_body_size 1000M;
  client_body_buffer_size 1M;     # avoid excessive disk buffering on medium uploads

  # A WebSocket is a long-lived idle connection: with nginx's 60s default
  # proxy_read_timeout it is dropped roughly every minute and the client
  # reconnects in a loop. These also cover slow report/import requests.
  proxy_read_timeout 720s;
  proxy_send_timeout 720s;
  proxy_connect_timeout 720s;
#   rewrite ^(.*) https://\$host\$1 permanent;
# }

# server {
#   listen 443 ssl;
#   server_name odoo.mycompany.com;
#   proxy_read_timeout 720s;
#   proxy_connect_timeout 720s;
#   proxy_send_timeout 720s;

#   # SSL parameters
#   ssl_certificate /etc/ssl/nginx/server.crt;
#   ssl_certificate_key /etc/ssl/nginx/server.key;
#   ssl_session_timeout 30m;
#   ssl_protocols TLSv1.2;
#   ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
#   ssl_prefer_server_ciphers off;

  # log
  access_log  /var/log/nginx/$OE_USER-access.log;
  error_log       /var/log/nginx/$OE_USER-error.log;

  # Redirect websocket requests to odoo gevent port
  location /websocket {
    proxy_pass http://$OE_USER-chat;
    # Required: nginx proxies to upstreams with HTTP/1.0 by default, and the
    # WebSocket Upgrade handshake only exists in HTTP/1.1. Without this the
    # upgrade is refused and Odoo's bus never connects -- chat, live
    # discussions and real-time notifications silently stop working.
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
    proxy_cookie_flags session_id samesite=lax secure;  # requires nginx 1.19.8
  }

  # Redirect requests to odoo backend server
  location / {
    # Add Headers for odoo proxy mode
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_redirect off;
    proxy_pass http://$OE_USER;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
    proxy_cookie_flags session_id samesite=lax secure;  # requires nginx 1.19.8
  }

  # common gzip
  gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
  gzip on;
}
EOF
  else
    cat <<EOF > ~/odoo
server {
  listen 80;

  # set proper server name after domain set
  server_name $WEBSITE_NAME;

  # Add Headers for odoo proxy mode
  proxy_set_header X-Forwarded-Host \$host;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_set_header X-Real-IP \$remote_addr;
  add_header X-Frame-Options "SAMEORIGIN";
  add_header X-XSS-Protection "1; mode=block";
  proxy_set_header X-Client-IP \$remote_addr;
  proxy_set_header HTTP_X_FORWARDED_HOST \$remote_addr;

  #   odoo    log files
  access_log  /var/log/nginx/$OE_USER-access.log;
  error_log       /var/log/nginx/$OE_USER-error.log;

  #   increase    proxy   buffer  size
  proxy_buffers   16  64k;
  proxy_buffer_size   128k;

  proxy_read_timeout 900s;
  proxy_connect_timeout 900s;
  proxy_send_timeout 900s;

  #   force   timeouts    if  the backend dies
  proxy_next_upstream error   timeout invalid_header  http_500    http_502
  http_503;

  types {
    text/less less;
    text/scss scss;
  }

  #   enable  data    compression
  gzip    on;
  gzip_min_length 1100;
  gzip_buffers    4   32k;
  gzip_types  text/css text/less text/plain text/xml application/xml application/json application/javascript application/pdf image/jpeg image/png;
  gzip_vary   on;
  client_header_buffer_size 4k;
  large_client_header_buffers 4 64k;
  client_max_body_size 0;

  location / {
    proxy_pass    http://127.0.0.1:$OE_PORT;
    # by default, do not forward anything
    proxy_redirect off;
  }

  location /longpolling {
    proxy_pass http://127.0.0.1:$LONGPOLLING_PORT;
  }

  location ~* .(js|css|png|jpg|jpeg|gif|ico)$ {
    expires 2d;
    proxy_pass http://127.0.0.1:$OE_PORT;
    add_header Cache-Control "public, no-transform";
  }

  # cache some static data in memory for 60mins.
  location ~ /[a-zA-Z0-9_-]*/static/ {
    proxy_cache_valid 200 302 60m;
    proxy_cache_valid 404      1m;
    proxy_buffering    on;
    expires 864000;
    proxy_pass    http://127.0.0.1:$OE_PORT;
  }
}
EOF
  fi

  sudo mv ~/odoo /etc/nginx/sites-available/$WEBSITE_PRIMARY
  sudo ln -sfn /etc/nginx/sites-available/$WEBSITE_PRIMARY /etc/nginx/sites-enabled/$WEBSITE_PRIMARY
  # -f: on a host that already carries another Odoo instance the default site
  # was removed by the first run, and a bare rm fails noisily for nothing.
  sudo rm -f /etc/nginx/sites-enabled/default

  if [ "$INSTALL_DEFAULT_DENY" = "True" ]; then
    # Without an explicit default_server, nginx promotes the FIRST-loaded vhost
    # to that role, so any hostname pointed at this box that no site claims is
    # served -- and possibly redirected -- by whichever site sorts first. On a
    # host with two instances that means one client's domain answering with
    # another client's site, and it is guaranteed to happen the moment a
    # wildcard DNS record (*.example.com) points here.
    sudo tee /etc/nginx/sites-available/000-default-deny > /dev/null <<'NGINXDENY'
# Catch-all for hostnames that no vhost claims. Reject rather than let a name
# fall through to an unrelated site. A new hostname works only once it is
# deliberately given a vhost.
server {
    listen 80 default_server;
    server_name _;
    # 444: close without a response; nothing legitimate arrives here.
    return 444;
}

server {
    listen 443 ssl default_server;
    server_name _;
    # nginx >= 1.19.4: refuse the handshake for unknown SNI instead of
    # presenting an unrelated domain's certificate.
    ssl_reject_handshake on;
}
NGINXDENY
    if nginx -v 2>&1 | grep -qE 'nginx/1\.(1[0-9]|[0-9])\.'; then
      # ssl_reject_handshake needs >= 1.19.4; drop the TLS half on older nginx
      # rather than fail the whole config test.
      sudo sed -i '/listen 443 ssl default_server;/,$d' /etc/nginx/sites-available/000-default-deny
      echo "  nginx too old for ssl_reject_handshake; installed the HTTP catch-all only"
    fi
    sudo ln -sfn /etc/nginx/sites-available/000-default-deny /etc/nginx/sites-enabled/000-default-deny
  fi

  sudo nginx -t && sudo service nginx reload
  sudo su root -c "printf 'proxy_mode = True\n' >> /etc/${OE_CONFIG}.conf"
  echo "Done! The Nginx server is up and running. Configuration can be found at /etc/nginx/sites-available/$WEBSITE_PRIMARY"
else
  echo "Nginx isn't installed due to choice of the user!"
fi

#--------------------------------------------------
# Enable ssl with certbot
#--------------------------------------------------

if [ $INSTALL_NGINX = "True" ] && [ $ENABLE_SSL = "True" ] && [ $ADMIN_EMAIL != "odoo@example.com" ]  && [ $WEBSITE_NAME != "_" ];then
  sudo apt-get update -y
  sudo apt-get install -y snapd
  sudo snap install core; snap refresh core
  sudo snap install --classic certbot
  sudo apt-get install python3-certbot-nginx -y
  # Report what actually happened. Certbot exits non-zero when the ACME
  # challenge fails -- typically because DNS does not point here yet, or points
  # here over A but not AAAA -- and announcing success regardless leaves the
  # site on plain HTTP while the log says it is secured.
  if sudo certbot --nginx $CERTBOT_DOMAINS --cert-name $WEBSITE_PRIMARY --noninteractive --agree-tos --email $ADMIN_EMAIL --redirect; then
    sudo service nginx reload
    echo "SSL/HTTPS is enabled!"
  else
    sudo service nginx reload
    echo "WARNING: certbot could not issue a certificate for $WEBSITE_NAME."
    echo "         The site is serving plain HTTP. Check that every A and AAAA"
    echo "         record for $WEBSITE_NAME resolves to this host, then re-run:"
    echo "           sudo certbot --nginx $CERTBOT_DOMAINS --cert-name $WEBSITE_PRIMARY --agree-tos --email $ADMIN_EMAIL --redirect"
  fi
else
  echo "SSL/HTTPS isn't enabled due to choice of the user or because of a misconfiguration!"
  if [ "$ADMIN_EMAIL" = "odoo@example.com" ]; then
      echo "Certbot does not support registering odoo@example.com. You should use real e-mail address."
  fi

  if [ "$WEBSITE_NAME" = "_" ]; then
      echo "Website name is set as _. Cannot obtain SSL Certificate for _. You should use real website address."
  fi
fi

# The service is a systemd unit named after $OE_USER and was already started
# by `systemctl enable --now` above. This used to run
# `/etc/init.d/$OE_CONFIG start`, a leftover from the SysV era (that init
# script is commented out further up), so it could only ever print
# "No such file or directory" -- alarming, and misleading, since the server was
# in fact already running.
echo -e "* Odoo service status"
sudo systemctl --no-pager --lines=0 status "$OE_USER" 2>/dev/null | head -n 3 || true
if ! sudo systemctl is-active --quiet "$OE_USER"; then
    echo "WARNING: $OE_USER.service is not running. Check: journalctl -u $OE_USER -n 50"
fi
echo "-----------------------------------------------------------"
echo "Done! The Odoo server is up and running. Specifications:"
echo "Port: $OE_PORT"
echo "User service: $OE_USER"
echo "Configuraton file location: /etc/${OE_CONFIG}.conf"
echo "Logfile location: /var/log/$OE_USER"
echo "User PostgreSQL: $OE_USER"
echo "Code location: $OE_HOME_EXT"
echo "Addons folder: $OE_HOME_EXT/addons/"
echo "Custom addons folder: $OE_HOME/custom/addons/"
echo "Password superadmin (database): $OE_SUPERADMIN"
# The unit is $OE_USER.service, not $OE_CONFIG -- see the systemd block above.
echo "Start Odoo service: sudo systemctl start $OE_USER"
echo "Stop Odoo service: sudo systemctl stop $OE_USER"
echo "Restart Odoo service: sudo systemctl restart $OE_USER"
if [ $INSTALL_NGINX = "True" ]; then
  echo "Nginx configuration file: /etc/nginx/sites-available/$WEBSITE_PRIMARY"
fi
echo "-----------------------------------------------------------"
