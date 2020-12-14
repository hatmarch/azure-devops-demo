#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare SA_PASSWORD=${1-}

if [[ -z "${SA_PASSWORD}" ]]; then
    echo "No database password provided as argument to this script"
    exit 1
fi

echo "Writing secrets into environment templates..."
if [[ ! -d $DEMO_HOME/secrets ]]; then
    mkdir $DEMO_HOME/secrets
fi
ENV_TEMPLATES=( .zshenv .zshenv-k8 )
for TEMPLATE in ${ENV_TEMPLATES[@]}; do
    echo "Writing $DEMO_HOME/secrets/$TEMPLATE"
    sed "s/@SA_PASSWORD@/${SA_PASSWORD}/" $DEMO_HOME/install/config/$TEMPLATE > $DEMO_HOME/secrets/$TEMPLATE
done
echo "done."

#source $DEMO_HOME/secrets/.zshenv