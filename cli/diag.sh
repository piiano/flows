#!/bin/bash
IFS=$'\n\t'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'
IS_MAC=false

msg()
{
    TOPIC=$1
    MSG=$2
    PREFIX=${3:-"${GREEN}OK"}
    printf "${PREFIX}${RESET}\t${TOPIC}\t${MSG}\n"
}

err()
{
    msg $1 $2 "${RED}ERROR"
    exit 1
}

warn()
{
    msg $1 $2 "${YELLOW}ERROR"
}

docker_exists()
{
    if command -v docker >/dev/null 2>&1; then
        msg "Docker" "CLI is installed"
        # Additional check for Docker daemon
        if docker info >/dev/null 2>&1; then
            msg "Docker" "daemon is running"
        else
            err "Docker" "daemon is not running"
        fi
    else
        err "Docker" "CLI is not installed"
    fi
}

docker_desktop()
{
    docker version | grep -q "Docker Desktop"
    if [ $? != "0" ] ; then
        warn "Docker" "unable to find docker desktop"
        return
    fi
    
    msg "Docker" "Identified docker desktop"

    SETTINGS="${HOME}/Library/Group Containers/group.com.docker/settings.json"
    cpus=$(jq ".cpus" "${SETTINGS}")
    memory=$(jq ".memoryMiB" "${SETTINGS}")
    disk_size=$(jq ".diskSizeMiB" "${SETTINGS}")
    disk_size=$((${disk_size} / 1000))
    data_folder=$(jq -r ".dataFolder" "${SETTINGS}")

    if [ $cpus -ge 4 ] ; then
        msg "Docker" "CPU (${cpus})"
    else
        warn "Docker" "CPU (${cpus})"
    fi

    if [ $memory -ge 4000 ] ; then
        msg "Docker" "Memory (${memory} MB)"
    else
        warn "Docker" "Memory (${memory} MB)"
    fi
    
    msg "Docker" "Disk size available ${disk_size} GB"
    msg "Docker" "Disk size allocated $(du -hs ${data_folder})"
    msg "Docker" "Internal Docker diagnostics:"
    /Applications/Docker.app/Contents/MacOS/com.docker.diagnose check
}

check_jars()
{
    dir=$1
    if [ ! -d ${dir} ] ; then
        warn "JARS" "Unable to find ${dir}"
    else
        num_files=$(find ${dir}  -name '*.jar' | wc -l)
        msg "JARs" "Found ${num_files} JARs in ${dir}"
    fi 
}

check_os()
{
    if [ $(uname) = "Darwin" ] ; then
        IS_MAC=true
        silicon=$(sysctl -n machdep.cpu.brand_string)
        msg "Hardware" "${silicon}"
        cpu_num=$(sysctl -n machdep.cpu.core_count)
        msg "Hardware" "${cpu_num}"
        msg "Hardware" "Architecture $(uname -m)"
    else
        IS_MAC=false
        # Assume Linux based / WSL
        cpu_num=$(cat /proc/cpuinfo | grep 'CPU architecture' | uniq)
        msg "Hardware" "${cpu_num}"
        mem_info=$(cat /proc/meminfo | grep 'MemTotal')
        msg "Hardware" "${mem_info}"
        msg "Hardware" "Architecture $(uname -m)"
        msg "OS details" "/etc/os-release:"
        cat /etc/os-release
    fi 
}

main()
{
    check_os
    check_jars $HOME/.m2
    check_jars $HOME/.gradle
    docker_exists

    if  ${IS_MAC} ; then
        docker_desktop
    fi

}

main