#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="az-demo"
declare sup_prj="${PROJECT_PREFIX}-support"
declare AZURE_PROJECT="fmg-project"
declare AZURE_ORG=""

display_usage() {
cat << EOF
$0: k8 for Window Devs Demo Uninstall --

  Usage: ${0##*/} [ OPTIONS ]
  
    -f         [optional] Full uninstall, removing pre-requisites
    -P <TEXT>  [optional] Project prefix to use.  Defaults to az-demo
    -s <TEXT>  [optional] The name of the support project.  Defaults to az-demo-support
    -o <TEXT>  The URL of the Azure organization (for use with az cli)
    -a <TEXT>  [optional] The Azure project in question.  Default to fmg-project
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
  while getopts ':s:P:f:a:oh' option; do
      case "${option}" in
          s  ) sup_flag=true; sup_prj="${OPTARG}";;
          P  ) P_flag=true; PROJECT_PREFIX="${OPTARG}";;
          a  ) a_flag=true; AZURE_PROJECT="${OPTARG}";;
          o  ) o_flag=true; AZURE_ORG="${OPTARG}";;
          f  ) full_flag=true;;
          h  ) display_usage; exit;;
          \? ) printf "%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
          :  ) printf "%s\n\n%s\n\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
      esac
  done
  shift "$((OPTIND - 1))"

  if [[ -z "${PROJECT_PREFIX}" ]]; then
      printf '%s\n\n' 'ERROR - PROJECT_PREFIX must not be null' >&2
      display_usage >&2
      exit 1
  fi

  if [[ ${sup_flag:-} && -z "${sup_prj}" ]]; then
      printf '%s\n\n' 'ERROR - Support project must not be null' >&2
      display_usage >&2
      exit 1
  fi

  if [[ -z "${AZURE_ORG}" ]]; then
      printf '%s\n\n' 'ERROR - Need to specify the URL of an Azure organization' >&2
      display_usage >&2
      exit 1
  fi
}

main() {
    # import common functions
    . $SCRIPT_DIR/common-func.sh

    trap 'error' ERR
    trap 'cleanup' EXIT SIGTERM
    trap 'interrupt' SIGINT

    get_and_validate_options "$@"

    az devops project delete --id ${${$(az devops project show -p ${AZURE_PROJECT} --query id)%\"}#\"} --organization ${AZURE_ORG} --yes

    dev_prj="${PROJECT_PREFIX}-dev"
    stage_prj="${PROJECT_PREFIX}-stage"
    sup_prj="${PROJECT_PREFIX}-sup"

    if [[ -n "${full_flag:-""}" ]]; then
        remove-operator "openshift-pipelines-operator-rh" || true

        remove-operator "codeready-workspaces" || true
    fi

    # delete the checluster before deleting the codeready project
    oc delete checluster --all -n codeready

    # delete the codeready project as well as any projects created for a given user
    oc get project -o name | grep codeready | xargs oc delete || true

    PROJECTS=( $dev_prj $stage_prj $sup_prj )
    for PROJECT in ${PROJECTS[@]}; do
        echo "Deleting project ${PROJECT}"
        oc delete project ${PROJECT} || true
    done
 
   if [[ -n "${full_flag:-}" ]]; then
        echo "Removing Gitea Operator"
        oc delete project gpte-operators || true
        oc delete clusterrole gitea-operator || true
        remove-crds gitea || true

        echo "Cleaning up CRDs"

        # delete all CRDS that maybe have been left over from operators
        CRDS=( "tekton.dev" "checlusters.org.eclipse.che" )
        for CRD in "${CRDS[@]}"; do
            remove-crds ${CRD} || true
        done
    fi
}

main "$@"
