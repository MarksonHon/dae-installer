#!/bin/bash

set -e

## Color
if command -v tput > /dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    RESET=$(tput sgr0)
fi

## Check root
if [[ $EUID -ne 0 ]]; then
    echo "${RED}error: This script must be run as root!${RESET}"
    exit 1
fi

## Check curl, unzip, jq
for tool_need in curl unzip jq; do
    if ! command -v $tool_need > /dev/null 2>&1; then
        if command -v apt > /dev/null 2>&1; then
        apt update; apt install $tool_need -y
        elif command -v dnf > /dev/null 2>&1; then
        dnf install $tool_need -y
        elif command -v yum > /dev/null  2>&1; then
        yum install $tool_need -y
        elif command -v zypper > /dev/null 2>&1; then
        zypper install --non-interactive $tool_need
        elif command -v pacman > /dev/null 2>&1; then
        pacman -S $tool_need --noconfirm
        else
        echo "$tool_need not installed, stop installation, please install $tool_need and try again!"
        we_should_exit=1
        fi
    fi
done


install_systemd_service() {
    echo "${GREEN}Installing systemd service...${RESET}"
    echo '[Unit]
Description=dae Service
Documentation=https://github.com/daeuniverse/dae
After=network-online.target docker.service systemd-sysctl.service

[Service]
Type=notify
User=root
LimitNPROC=512
LimitNOFILE=1048576
ExecStartPre=/usr/local/bin/dae validate -c /usr/local/etc/dae/config.dae
ExecStart=/usr/local/bin/dae run --disable-timestamp -c /usr/local/etc/dae/config.dae
ExecReload=/usr/bin/local/dae reload $MAINPID
Restart=on-abnormal

[Install]
WantedBy=multi-user.target' > /etc/systemd/system/dae.service
    systemctl daemon-reload
    echo "${GREEN}Systemd service installed,${RESET}"
    echo "${GREEN}you can start dae by running:${RESET}"
    echo "${GREEN}systemctl start dae${RESET}"
    echo "${GREEN}if you want to start dae at system boot:${RESET}"
    echo "${GREEN}systemctl enable dae${RESET}"
}

install_openrc_service(){
    echo "${GREEN}Installing OpenRC service...${RESET}"
    echo '#!/sbin/openrc-run
description="dae Service"
command="/usr/local/bin/dae"
command_args="run -c /usr/local/etc/dae/config.dae"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
rc_ulimit="-n 30000"
rc_cgroup_cleanup="yes"

depend() {
    after docker net
    use net
}

start_pre() {
   if [ ! -d "/tmp/dae/" ]; then 
     mkdir "/tmp/dae" 
   fi
   if [ ! -d "/var/log/dae/" ]; then
   ln -s "/tmp/dae/" "/var/log/"
   fi
   if ! /usr/local/bin/dae validate -c /usr/local/etc/dae/config.dae; then
      eerror "dae config file /usr/local/etc/dae/config.dae is invalid, exiting"
      return 1
   fi
}

reload() {
	ebegin "Reloading $RC_SVCNAME"
	/usr/bin/local/dae reload $(cat "/run/${RC_SVCNAME}.pid")
	eend $?
}' > /etc/init.d/dae
    chmod +x /etc/init.d/dae
    rc-update add dae default
    echo "${GREEN}OpenRC service installed,${RESET}"
    echo "${GREEN}you can start dae by running:${RESET}"
    echo "${GREEN}rc-service dae start${RESET}"
    echo "${GREEN}if you want to start dae at system boot:${RESET}"
    echo "${GREEN}rc-update add dae default${RESET}"
}

check_version(){
    if ! command -v /usr/local/bin/dae > /dev/null 2>&1; then
    current_version=0
    else
    current_version=$(/usr/local/bin/dae --version | awk '{print $3}')
    fi
    if ! curl -s 'https://api.github.com/repos/daeuniverse/dae/releases/latest' -o /tmp/dae.json; then
        echo "${RED}error: Failed to get the latest version of dae!${RESET}"
        echo "${RED}Please check your network and try again.${RESET}"
        we_should_exit=1
    else
        latest_version=$(jq -r '.tag_name' /tmp/dae.json)
        rm -f /tmp/dae.json
    fi
}

check_arch() {
if [[ $(uname) == 'Linux' ]]; then
case "$(uname -m)" in
      'i386' | 'i686')
        MACHINE='x86_32'
        ;;
      'amd64' | 'x86_64')
        MACHINE='x86_64'
        ;;
      'armv5tel')
        MACHINE='armv5'
        ;;
      'armv6l')
        MACHINE='armv6'
        grep Features /proc/cpuinfo | grep -qw 'vfp' || MACHINE='arm32-v5'
        ;;
      'armv7' | 'armv7l')
        MACHINE='armv7'
        grep Features /proc/cpuinfo | grep -qw 'vfp' || MACHINE='arm32-v5'
        ;;
      'armv8' | 'aarch64')
        MACHINE='arm64'
        ;;
      'mips')
        MACHINE='mips32'
        ;;
      'mipsle')
        MACHINE='mips32le'
        ;;
      'mips64')
        MACHINE='mips64'
        ;;
      'mips64le')
        MACHINE='mips64le'
        ;;
      'riscv64')
        MACHINE='riscv64'
        ;;
      *)
        echo "${RED}error: The architecture is not supported.${RESET}"
        exit 1
        ;;
    esac
