#!/bin/bash
# ©2023 JFTF
# JFTF development environment deployment script
# Prerequisites
# Ubuntu 22.04+
# Version 1.0

PARENT_DIR="$(cd .. && dirname "$(pwd)")"
PYTHON3_PACK_NAME="python3"
APT_PACKAGES="python3-venv python3-dev python3-pip mariadb-server libmariadb-dev-compat libmariadb-dev libssl-dev memcached libmemcached-tools rsyslog ksystemlog rabbitmq-server"
DATABASE_NAME="jftf_cmdb"
MOCK_DATABASE_NAME="test_jftf_cmdb"
DATABASE_USER="jftf"
DATABASE_PASSWORD="jftf_development"
DATABASE_TIMEZONE="Europe/Bucharest"
export DJANGO_SUPERUSER_USERNAME="jftf_dev"
DJANGO_SUPERUSER_EMAIL="jftf_dev@jftf.com"
export DJANGO_SUPERUSER_PASSWORD="jftf_dev"
RABBITMQ_USER="jftf"
RABBITMQ_PASSWORD="jftf_development"

if [[ $EUID -eq 0 ]]; then
  echo "This script cannot be executed as root. Please run it without root privileges."
  exit 1
fi

function install_apt_package() {
  echo "Checking installation of $1"
  if [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -c "ok installed")" -eq 0 ]; then
    sudo apt-get install "$1" -y
  else
    echo "Package $1 already installed on the system!"
  fi
}

function generate_python_venv() {
  echo "Generating Python virtual environment"
  VENV_DIR="$PARENT_DIR/.venv"
  install_apt_package $PYTHON3_PACK_NAME
  echo "Checking for Python venv existence"
  if [ -d "$VENV_DIR" ]; then
    echo "Found Python venv, skipping generation step!"
  else
    echo "No Python venv found, generating..."
    python3 -m venv "$VENV_DIR"
  fi
  echo "Activating Python venv"
  if source "$VENV_DIR/bin/activate"; then
    echo "Python venv activated successfully!"
    pip3 list
  else
    echo "Python venv failed to activate!"
    exit 1
  fi
}

function install_pip_dependencies() {
  echo "Resolving pip dependencies from requirements.txt"
  PIP_REQ_TXT="$PARENT_DIR/requirements.txt"
  if [ -f "$PIP_REQ_TXT" ]; then
    if pip3 install -r "$PIP_REQ_TXT"; then
      echo "Installed Python packages successfully!"
      pip3 list
    else
      echo "Failed to install Python packages, aborting!"
      exit 1
    fi
  else
    echo "Requirements.txt not found, aborting!"
    exit 1
  fi
}

function install_apt_dependencies() {
  echo "Installing required apt packages"
  for PACKAGE in $APT_PACKAGES; do
    install_apt_package "$PACKAGE"
  done
}

function configure_database() {
  echo "Configuring MariaDB development database and development user"
  sudo mariadb -e "CREATE OR REPLACE USER $DATABASE_USER@localhost IDENTIFIED BY '$DATABASE_PASSWORD';"
  if [ $? ]; then
    echo "JFTF development user created successfully!"
  else
    echo "Failed to create JFTF development user!"
    exit 1
  fi
  sudo mariadb -e "DROP DATABASE IF EXISTS $DATABASE_NAME;"
  sudo mariadb -e "CREATE OR REPLACE DATABASE $DATABASE_NAME;"
  if [ $? ]; then
    echo "JFTF development database created successfully!"
  else
    echo "Failed to create JFTF development database!"
    exit 1
  fi
  sudo mariadb -e "GRANT ALL ON $DATABASE_NAME.* TO $DATABASE_USER@localhost IDENTIFIED BY '$DATABASE_PASSWORD' WITH GRANT OPTION;"
  sudo mariadb -e "GRANT ALL ON $MOCK_DATABASE_NAME.* TO $DATABASE_USER@localhost IDENTIFIED BY '$DATABASE_PASSWORD' WITH GRANT OPTION;"
  if [ $? ]; then
    echo "JFTF development user granted development database permissions!"
  else
    echo "Failed to grant JFTF development user development database permissions!"
    exit 1
  fi
  sudo mariadb -e "SET GLOBAL time_zone = '$DATABASE_TIMEZONE';"
  if [[ $(sudo mariadb -B -N -e "SELECT @@global.time_zone='$DATABASE_TIMEZONE';") == "1" ]]; then
    echo "Global time zone is set to $DATABASE_TIMEZONE."
  else
    echo "Global time zone is not set to $DATABASE_TIMEZONE. Exiting..."
    exit 1
  fi
  sudo mariadb -e "FLUSH PRIVILEGES;"
}

