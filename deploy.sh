#!/bin/bash

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

export DEBIAN_FRONTEND=noninteractive

DIST=$(lsb_release -cs)
VERSION=17
DATABASE=lifeinformatica
USER=odoo$VERSION
MASTER_PASSWORD=T3mporal10
ODOO_CONFIG_FILE=odoo.conf

echo "---------------------------------------------------------------------------"
echo "Installing specials packages..."
echo "---------------------------------------------------------------------------"
apt-get -y update ; apt-get -y upgrade
apt install -y python3-pip
apt install -y git python3-venv python3-dev libxml2-dev libxslt1-dev zlib1g-dev libsasl2-dev libldap2-dev build-essential libssl-dev libffi-dev libmysqlclient-dev libjpeg-dev libpq-dev libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev
apt install -y npm
#ln -s /usr/bin/nodejs /usr/bin/node
npm install -g less less-plugin-clean-css
apt install -y node-less

echo "---------------------------------------------------------------------------"
echo "Installing PostgreSQL..."
echo "---------------------------------------------------------------------------"
apt install postgresql -y

# run psql with root privileges for the postgres user
sudo -u postgres psql<<EOF
       CREATE USER $USER WITH PASSWORD '$MASTER_PASSWORD';
        ALTER USER $USER WITH SUPERUSER CREATEDB;
       \q
EOF

echo "---------------------------------------------------------------------------"
echo "Installing Wk html to pdf..."
echo "---------------------------------------------------------------------------"
apt install -y xfonts-base xfonts-75dpi
wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb
apt --fix-broken install -y


echo "---------------------------------------------------------------------------"
echo "Installing Odoo User..."
echo "---------------------------------------------------------------------------"
useradd -m -d /home/odoo -U -r -s /bin/bash $USER

echo "---------------------------------------------------------------------------"
echo "Installing Odoo..."
echo "---------------------------------------------------------------------------"
sudo -u $USER -s /bin/bash <<EOF
        cd /home/odoo
        rm -rf /home/odoo/*
        git clone --branch=$VERSION.0 --depth=1 --single-branch https://www.github.com/odoo/odoo
EOF
python3 -m venv /home/odoo/$USER-venv
source /home/odoo/$USER-venv/bin/activate
pip3 install wheel unidecode astor schwifty==2024.4.0 xmlsig cachetools PyYAML
# The versions of the requirements file packages have been modified so that they are compatible with Python 3.10 and Jammy
if [ "$DIST" = "jammy" ]; then
        sed -E -i "s/^(gevent==)[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,2}(.*python_version\s==\s'3.10'.*$)/\121.12.00\2/g" /home/odoo/odoo/requirements.txt
fi
pip3 install -r /home/odoo/odoo/requirements.txt
deactivate

echo "---------------------------------------------------------------------------"
echo "Setup Configuration File..."
echo "---------------------------------------------------------------------------"

if [ -d /tmp/dsbackup-infra-odoo-* ]; then
    rm -rf /tmp/dsbackup-infra-odoo-*
fi

if [ -d /tmp/infra ]; then
    rm -rf /tmp/infra
fi

# curl -u oscarherraiz:ATBBhmR9RnPQxeHYxNJyGpnNHPUp6231D46A https://bitbucket.org/dsbackup/infra-odoo/get/master.tar.gz -o /tmp/config.tar.gz
# tar -xzf /tmp/config.tar.gz -C /tmp/
mv -f /tmp/dsbackup-infra-odoo-* /tmp/infra
cp /tmp/infra/${ODOO_CONFIG_FILE} /etc

sed -E -i "s/^(admin_passwd[[:blank:]]*=[[:blank:]]*)\"MASTER_PASSWORD\"$/\1${MASTER_PASSWORD}/g" /etc/${ODOO_CONFIG_FILE}
sed -E -i "s/^(db_user[[:blank:]]*=[[:blank:]]*)\"USERNAME\"$/\1${USER}/g" /etc/${ODOO_CONFIG_FILE}
sed -E -i "s/^(db_name[[:blank:]]*=[[:blank:]]*)\"DATABASE\"$/\1${DATABASE}/g" /etc/${ODOO_CONFIG_FILE}

sudo chown $USER: /etc/${ODOO_CONFIG_FILE}
sudo chmod 640 /etc/${ODOO_CONFIG_FILE}

echo "---------------------------------------------------------------------------"
echo "Download repositories..."
echo "---------------------------------------------------------------------------"
POPULATE_PATH=/home/odoo
rm -rf /${POPULATE_PATH}/custom_addons
mkdir -p ${POPULATE_PATH}/custom_addons && cd ${POPULATE_PATH}/custom_addons

for repo in $(cat /tmp/infra/repositories); do
    git clone -b $VERSION.0 $repo
    REPO_NAME=$(echo $repo | awk -F'/' '{print $NF}' | cut -d '.' -f1)
    sed -E -i "s/([[:blank:]]*\/home\/odoo\/custom_addons.*)/\1,\/home\/odoo\/custom_addons\/$REPO_NAME/g" /etc/$ODOO_CONFIG_FILE
done

echo "---------------------------------------------------------------------------"
echo "Activating modules..."
echo "---------------------------------------------------------------------------"
sudo -u $USER -s /bin/bash <<EOF
        source /home/odoo/$USER-venv/bin/activate
        for row in \$(cat /tmp/infra/modules); do
                module=\$(echo \$row | cut -d ';' -f 2)
                if [[ \$row == \#* ]]; then
                        echo "Skip commented line \$module!"
                else
                        /home/odoo/odoo/odoo-bin -c /etc/odoo.conf -d $DATABASE --init \$module --stop-after-init --without-demo=all
                        echo "Module \$module activation succesful!"
                fi
        done
        /home/odoo/odoo/odoo-bin -c /etc/odoo.conf -d $DATABASE --update base --stop-after-init --without-demo=all
EOF

echo "---------------------------------------------------------------------------"
echo "Setup Loggin..."
echo "---------------------------------------------------------------------------"

mkdir -p /var/log/odoo
chown $USER: /var/log/odoo

echo "---------------------------------------------------------------------------"
echo "Creating Service File..."
echo "---------------------------------------------------------------------------"

cp /tmp/infra/odoo-server.service /etc/systemd/system/
sed -E -i "s/^(SyslogIdentifier=)\"USER\"$/\1${USER}/g" /etc/systemd/system/odoo-server.service
sed -E -i "s/^(User=)\"USER\"$/\1${USER}/g" /etc/systemd/system/odoo-server.service
sed -E -i "s/^(Group=)\"USER\"$/\1${USER}/g" /etc/systemd/system/odoo-server.service
sed -E -i "s/^(ExecStart=\/home\/odoo\/)\"USER\"(.*$)/\1${USER}\2/g" /etc/systemd/system/odoo-server.service

sudo chmod 755 /etc/systemd/system/odoo-server.service
sudo chown root: /etc/systemd/system/odoo-server.service

systemctl enable odoo-server.service

echo "---------------------------------------------------------------------------"
echo "Clean up..."
echo "---------------------------------------------------------------------------"
if [ -f /tmp/config.tar.gz ]; then
    rm -f /tmp/config.tar.gz
fi
if [ -d /tmp/infra ]; then
    rm -rf /tmp/infra
fi

apt-get -qq purge expect > /dev/null


echo "---------------------------------------------------------------------------"
echo "Restarting services..."
echo "---------------------------------------------------------------------------"
systemctl start odoo-server.service
systemctl status odoo-server.service



