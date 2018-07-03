#!/bin/bash -eux

# Use commandline arguments first. If not found use env vars.
NAMESPACE_NAME=$1 
CLUSTER_NAME=$2
INGRESS_IP=127.0.0.1 # default...

if [ -z "$1" ]
  then
    NAMESPACE_NAME=$(NAMESPACE)
fi

if [ -z "$2" ]
  then
    CLUSTER_NAME=$(CLUSTER)
fi

if [ -z "$1" ]
  then
    echo "Missing namespace. Exiting."
    exit 1
fi

if [ -z "$2" ]
  then
    echo "Missing cluster. Exiting."
    exit 1
fi

# Get cluster password and set auth for convenience
PASSWORD=$(gcloud container clusters describe $CLUSTER_NAME | awk '/password/ {print $2}')
KUBECTL="kubectl -n $NAMESPACE_NAME --username=admin --password=$PASSWORD"

# Convenience method to set CloudBees Jenkins Enterprise Operations Center domain
get_domain_name() {
  echo "$NAMESPACE_NAME.$INGRESS_IP.xip.io"
}

# Installs CloudBees Jenkins Enterprise
install_cje() {
    local source=${1:?}
    local install_file; install_file=$(mktemp)
    cp $source $install_file
    
    # Set domain
    sed -i -e "s#cje.example.com#$(get_domain_name)#" "$install_file"
    echo "Installing CJE"
    $KUBECTL apply -f "$install_file"

    echo "Waiting for CJE to start"
    TIMEOUT=10 retry_command curl -sSLf -o /dev/null http://$(get_domain_name)/cjoc/login
}

# installs ingress controller if it doesn't already exist
install_ingress_controller(){
  if [[ -z $(kubectl get namespace | grep ingress-nginx ) ]]; then
    echo "Installing ingress controller"
    curl https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/mandatory.yaml | kubectl apply -f -

    curl https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/provider/cloud-generic.yaml | kubectl apply -f -
  fi

  # Set and check the ingress ip
  while [[ "$(kubectl get svc ingress-nginx -n ingress-nginx  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" = '' ]]; do sleep 3; done
  INGRESS_IP=$(kubectl get svc ingress-nginx -n ingress-nginx  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | sed 's/"//g')
  echo "NGINX INGRESS: $INGRESS_IP"
}

# Convenience method to retry a command several times
retry_command() {
  local max_attempts=${ATTEMPTS-60}
  local timeout=${TIMEOUT-1}
  local attempt=0
  local exitCode=0

  while (( $attempt < $max_attempts ))
  do
    set +e
    "$@"
    exitCode=$?
    set -e

    if [[ $exitCode == 0 ]]
    then
      break
    fi

    echo "$(date -u '+%T') Failure ($exitCode) Retrying in $timeout seconds..." 1>&2
    sleep $timeout
    attempt=$(( attempt + 1 ))
    timeout=$(( timeout ))
  done

  if [[ $exitCode != 0 ]]
  then
    echo "$(date -u '+%T') Failed in the last attempt ($@)" 1>&2
  fi

  return $exitCode
}

# Main starts here

# Configure GKE cluster to be ready for CJE
gcloud container clusters get-credentials "$CLUSTER_NAME"
kubectl create clusterrolebinding cluster-admin-binding  --clusterrole cluster-admin  --user $(gcloud config get-value account)

# Install ingress controller and get IP
install_ingress_controller

# Create namespace 
kubectl create namespace "$NAMESPACE_NAME"
kubectl label namespace "$NAMESPACE_NAME" name="$NAMESPACE_NAME"

# Install CJE
kubectl config set-context $(kubectl config current-context) --namespace="${NAMESPACE_NAME}"
install_cje "/data/cje.yml"

# console validation
if (curl -s "http://$(get_domain_name)/cjoc/login" | grep "Unlock Jenkins") 
        echo "CloudBees Jenkins Enterprise launched successfully."
        exit 0
else
        echo "CloudBees Jenkins Enterprise failed to launch"
        exit 1

# End of script