else
    echo "${RED}error: The operating system is not supported.${RESET}"
    exit 1
fi
}

update_geoip() {
    if [ ! -d /usr/local/share/dae ]; then
        mkdir -p /usr/local/share/dae
    fi
    geoip_url="https://github.com/v2rayA/dist-v2ray-rules-dat/raw/master/geoip.dat"
    echo "${GREEN}Downloading GeoIP database...${RESET}"
    echo "${GREEN}Downloading from: $geoip_url${RESET}"
    if ! curl -LO $geoip_url --progress-bar; then
        echo "${RED}error: Failed to download GeoIP database!${RESET}"
        echo "${RED}Please check your network and try again.${RESET}"
        exit 1
    fi
    if ! curl -sLO $geoip_url.sha256sum; then
        echo "${RED}error: Failed to download the checksum file of GeoIP database!${RESET}"
        echo "${RED}Please check your network and try again.${RESET}"
        rm -f geoip.dat
        exit 1
    fi
    geoip_local_sha256=$(sha256sum geoip.dat)
    geoip_remote_sha256=$(cat geoip.dat.sha256sum)
    if [ "$geoip_local_sha256" != "$geoip_remote_sha256" ]; then
        echo "${RED}error: The checksum of the downloaded GeoIP database does not match!${RESET}"
        echo "${RED}Local SHA256: $geoip_local_sha256${RESET}"
        echo "${RED}Remote SHA256: $geoip_remote_sha256${RESET}"
        echo "${RED}Please check your network and try again.${RESET}"
        rm -f geoip.dat
        exit 1
    fi
    mv geoip.dat /usr/local/share/dae/
    rm -f geoip.dat.sha256sum
    echo "${GREEN}GeoIP database have been updated.${RESET}"
}

update_geosite() {
    if [ ! -d /usr/local/share/dae ]; then
        mkdir -p /usr/local/share/dae
    fi
    geosite_url="https://github.com/v2rayA/dist-v2ray-rules-dat/raw/master/geosite.dat"
    echo "${GREEN}Downloading GeoSite database...${RESET}"
    echo "${GREEN}Downloading from: $geosite_url${RESET}"
    if ! curl -LO $geosite_url --progress-bar; then
        echo "${RED}error: Failed to download GeoSite database!${RESET}"
        echo "${RED}Please check your network and try again.${RESET}"
        exit 1
    fi
    if ! curl -sLO $geosite_url.sha256sum; then
        echo "${RED}error: Failed to download the checksum file of GeoSite database!${RESET}"
        echo "${RED}Please check your network and try again.${RESET}"
        rm -f geosite.dat
        exit 1
    fi
    geosite_local_sha256=$(sha256sum geosite.dat)
    geosite_remote_sha256=$(cat geosite.dat.sha256sum)
    if [ "$geoip_local_sha256" != "$geoip_remote_sha256" ]; then
        echo "${RED}error: The checksum of the downloaded GeoIP database does not match!${RESET}"
        echo "${RED}Local SHA256: $geosite_local_sha256${RESET}"
        echo "${RED}Remote SHA256: $geosite_remote_sha256${RESET}"
        echo "${RED}Please check your network and try again.${RESET}"
        rm -f geosite.dat geosite.dat.sha256sum
        exit 1
    fi
    mv geosite.dat /usr/local/share/dae/
    rm -f geosite.dat.sha256sum
    echo "${GREEN}GeoSite database have been updated.${RESET}"
}

stop_dae(){
    if [ -f /etc/systemd/system/dae.service ] && [ -f /run/dae.pid ] && [ -n "$(cat /run/dae.pid)" ]; then
        echo "${GREEN}Stopping dae...${RESET}"
        systemctl stop dae
        dae_stopped=1
        echo "${GREEN}Stopped dae${RESET}"
    fi
    if [ -f /etc/init.d/dae ] && [ -f /run/dae.pid ] && [ -n "$(cat /run/dae.pid)" ]; then
        echo "${GREEN}Stopping dae...${RESET}"
        /etc/init.d/dae stop
        dae_stopped=1
        echo "${GREEN}Stopped dae${RESET}"
    fi
}

start_dae(){
    if [ -f /etc/systemd/system/dae.service ] && [ $dae_stopped == 1 ]; then
        echo "${GREEN}Starting dae...${RESET}"
        systemctl start dae
        echo "${GREEN}Started dae${RESET}"
    fi
    if [ -f /etc/init.d/dae ] && [ $dae_stopped == 1 ]; then
        echo "${GREEN}Starting dae...${RESET}"
        /etc/init.d/dae start
        echo "${GREEN}Started dae${RESET}"
    fi
}

