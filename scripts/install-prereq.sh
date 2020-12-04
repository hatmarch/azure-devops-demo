#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="az-demo"

display_usage() {
cat << EOF
$0: Install Azure DevOps Demo Prerequisites --

  Usage: ${0##*/} [ OPTIONS ]

    -s <NAMESPACE>    [optional] Change the name of the support namespace (default: az-demo-support)

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
  while getopts ':ho:' option; do
      case "${option}" in
          # o  ) o_flag=true; WMCO_OPERATOR_IMAGE="${OPTARG}";;
          s  ) sup_prj="${OPTARG}";;
          h  ) display_usage; exit;;
          \? ) printf "%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
          :  ) printf "%s\n\n%s\n\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
      esac
  done
  shift "$((OPTIND - 1))"

}

wait_for_crd()
{
    local CRD=$1
    local PROJECT=$(oc project -q)
    if [[ "${2:-}" ]]; then
        # set to the project passed in
        PROJECT=$2
    fi

    # Wait for the CRD to appear
    while [ -z "$(oc get $CRD 2>/dev/null)" ]; do
        sleep 1
    done 
    oc wait --for=condition=Established $CRD --timeout=6m -n $PROJECT
}


main()
{
    # import common functions
    . $SCRIPT_DIR/common-func.sh

    trap 'error' ERR
    trap 'cleanup' EXIT SIGTERM
    trap 'interrupt' SIGINT

    get_and_validate_options "$@"


    declare giteaop_prj=gpte-operators
    echo "Installing gitea operator in ${giteaop_prj}"
    oc apply -f $DEMO_HOME/install/kube/gitea/gitea-crd.yaml
    oc apply -f $DEMO_HOME/install/kube/gitea/gitea-cluster-role.yaml
    oc get ns $giteaop_prj 2>/dev/null  || { 
        oc new-project $giteaop_prj --display-name="GPTE Operators"
    }

    # create the service account and give necessary permissions
    oc get sa gitea-operator -n $giteaop_prj 2>/dev/null || {
      oc create sa gitea-operator -n $giteaop_prj
    }
    oc adm policy add-cluster-role-to-user gitea-operator system:serviceaccount:$giteaop_prj:gitea-operator

    # install the operator to the gitea project
    oc apply -f $DEMO_HOME/install/kube/gitea/gitea-operator.yaml -n $giteaop_prj

    #
    # Install Pipelines (Tekton)
    #
    echo "Installing OpenShift pipelines"
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: ocp-4.6
  installPlanApproval: Automatic
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    # Ensure pipelines is installed
    wait_for_crd "crd/pipelines.tekton.dev"

    echo -n "Ensuring gitea operator has installed successfully..."
    oc rollout status deploy/gitea-operator -n $giteaop_prj
    echo "done."

    echo "Prerequisites installed successfully!"

}

main "$@"



