#!/usr/bin/bash


# install_otrs.sh - Install OTRS and MariaDB

# Site:       https://www.linkedin.com/in/mateusrissi/
# Author:     Mateus Rissi

#  This script will install OTRS and MariaDB, also will do the basic configuration 
#  of OTRS and the database that OTRS will use.
#
#  Examples:
#      # ./install_otrs.sh

# History:
#   v1.0.0 22/04/2020, Mateus:
#       - Start
#       - Funcionalities
#   v1.1.0 08/05/2020, Mateus:
#       - Fixed OTRS Daemon not runnning

# Tested on:
#   bash 4.2.46
# --------------------------------------------------------------------------- #


# VARIABLES
otrs_version="6.0.26"
mysql_conf_file="/etc/my.cnf"
mysql_dump_file="/etc/my.cnf.d/mysql-clients.cnf"
random_passwd="$(date +%s | sha256sum | base64 | head -c 32)"
sec_mysql_temp_file="/tmp/secure_mysql_temp_file.txt"
install_otrs_log_file="/tmp/install_otrs.log"
sys_id="$(date +%s | sha256sum | base64 | head -c 2)"

tasks_to_execute="
    disable_SELinux
    install_dependencies
    modify_mysql_config_file
    modify_mysql_dump
    start_mariaDB
    secure_mysql
    install_otrs
    install_otrs_modules
    set_otrs_permissions
    enable_mariaDB
    configure_firewall
    create_otrs_database
    config_web
    start_otrs
    enable_apache
    set_otrs_password
"

read -r -d '' info_to_show <<EOF
====================================================================
                    SAVE THIS PASSWORD!!!

            These passwords will not be shown again.

        MYSQL root@localhost: $random_passwd
        MYSQL otrs@localhost: $random_passwd

            Login: root@localhost
            Password: $random_passwd
====================================================================
EOF

red="\033[31;1m"
green="\033[32;1m"
no_color="\033[0m"


# FUNCTIONS
disable_SELinux() {
    setenforce permissive
    sed -i s/enforcing/permissive/g /etc/sysconfig/selinux
}

install_dependencies() {
    yum check-update

    yum -y install \
        epel-release \
        mariadb-server \
        mariadb
}

modify_mysql_config_file() {
    sed -i s/"\[mysqld\]"/"\[mysqld\]\nmax_allowed_packet=64M\nquery_cache_size=32M\ninnodb_log_file_size=256M"/g $mysql_conf_file
}

modify_mysql_dump() {
    sed -i s/"\[mysqldump\]"/"\[mysqldump\]\nmax_allowed_packet=64M\n"/g $mysql_dump_file
}

start_mariaDB() {
    systemctl start mariadb
}

install_otrs() {
    yum check-update
    curl -L http://ftp.otrs.org/pub/otrs/RPMS/rhel/7/otrs-${otrs_version}-01.noarch.rpm -o "/opt/otrs.rpm" -s
    yum -y install "/opt/otrs.rpm" || yum -y install "/opt/otrs.rpm"
    rm -f "/opt/otrs.rpm"
    systemctl restart httpd
}

install_otrs_modules() {
    yum check-update

    yum -y install \
        "perl(Crypt::Eksblowfish::Bcrypt)" \
        "perl(JSON::XS)" \
        "perl(Mail::IMAPClient)" \
        "perl(Authen::NTLM)" \
        "perl(ModPerl::Util)" \
        "perl(Text::CSV_XS)" \
        "perl(YAML::XS)"

    yum -y install mod_ssl
}

set_otrs_permissions() {
    /opt/otrs/bin/otrs.SetPermissions.pl
}

secure_mysql() {
    cat <<- EOF > $sec_mysql_temp_file
        UPDATE mysql.user SET Password=PASSWORD('${random_passwd}') WHERE User='root';
        DELETE FROM mysql.user WHERE User='';
        DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
        DROP DATABASE IF EXISTS test;
        DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
        FLUSH PRIVILEGES;
EOF

    mysql -sfu root < $sec_mysql_temp_file

    rm -f $sec_mysql_temp_file
}

enable_mariaDB() {
    systemctl enable mariadb.service
    systemctl restart mariadb.service
}

configure_firewall() {
    systemctl start firewalld
    firewall-cmd --permanent --zone=public --add-port=80/tcp
    firewall-cmd --reload
}

create_otrs_database() {
    mysql -u root -p$random_passwd -e "create database otrs character set utf8 collate utf8_bin;"
    mysql -u root -p$random_passwd -e "create user otrs@localhost identified by '"${random_passwd}"';"
    mysql -u root -p$random_passwd -e "grant all privileges on otrs.* to otrs@localhost;"
    mysql -u root -p$random_passwd -e "flush privileges;"
}

config_web() {
    curl -d action="/otrs/installer.pl" -d Action="Installer" -d Subaction="License" -d submit="Submit" http://localhost/otrs/installer.pl
    curl -d action="/otrs/installer.pl" -d Subaction="Start" -d submit="Aceite licença e continue" http://localhost/otrs/installer.pl
    curl -d action="/otrs/installer.pl" -d Action="Installer" -d Subaction="DB" -d DBType="mysql" -d DBInstallType="UseDB" -d submit="FormDBSubmit" http://localhost/otrs/installer.pl 
    curl -d action="/otrs/installer.pl" -d Action="Installer" -d Subaction="DBCreate" -d DBType="mysql" -d InstallType="UseDB" -d DBUser="otrs" -d DBPassword="${random_passwd}" -d DBHost="127.0.0.1" -d DBName="otrs" -d button="ButtonCheckDB" -d submit="FormDBSubmit" http://localhost/otrs/installer.pl
    curl -d action="/otrs/installer.pl" -d Action="Installer" -d Subaction="System" -d submit="Submit" http://localhost/otrs/installer.pl
    curl -d action="/otrs/installer.pl" -d Action="Installer" -d Subaction="ConfigureMail" -d SystemID="${sys_id}" -d FQDN="localhost.localdomain" -d AdminEmail="support@yourhost.example.com" -d Organization="Suntech" -d LogModule="Kernel::System::Log::SysLog" DefaultLanguage="pt_BR" -d CheckMXRecord="0" -d submit="Submit" http://localhost/otrs/installer.pl
    curl -d action="/otrs/installer.pl" -d Action="Installer" -d Subaction="Finish" -d Skip="0" -d button="ButtonSkipMail" http://localhost/otrs/installer.pl
}

start_otrs() {
    su - otrs -c '/opt/otrs/bin/otrs.Daemon.pl start'
    su - otrs -c '/opt/otrs/bin/Cron.sh start'
}

enable_apache() {
    systemctl enable httpd
    systemctl restart httpd
}

set_otrs_password() {
    su - otrs -c "/opt/otrs/bin/otrs.Console.pl Admin::User::SetPassword root@localhost $random_passwd"
}


# EXEC
for task in $tasks_to_execute; do

    echo -ne "Running ${task}... "

    $task >> $install_otrs_log_file 2>&1

    if [ $? -eq 0 ]; then
        echo -e "[${green}done${no_color}]\n"
    else
        echo -e "[${red}failed${no_color}]\n"
    fi
done

echo "$info_to_show"