function configure_rsyslog_remote_logging() {
  echo "Reconfiguring rsyslog daemon configuration file to allow remote logging"
  if [ ! -f /etc/rsyslog.conf ]; then
    echo "rsyslog.conf not found"
    exit 1
  fi
  sed -i 's/#module(load="imudp")/module(load="imudp")/' /etc/rsyslog.conf
  sed -i 's/#input(type="imudp" port="514")/input(type="imudp" port="514")/' /etc/rsyslog.conf

  # shellcheck disable=SC2016
  if ! grep -q '$AllowedSender UDP, 127.0.0.1' /etc/rsyslog.conf; then
    # shellcheck disable=SC2016
    echo '$AllowedSender UDP, 127.0.0.1' >>/etc/rsyslog.conf
  fi

  sudo systemctl restart rsyslog.service
  echo "Rsyslog daemon configuration successful!"
}

function apply_migrations() {
  echo "Applying Django migrations"
  MANAGE_PY_PATH="$PARENT_DIR/jftf_core/manage.py"
  if [ -f "$MANAGE_PY_PATH" ]; then
    if [ "$(python3 "$MANAGE_PY_PATH" migrate)" ]; then
      echo "Migration applied successfully!"
    else
      echo "Failed to apply migrations, aborting!"
      exit 1
    fi
  else
    echo "manage.py not found, aborting!"
    exit 1
  fi
}

function init_legacy_jftf_cmdb_db_views() {
  cd legacy_dbdriver || exit 1
  sudo ./db_views_init.sh $DATABASE_PASSWORD localhost
  cd .. || exit
}

function create_superuser() {
  echo "Creating Django superuser"
  python3 "$MANAGE_PY_PATH" createsuperuser --noinput --email "$DJANGO_SUPERUSER_EMAIL"
}

function enable_rabbitmq() {
  echo "Enabling and starting RabbitMQ service"

  # Enable RabbitMQ service
  sudo systemctl enable rabbitmq-server

  # Start RabbitMQ service
  sudo systemctl start rabbitmq-server

  # Check RabbitMQ service status
  sudo systemctl status rabbitmq-server --no-pager
}

function configure_rabbitmq_user() {
  echo "Configuring RabbitMQ JFTF administrator user"

  sudo rabbitmqctl add_user $RABBITMQ_USER $RABBITMQ_PASSWORD
  sudo rabbitmqctl set_user_tags $RABBITMQ_USER administrator
  sudo rabbitmqctl set_permissions -p / jftf ".*" ".*" ".*"
}

echo
echo "JFTF development environment deployment script"
echo
echo "WARNING!!!"
echo "This script will drop and reset the JFTF database! Continue at your own RISK!!!"
echo "Script only to be used for development/testing purposes, not for production deployment!"
echo

while true; do
  read -r -p 'Do you want to start the setup process? Y(y)/N(n) ' choice
  case "$choice" in
  n | N)
    exit 0
    break
    ;;
  y | Y)
    echo
    install_apt_dependencies
    echo
    generate_python_venv
    echo
    install_pip_dependencies
    echo
    configure_database
    echo
    apply_migrations
    echo
    init_legacy_jftf_cmdb_db_views
    echo
    create_superuser
    echo
    configure_rsyslog_remote_logging
    echo
    enable_rabbitmq
    configure_rabbitmq_user
    echo
    break
    ;;
  *) echo 'Response not valid' ;;
  esac
done

echo
echo "JFTF development deployment completed successfully!"
