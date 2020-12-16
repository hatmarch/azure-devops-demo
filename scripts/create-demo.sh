#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="az-demo"
declare SA_PASSWORD=""
declare AZURE_PROJECT="fmg-project"
declare AZURE_ORG=""
declare AZURE_PIPELINE_NAME="fmg-demo-yaml"
declare CLUSTER_ADMIN_PASSWORD=""
declare CONTAINER_REGISTRY_URL="https://quay.io/"
declare CONTAINER_REGISTRY_USERNAME=""
declare CONTAINER_REGISTRY_PASSWORD=""

display_usage() {
cat << EOF
$0: Azure DevOps Demo --

  Usage: ${0##*/} [ OPTIONS ]
  
    -i         [optional] Install prerequisites
    -P <TEXT>  [optional] Project prefix to use.  Defaults to "az-demo"
    -q <TEXT>  The password to use for the sa user of the database
    -o <TEXT>  The URL of the Azure organization (for use with az cli)
    -p <TEXT>  [optional] Password of the OpenShift cluster admin account.  If not provided token based authentication will be used for service connections
    -u <TEXT>  Container Registry user name
    -w <TEXT>  Container Registry password
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
  while getopts ':iP:p:q:o:a:u:w:h' option; do
      case "${option}" in
          i  ) prereq_flag=true;;
          P  ) P_flag=true; PROJECT_PREFIX="${OPTARG}";;
          p  ) p_flag=true; CLUSTER_ADMIN_PASSWORD="${OPTARG}";;
          a  ) a_flag=true; AZURE_PROJECT="${OPTARG}";;
          o  ) o_flag=true; AZURE_ORG="${OPTARG}";;
          q  ) q_flag=true; SA_PASSWORD="${OPTARG}";;
          u  ) u_flag=true; CONTAINER_REGISTRY_USERNAME="${OPTARG}";;
          w  ) w_flag=true; CONTAINER_REGISTRY_PASSWORD="${OPTARG}";;
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

  if [[ -z "${AZURE_ORG}" ]]; then
      printf '%s\n\n' 'ERROR - Need to specify the URL of an Azure organization' >&2
      display_usage >&2
      exit 1
  fi

  if [[ -z "${CONTAINER_REGISTRY_USERNAME}" ]]; then
      printf '%s\n\n' 'ERROR - Need to specify the user for a container registry' >&2
      display_usage >&2
      exit 1
  fi

  if [[ -z "${CONTAINER_REGISTRY_PASSWORD}" ]]; then
      printf '%s\n\n' 'ERROR - Need to specify the password for a container registry' >&2
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

    # OPENSHIFT_SERVER_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
    OPENSHIFT_SERVER_URL=$(oc whoami --show-server)
    echo "Current OpenShift server URL is: ${OPENSHIFT_SERVER_URL}"

    #    
    # create the dev project
    #
    echo "Creating projects"
    dev_prj="${PROJECT_PREFIX}-dev"
    oc get ns $dev_prj 2>/dev/null  || { 
        oc new-project $dev_prj
    }
    
    stage_prj="${PROJECT_PREFIX}-stage"
    oc get ns $stage_prj 2>/dev/null || {
        oc new-project $stage_prj
    }

    sup_prj="${PROJECT_PREFIX}-support"
    oc get ns $sup_prj 2>/dev/null || {
        oc new-project $sup_prj
    }

    echo "Granting default service account of $sup_prj edit access to both $dev_prj and $stage_prj"
    oc adm policy add-role-to-user edit system:serviceaccount:$sup_prj:default -n $stage_prj
    oc adm policy add-role-to-user edit system:serviceaccount:$sup_prj:default -n $dev_prj  

    AZURE_PROJECT=$(trim $AZURE_PROJECT)
    echo "AZURE_PROJECT is $AZURE_PROJECT"

    #
    # Project creation
    #
    echo "Creating new project ${AZURE_PROJECT} in org ${AZURE_ORG}."
    az devops project create --name ${AZURE_PROJECT} --visibility public --organization ${AZURE_ORG} > /dev/null

    # Initialize the azure cli
    az devops configure --defaults organization=${AZURE_ORG} project=${AZURE_PROJECT}


    #
    # Create fresh azure repo for demo (add --debug to both to see verbose output)
    #
    echo "Creating repo"
    declare AZURE_REPO=eshop
    # --query webUrl
    AZURE_REPO_URL=$(az repos create --name ${AZURE_REPO} --query webUrl)
    echo "Importing repo"
    az repos import create --git-url https://github.com/hatmarch/eShopOnWeb.git -r ${AZURE_REPO} > /dev/null
    echo "Updating repo"
    az repos update --default-branch feature-fmg -r ${AZURE_REPO} > /dev/null
    echo "Created repo at: ${AZURE_REPO_URL}"

    echo "Creating Azure DevOps Pipeline from YAML"
    az pipelines create --name ${AZURE_PIPELINE_NAME} --description 'Pipeline for FMG (YAML)' --repository $(trim ${AZURE_REPO_URL}) \
        --branch feature-fmg --yml-path azure-pipelines.yml --skip-first-run > /dev/null

    #
    # create service connections
    #
    echo "Creating service connections for use in pipeline"
    
    # Kubernetes connection
    echo "Creating Kubernetes Manifest connection"
    K8_SA_SECRET_NAME=$(oc get sa default -n $sup_prj -o=json | jq -r '.secrets[] | select(.name | test("default-token")).name')
    K8_SA_CA_CRT=$(oc get secret $K8_SA_SECRET_NAME -o jsonpath='{.data.ca\.crt}' -n $sup_prj)
    K8_SA_TOKEN=$(oc get secret $K8_SA_SECRET_NAME -o jsonpath='{.data.token}' -n $sup_prj)
    sed "s/@CRT@/${K8_SA_CA_CRT}/g" $DEMO_HOME/install/azure-devops/service-connection-templates/k8-manifest-service-connection.json | \
        sed "s/@TOKEN@/${K8_SA_TOKEN}/g" | sed "s#@SERVER_URL@#${OPENSHIFT_SERVER_URL}#" > /tmp/k8-manifest-conn.json
    K8_MANIFEST_CONNECTION_ID=$(trim $(az devops service-endpoint create --service-endpoint-configuration /tmp/k8-manifest-conn.json --query id))
    az devops service-endpoint update --id $K8_MANIFEST_CONNECTION_ID --enable-for-all true > /dev/null

    # openshift connection
    echo "Creating Openshift connection"
    if [[ -n $CLUSTER_ADMIN_PASSWORD ]]; then
        sed "s/@USER@/$(oc whoami)/g" $DEMO_HOME/install/azure-devops/service-connection-templates/openshift-service-connection.json | \
            sed "s/@PASSWORD@/'${CLUSTER_ADMIN_PASSWORD}'/g" | sed "s#@SERVER_URL@#${OPENSHIFT_SERVER_URL}#g" > /tmp/oc-conn.json
    else
        echo "No cluster admin password provided, using service account token instead."
        sed "s/@TOKEN@/${K8_SA_TOKEN}/g" $DEMO_HOME/install/azure-devops/service-connection-templates/openshift-service-connection-token.json | \
            sed "s#@SERVER_URL@#${OPENSHIFT_SERVER_URL}#g" > /tmp/oc-conn.json
        # FIXME: Use the token of a service account instead
        # echo "WARNING: No cluster admin password provided, using token based service connection instead which could lead to authentication issues when token expires"
        # sed "s/@TOKEN@/$(oc whoami -t)/g" $DEMO_HOME/install/azure-devops/service-connection-templates/openshift-service-connection-token.json | \
        #     sed "s#@SERVER_URL@#${OPENSHIFT_SERVER_URL}#g" > /tmp/oc-conn.json
    fi
    OPENSHIFT_CONNECTION_ID=$(trim $(az devops service-endpoint create --service-endpoint-configuration /tmp/oc-conn.json --query id))
    az devops service-endpoint update --id $OPENSHIFT_CONNECTION_ID --enable-for-all true > /dev/null

    # registry connection
    echo "Creating Registry Connection"
    sed "s#@REGISTRY_URL@#${CONTAINER_REGISTRY_URL}#g" $DEMO_HOME/install/azure-devops/service-connection-templates/registry-service-connection.json | \
        sed "s/@USER@/${CONTAINER_REGISTRY_USERNAME}/g" | sed "s/@SERVER_URL@/${CONTAINER_REGISTRY_PASSWORD}/" > /tmp/registry-conn.json
    REGISTRY_CONNECTION_ID=$(trim $(az devops service-endpoint create --service-endpoint-configuration /tmp/registry-conn.json --query id))
    az devops service-endpoint update --id $REGISTRY_CONNECTION_ID --enable-for-all true > /dev/null
    
    # create variables for the pipeline
    echo "Creating variables for the service connections in the pipeline"
    az pipelines variable create --pipeline-name ${AZURE_PIPELINE_NAME} --name openshift_service_connection_id --value ${OPENSHIFT_CONNECTION_ID} > /dev/null
    az pipelines variable create --pipeline-name ${AZURE_PIPELINE_NAME} --name k8_manifest_service_connection_id --value ${K8_MANIFEST_CONNECTION_ID} > /dev/null
    az pipelines variable create --pipeline-name ${AZURE_PIPELINE_NAME} --name container_registry_service_connection_id --value ${REGISTRY_CONNECTION_ID} > /dev/null

    #
    # Start setting up the cluster
    #

    #FIXME: Testing
    # echo "exit testing"
    # exit 0

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

    # Update environment templates
    ${SCRIPT_DIR}/update-environment-templates.sh ${SA_PASSWORD}

    echo "Pre-seed the user codeready namespace (${crw_user_ns}) with environment secret"
    oc create secret generic codeready-env --from-file=.zshenv=$DEMO_HOME/secrets/.zshenv-k8 -n $crw_user_ns

    # annotate the secret so that it is loaded by default in all codeready workspaces
    oc annotate secret --overwrite codeready-env "che.eclipse.org/automount-workspace-secret"="true" "che.eclipse.org/mount-path"="{prod-home}" \
        "che.eclipse.org/mount-as"="file" -n $crw_user_ns

    echo "Create secret for deployment config in dev environment"
    oc create secret generic eshop-dev --from-env-file=$DEMO_HOME/secrets/.zshenv-k8 -n $dev_prj

#    kubectl get serviceAccounts <service-account-name> -n <namespace> -o=jsonpath={.secrets[*].name}

    echo "Demo installation completed successfully!"
}

main "$@"