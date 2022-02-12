#!/usr/bin/env bash

set -o errexit
set -o pipefail

usage() {
  echo -e "Usage: $0 [--create-cluster|--install-extensions] [flags]\n\nFlags:\n-h,--help\t\tthis help\n-v,--vcenter-ip\t\tthe vcenter ip\n-u,--vcenter-username\tthe vcenter username\n-n,--namespace\t\tthe vsphere namespace\n-c,--cluster-name\tthe cluster name\n-e,--env\t\tthe cluster environment"
}


TEMPLATE_DIR="templates"
TKC_TEMPLATE_FILE_FINAL="${TKC_TEMPLATE_FILE:-tkc_v1alpha1.yaml}"
EXTENSIONS_DIR="extensions/current"

options=$(getopt -l "help,vcenter-ip:,vcenter-username:,namespace:,env:,cluster-name:,create-cluster,install-extensions" -o "Chv:u:n:e:c:i" -a -- "$@")

if [ $? -ne 0 ];
then
  exit 1
fi

eval set -- "$options"

export CREATE_CLUSTER=0
export INSTALL_EXTENSIONS=0

while true
do
  case $1 in
    -h|--help)
      usage
      exit 0
      ;;
    -v|--vcenter-ip)
      shift
      export VCENTER_IP=$1
      ;;
    -u|--vcenter-username)
      shift
      export VCENTER_USERNAME=$1
      ;;
    -n|--namespace)
      shift
      export NAMESPACE_NAME=$1
      ;;
    -e|--env)
      shift
      export CLUSTER_ENV=$1
      ;;
    -c|--cluster-name)
      shift
      export CLUSTER_NAME=$1
      ;;
    -C|--create-cluster)
      export CREATE_CLUSTER=1
      ;;
    -i|--install-extensions)
      export INSTALL_EXTENSIONS=1
      ;;
    --)
      shift
      break;;
  esac
  shift
done


if [[ -z ${VCENTER_IP} || -z ${VCENTER_USERNAME} || -z ${NAMESPACE_NAME} || -z ${CLUSTER_ENV}} || -z ${CLUSTER_NAME} ]]
then
  usage
  exit 1
fi

declare -A EXTENSIONS_MAP_NS
declare -A EXTENSIONS_MAP_DIR

EXTENSIONS_MAP_NS=( ["contour"]="tanzu-system-ingress" ["external-dns"]="tanzu-system-service-discovery" ["fluent-bit"]="tanzu-system-logging" ["prometheus"]="tanzu-system-monitoring" ["grafana"]="tanzu-system-monitoring" )
EXTENSIONS_MAP_DIR=( ["contour"]="ingress" ["external-dns"]="service-discovery" ["fluent-bit"]="logging" ["prometheus"]="monitoring" ["grafana"]="monitoring")
EXTENSIONS_LIST="contour external-dns fluent-bit prometheus grafana"

CLUSTER_FILES_DIR="build/${CLUSTER_ENV}/${NAMESPACE_NAME}/${CLUSTER_NAME}"

create_cluster() {
  echo "Creating tkc file ${CLUSTER_NAME}.yaml in the ${CLUSTER_FILES_DIR} path"
  mkdir -p ${CLUSTER_FILES_DIR}
  cp ${TEMPLATE_DIR}/${TKC_TEMPLATE_FILE_FINAL} ${CLUSTER_FILES_DIR}/${CLUSTER_NAME}.yaml
  sed -e "s/CLUSTER_NAME/${CLUSTER_NAME}/g" -i ${CLUSTER_FILES_DIR}/${CLUSTER_NAME}.yaml
  echo "Login to vsphere and Change context to the correct vsphere namespace"
  if [ -e $HOME/.kube/config ]
  then
    mv $HOME/.kube/config $HOME/.kube/config.bak
  fi
  kubectl vsphere login --vsphere-username ${VCENTER_USERNAME} --server=https://${VCENTER_IP} --insecure-skip-tls-verify --tanzu-kubernetes-cluster-namespace ${NAMESPACE_NAME}
  kubectl config use-context ${NAMESPACE_NAME}
  echo "Creating tkc cluster ${CLUSTER_NAME} in the vsphere namespace ${NAMESPACE_NAME}"
  kubectl apply -f ${CLUSTER_FILES_DIR}/${CLUSTER_NAME}.yaml
  if [ -e $HOME/.kube/config.bak ]
  then
    mv $HOME/.kube/config.bak $HOME/.kube/config
  fi
}