install_dae() {
    download_url=https://github.com/daeuniverse/dae/releases/download/$latest_version/dae-linux-$MACHINE.zip
    echo "${GREEN}Downloading dae...${RESET}"
    echo "${GREEN}Downloading from: $download_url${RESET}"
    if ! curl -LO $download_url --progress-bar; then
        echo "${RED}error: Failed to download dae!${RESET}"
        echo "${RED}Please check your network and try again.${RESET}"
        exit 1
    fi
    local_sha256=$(sha256sum dae-linux-$MACHINE.zip | awk -F ' ' '{print $1}')
    if [ -z "$local_sha256" ]; then
        echo "${RED}error: Failed to get the checksum of the downloaded file!${RESET}"
        echo "${RED}Please check your network and try again.${RESET}"
        rm -f dae-linux-$MACHINE.zip
        exit 1
    fi
    if ! curl -sL $download_url.dgst -o dae-linux-$MACHINE.zip.dgst; then
        echo "${RED}error: Failed to download the checksum file!${RESET}"
        echo "${RED}Please check your network and try again.${RESET}"
        rm -f dae-linux-$MACHINE.zip.dgst
        exit 1
    fi
    remote_sha256=$(cat ./dae-linux-$MACHINE.zip.dgst | awk -F "./dae-linux-$MACHINE.zip" 'NR==3' | awk '{print $1}')
    if [ "$local_sha256" != "$remote_sha256" ]; then
        echo "${RED}error: The checksum of the downloaded file does not match!${RESET}"
        echo "${RED}Local SHA256: $local_sha256${RESET}"
        echo "${RED}Remote SHA256: $remote_sha256${RESET}"
        echo "${RED}Please check your network and try again.${RESET}"
        rm -f dae-linux-$MACHINE.zip
        exit 1
    fi
    unzip dae-linux-$MACHINE.zip -d /usr/local/bin/
    mv /usr/local/bin/dae-linux-$MACHINE /usr/local/bin/dae
    chmod +x /usr/local/bin/dae
    rm -f dae-linux-$MACHINE.zip
    echo "${GREEN}dae installed${RESET}"
}

installation(){
    if [ "$we_should_exit" == "1" ]; then
        exit 1
    fi
    check_version
    if [ "$current_version" == "$latest_version" ]; then
        echo "${GREEN}dae is already installed, current version: $current_version${RESET}"
        exit 0
    fi
    check_arch
    install_dae
    update_geoip
    update_geosite
    stop_dae
    start_dae
    if [ -f /usr/lib/systemd/systemd ]; then
        install_systemd_service
    elif [ -f /sbin/openrc-run ]; then
        install_openrc_service
    else
        echo "${YELLOW}warning: There is no Systemd or OpenRC on this system, no service would be installed.${RESET}"
        echo "${YELLOW}You should write service file/script by yourself.${RESET}"
    fi
    echo "${GREEN}dae installed, installed version: $latest_version${RESET}"
    echo "${GREEN}Your config file should be: /usr/local/etc/dae/config.dae${RESET}"
    if ! curl -sL "https://github.com/daeuniverse/dae/raw/main/example.dae" -o /usr/local/etc/dae/example.dae; then
        echo "${YELLOW}warning: Failed to download example config file.${RESET}"
        echo "${YELLOW}You can download it from https://raw.githubusercontent.com/daeuniverse/dae/main/example.dae${RESET}"
    else
        echo "${GREEN}Example config file downloaded to: /usr/local/etc/dae/example.dae${RESET}"
        echo "${GREEN}You can edit it and save it to /usr/local/etc/dae/config.dae${RESET}"
    fi
}
# Main
current_dir=$(pwd)
cd /tmp/
if [ "$1" == "update-geoip" ]; then
    update_geoip
elif [ "$1" == "update-geosite" ]; then
    update_geosite
elif [ "$1" == "install" ]; then
    installation
fi
if [ "$2" == "update-geoip" ]; then
    update_geoip
elif [ "$2" == "update-geosite" ]; then
    update_geosite
elif [ "$2" == "install" ]; then
    installation
fi
if [ "$3" == "update-geoip" ]; then
    update_geoip
elif [ "$3" == "update-geosite" ]; then
    update_geosite
elif [ "$3" == "install" ]; then
    installation
elif [ "$1" == "" ]; then
    installation
fi
cd $current_dir
if ! [ "$1" == "update-geoip" ] && ! [ "$1" == "update-geosite" ] && ! [ "$1" == "install" ] && ! [ "$1" == "" ]; then
    echo "${YELLOW}error: Invalid argument, usage:${RESET}"
    echo "${YELLOW}Run 'install.sh install' to install dae,${RESET}"
    echo "${YELLOW}Run 'install.sh update-geoip' to update GeoIP database,${RESET}"
    echo "${YELLOW}Run 'install.sh update-geosite' to update GeoSite database.${RESET}"
    exit 1
fi