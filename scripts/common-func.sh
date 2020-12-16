interrupt() {
  cleanup 130
}

error() {
  local ret=$?
  echo "[$0] An error occured during the execution of the script"
  cleanup ${ret}
}

cleanup() {
  local ret="${1:-${?}}"

  echo "Finishing with return value of ${ret}"
  exit "${ret}"
}

remove-operator()
{
    OPERATOR_NAME=$1
    OPERATOR_PRJ=${2:-openshift-operators}

    echo "Uninstalling operator: ${OPERATOR_NAME} from project ${OPERATOR_PRJ}"
    # NOTE: there is intentionally a space before "currentCSV" in the grep since without it f.currentCSV will also be matched which is not what we want
    CURRENT_CSV=$(oc get sub ${OPERATOR_NAME} -n ${OPERATOR_PRJ} -o yaml | grep " currentCSV:" | sed "s/.*currentCSV: //")
    oc delete sub ${OPERATOR_NAME} -n ${OPERATOR_PRJ} || true
    oc delete csv ${CURRENT_CSV} -n ${OPERATOR_PRJ} || true

    # Attempt to remove any orphaned install plan named for the csv
    oc get installplan -n ${OPERATOR_PRJ} | grep ${CURRENT_CSV} | awk '{print $1}' 2>/dev/null | xargs oc delete installplan -n $OPERATOR_PRJ
}

remove-crds() 
{
    API_NAME=$1

    oc get crd -oname | grep "${API_NAME}" | xargs oc delete
}

# Get rid of leading and trailing \" only
# See also: https://stackoverflow.com/questions/9733338/shell-script-remove-first-and-last-quote-from-a-variable
trim() {
    TEMP=${1%\"}
    echo ${TEMP#\"}
}