#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT="az-demo-dev"
declare DATABASE_SVC="hplus-db"

display_usage() {
cat << EOF
$0: Database Initialization --

  Usage: ${0##*/} [ OPTIONS ]
  
    -p <TEXT>  [optional] The project in which the database should be initialized

EOF
}

get_and_validate_options() {
  # Transform long options to short ones
#   for arg in "$@"; do
#     shift
#     case "$arg" in
#       "--long-x") set -- "$@" "-x" ;;
#       "--long-y") set -- "$@" "-y" ;;
#       *)        set -- "$@" "$arg"
#     esac
#   done

  
  # parse options
  while getopts ':ip:h' option; do
      case "${option}" in
          p  ) p_flag=true; PROJECT="${OPTARG}";;
          h  ) display_usage; exit;;
          \? ) printf "%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
          :  ) printf "%s\n\n%s\n\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
      esac
  done
  shift "$((OPTIND - 1))"

  if [[ -z "${PROJECT}" ]]; then
      printf '%s\n\n' 'ERROR - PROJECT must not be null' >&2
      display_usage >&2
      exit 1
  fi
}

declare PORT_FORWARD_PID=""

cleanup() {
    if [[ -n "${PORT_FORWARD_PID}" ]]; then
        echo "Stopping port-forward task at ${PORT_FORWARD_PID}"
        kill ${PORT_FORWARD_PID}
    fi
}

main() {
    # import common functions
    . $SCRIPT_DIR/common-func.sh

    trap 'cleanup' ERR EXIT SIGTERM SIGINT

    get_and_validate_options "$@"

    # port forward to the database
    echo "Setting up localhost:1433 to port-forward to the database"
    oc port-forward svc/${DATABASE_SVC} 1433:1433 -n $PROJECT &
    PORT_FORWARD_PID=$!

    cd $DEMO_HOME/eShopOnWeb/src/Web

    dotnet tool restore
    dotnet ef database update -c catalogcontext -p ../Infrastructure/Infrastructure.csproj -s Web.csproj
    dotnet ef database update -c appidentitydbcontext -p ../Infrastructure/Infrastructure.csproj -s Web.csproj

    echo "Database successfully initialized."
}

main "$@"