prepare_context() {
  LOGIN_STRING="kubectl vsphere login --vsphere-username ${VCENTER_USERNAME} --server=https://${VCENTER_IP} --insecure-skip-tls-verify --tanzu-kubernetes-cluster-namespace ${NAMESPACE_NAME}"
  if [ $CREATE_CLUSTER -eq 1 ]
  then
    echo "Login to vsphere and Change context to the correct vsphere namespace"
    $LOGIN_STRING
  fi
  if [ $INSTALL_EXTENSIONS -eq 1 ]
  then
    echo "Login to vsphere and Change context to the correct cluster"
    $LOGIN_STRING --tanzu-kubernetes-cluster-name ${CLUSTER_NAME}
  fi
}

install_prereq() {
  echo "Installing cert-manager"
  IF_NS=$(kubectl get ns cert-manager --no-headers) &> /dev/null || true
  if [[ -z $IF_NS ]]
  then
    kubectl apply -f ${EXTENSIONS_DIR}/cert-manager
  else
    echo "cert-manager already installed"
  fi
  echo "Installing kapp-controller"
  IF_NS=$(kubectl get ns tkg-system --no-headers) &> /dev/null || true
  if [[ -z ${IF_NS} ]]
  then
    if [ -e ${CLUSTER_FILES_DIR}/kapp-controller.yaml ]
    then
      kubectl apply -f ${CLUSTER_FILES_DIR}/kapp-controller.yaml
    else
      kubectl apply -f ${EXTENSIONS_DIR}/extensions/kapp-controller.yaml
    fi
  else
    echo "kapp-controller already installed"
  fi
}

install_extensions() {
  for extension in ${EXTENSIONS_LIST}
  do
    echo "---"
    echo "Installing $extension extension"
    IF_NOT_INSTALLED=$(kubectl get secret -n ${EXTENSIONS_MAP_NS[${extension}]} ${extension}-data-values --no-headers) &> /dev/null || true
    if [[ -z ${IF_NOT_INSTALLED} ]]
      then
        kubectl apply -f ${EXTENSIONS_DIR}/extensions/${EXTENSIONS_MAP_DIR[${extension}]}/${extension}/namespace-role.yaml
        if [ -e "${CLUSTER_FILES_DIR}/${extension}-data-values.yaml" ]
          then
            kubectl create secret generic ${extension}-data-values --from-file=values.yaml=${CLUSTER_FILES_DIR}/${extension}-data-values.yaml -n ${EXTENSIONS_MAP_NS[${extension}]}
            if [ -e ${CLUSTER_FILES_DIR}/${extension}-extension.yaml ]
            then
              kubectl apply -f ${CLUSTER_FILES_DIR}/${extension}-extension.yaml
            else
              kubectl apply -f ${EXTENSIONS_DIR}/extensions/${EXTENSIONS_MAP_DIR[${extension}]}/${extension}/${extension}-extension.yaml
            fi
          else
            echo -e "\n---"
            echo "/!\\ ${extension}-data-values.yaml file missing /!\\"
            echo -e "---\n"
            kubectl delete ns ${EXTENSIONS_MAP_NS[${extension}]}
            exit 1
          fi
      else
        echo "Extension ${extension} already installed, update the values"
        if [ -e "${CLUSTER_FILES_DIR}/${extension}-data-values.yaml" ]
          then
            kubectl create secret generic ${extension}-data-values --from-file=values.yaml=${CLUSTER_FILES_DIR}/${extension}-data-values.yaml -n ${EXTENSIONS_MAP_NS[${extension}]} -o yaml --dry-run | kubectl replace -f-
          else
            echo -e "\n---"
            echo "/!\\ ${extension}-data-values.yaml file missing - No update /!\\"
            echo -e "---\n"
        fi
    fi
  done
}

if [[ $CREATE_CLUSTER -eq 0 && $INSTALL_EXTENSIONS -eq 0 ]]
then
  echo "Must specify --create-cluster or --install-extensions"
  exit 1
fi

if [ $CREATE_CLUSTER -eq 1 ]
then
  if [ $INSTALL_EXTENSIONS -eq 1 ]
  then
    usage
    exit 1
  else
    create_cluster
  fi
fi

if [ $INSTALL_EXTENSIONS -eq 1 ]
then
  if [ -e $HOME/.kube/config ]
  then
    mv $HOME/.kube/config $HOME/.kube/config.bak
  fi
  prepare_context
  install_prereq
  install_extensions
  if [ -e $HOME/.kube/config.bak ]
  then
    mv $HOME/.kube/config.bak $HOME/.kube/config
  fi
fi
