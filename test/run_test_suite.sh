#!/usr/bin/env bash
set -e
set -x

while getopts p options; do
    case $options in
        p)
            proxy=TRUE
            ;;
        *)
            echo "Usage $0 [-p ] # starts a proxy that caches packages in-memory"
            exit
            ;;
    esac
done

if [[ -v proxy ]]; then
    os=$(uname)
    if [[ $os = 'Linux' ]]; then
        echo Unimplemented
        exit 1
    elif [[ $os = 'Darwin' ]]; then
        squid='/usr/local/opt/squid/sbin/squid'
    else
        echo 'Unknown OS'
        exit 1
    fi

    if ! pgrep -qF squid.pid; then
        $squid -N -f squid.conf &
    fi
    export http_proxy=http://10.0.2.2:3128
fi

part=("-t gpt" "-t mbr")
lvm=("-l" "")
crypt=("-e testencpass" "")
distro=("-d debian -r trixie" "-d ubuntu -r plucky")

for p in "${part[@]}"; do
    for l in "${lvm[@]}"; do
        for e in "${crypt[@]}"; do
            for d in "${distro[@]}"; do
              if [[ $p =~ 'gpt' ]]; then
                firmware_params='-e'
              fi
              python3 test_vm.py "$firmware_params" --append-arguments="$d $p $e $l" install
              python3 test_vm.py "$firmware_params" test
            done
        done
    done
done
