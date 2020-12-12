#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="az-demo"
declare SA_PASSWORD=""

display_usage() {
cat << EOF
$0: Azure DevOps Demo --

  Usage: ${0##*/} [ OPTIONS ]
  
    -i         [optional] Install prerequisites
    -p <TEXT>  [optional] Project prefix to use.  Defaults to "az-demo"
    -q <TEXT>  The password to use for the sa user of the database

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
  while getopts ':ip:q:h' option; do
      case "${option}" in
          i  ) prereq_flag=true;;
          p  ) p_flag=true; PROJECT_PREFIX="${OPTARG}";;
          q  ) q_flag=true; SA_PASSWORD="${OPTARG}";;
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

  if [[ -z "${SA_PASSWORD}" ]]; then
      printf '%s\n\n' 'ERROR - Database sa password must not be null' >&2
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

    # Install pre-reqs before tekton
    if [[ -n "${prereq_flag:-}" ]]; then
        ${SCRIPT_DIR}/install-prereq.sh 
    fi

    #
    # create the dev project
    #
    dev_prj="${PROJECT_PREFIX}-dev"
    oc get ns $dev_prj 2>/dev/null  || { 
        oc new-project $dev_prj
    }
    # this label is needed to allow windows nodes to run, per this article: 
    # https://github.com/openshift/windows-machine-config-bootstrapper/blob/release-4.6/tools/ansible/docs/ocp-4-4-with-windows-server.md#deploying-in-a-namespace-other-than-default
    # oc label --overwrite namespace $vm_prj 'openshift.io/run-level'=1

    stage_prj="${PROJECT_PREFIX}-stage"
    oc get ns $stage_prj 2>/dev/null || {
        oc new-project $stage_prj
    }

    sup_prj="${PROJECT_PREFIX}-support"
    oc get ns $sup_prj 2>/dev/null || {
        oc new-project $sup_prj
    }

    echo "Deploying Database"
    oc get secret sql-secret -n $dev_prj 2>/dev/null || {
        oc create secret generic sql-secret --from-literal SA_PASSWORD="${SA_PASSWORD}" -n $dev_prj
    }
    # install this template to the openshift project so that it's available everywhere
    oc apply -f $DEMO_HOME/install/kube/database/database-template.yaml -n openshift

    # actually create the database (FIXME: Do this via the template)
    oc apply -f $DEMO_HOME/install/kube/database/database-deploy.yaml -n $dev_prj
    echo -n "Waiting for database deployment to appear..."
    while [[ -z "$(oc get deploy hplus-db -n $dev_prj 2>/dev/null)" ]]; do
        echo -n "."
        sleep 1
    done
    echo "done!"
    oc rollout status deploy/hplus-db -n $dev_prj

    echo "Initializing database"
    ${SCRIPT_DIR}/initialize-database.sh $dev_prj

    echo "Installing CodeReady Workspaces"
    ${SCRIPT_DIR}/install-crw.sh codeready

    echo "Creating PVCs"
    oc apply -R -f $DEMO_HOME/install/kube/storage/ -n $dev_prj

    echo "Installing Tekton Tasks"
    #oc apply -R -f install/kube/tekton/tasks/ -n $sup_prj

     # There can be a race when the system is installing the pipeline operator in the $sup_prj
    echo -n "Waiting for Pipelines Operator to be installed in $sup_prj..."
    while [[ "$(oc get $(oc get csv -oname -n $sup_prj| grep pipelines) -o jsonpath='{.status.phase}' -n $sup_prj 2>/dev/null)" != "Succeeded" ]]; do
        echo -n "."
        sleep 1
    done
    echo "done."

    echo "Initiatlizing git repository in gitea and configuring webhooks"
    oc apply -f $DEMO_HOME/install/kube/gitea/gitea-server-cr.yaml -n $sup_prj
    oc wait --for=condition=Running Gitea/gitea-server -n $sup_prj --timeout=6m
    echo -n "Waiting for gitea deployment to appear..."
    while [[ -z "$(oc get deploy gitea -n $sup_prj 2>/dev/null)" ]]; do
        echo -n "."
        sleep 1
    done
    echo "done!"
    oc rollout status deploy/gitea -n $sup_prj

    oc create -f $DEMO_HOME/install/kube/gitea/gitea-init-taskrun.yaml -n $sup_prj
    # output the logs of the latest task
    tkn tr logs -L -f -n $sup_prj

    crw_user_ns="$(oc whoami)-codeready"
    oc get ns $crw_user_ns 2>/dev/null  || { 
        oc new-project $crw_user_ns
    }

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

    echo "Pre-seed the user codeready namespace (${crw_user_ns}) with environment secret"
    oc create secret generic codeready-env --from-file=.zshenv=$DEMO_HOME/secrets/.zshenv-k8 -n $crw_user_ns

    # annotate the secret so that it is loaded by default in all codeready workspaces
    oc annotate secret --overwrite codeready-env "che.eclipse.org/automount-workspace-secret"="true" "che.eclipse.org/mount-path"="{prod-home}" \
        "che.eclipse.org/mount-as"="file" -n $crw_user_ns

    echo "Create secret for deployment config in dev environment"
    oc create secret generic eshop-dev --from-env-file=$DEMO_HOME/secrets/.zshenv-k8 -n $dev_prj

    echo "Demo installation completed successfully!"
}

main "$@"