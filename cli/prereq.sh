#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
OS=unsupported

# set OS as the specific family: ubuntu/rhel and 
identify_os()
{
    if ! command -v uname > /dev/null 2>&1; then
        echo "Unable to identify operating system"
        return
    fi

    OS=`uname`
    if [[ ${OS} == 'Darwin' ]] ; then
        echo "Identified MacOS"
        OS=mac
        return
    fi

    if [[ ${OS} != 'Linux' ]] ; then
        echo "Unsupported operating system: $OS"
        OS=unsupported
        return
    fi
        
    if [ ! -f /etc/os-release ]; then
        echo "Unsupported linux that is missing /etc/os-release file"
        OS="unsupported"
        return
    fi       

    . /etc/os-release
    if [[ "$ID" == "ubuntu" ]] || [[ "$ID_LIKE" == *ubuntu* ]]; then
        echo "This system is based on Ubuntu"
        OS="ubuntu"
    elif [ "$ID" == "rhel" ] || [ "$ID" == "centos" ] || [ "$ID" == "fedora" ] || [[ "$ID_LIKE" == *rhel* ]] || [[ "$ID_LIKE" == *fedora* ]]; then
        echo "This system is based on Red Hat."
        OS="rhel"
    else
        echo "Unsupported linux $ID that is not based on Ubuntu or Red Hat."
        OS="unsupported"
    fi
}

init_mac_prerequisites()
{
    # install brew
    if ! command -v brew > /dev/null 2>&1; then
        echo "Homebrew is not installed. Installing..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
        echo "Homebrew is already installed."
    fi

    brew install jq curl awscli

    # Installing Docker on macOS
    if ! command -v docker > /dev/null 2>&1; then
        echo "Docker is not installed. Installing..."
        brew install --cask docker
        open /Applications/Docker.app
    else
        echo "Docker is already installed."
    fi

    # Poll Docker until it is ready
    for i in {1..60}; do
        if docker info >/dev/null 2>&1; then
        echo "Docker is ready."
        break
        else
        echo "Waiting for Docker to be ready ($i)..."
        sleep 3
        fi
    done
    
}


init_ubuntu_prerequisites()
{
    SUDO=""
    if [ `id -u` != 0 ] ; then
        echo "Attempt to run with sudo"
        SUDO="sudo"
    fi
    
    # List of packages to install
    packages=("jq" "curl" "awscli" "docker.io")

    # Update package list
    $SUDO apt-get update

    # Install packages
    for pkg in "${packages[@]}"; do
        echo "Installing or updating $pkg..."
        $SUDO apt-get install -y $pkg
    done
}

identify_os
if [ ${OS} = 'mac' ] ; then
    init_mac_prerequisites
elif [ ${OS} = 'ubuntu' ] ; then
    init_ubuntu_prerequisites
elif [ ${OS} = 'rhel' ] ; then
    echo "Please install prereuisites for this system manually. Try to proceed anyway..."
else
    echo "Unsupported ${OS} operating system"
    exit 1
fi
