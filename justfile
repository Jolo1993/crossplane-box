set export
set shell := ["bash", "-uc"]
                                 
yaml          := justfile_directory() + "/yaml"
apps          := justfile_directory() + "/apps"
              
browse        := if os() == "linux" { "xdg-open "} else { "open" }
copy          := if os() == "linux" { "xsel -ib"} else { "pbcopy" }
replace       := if os() == "linux" { "sed -i"} else { "sed -i '' -e" }
              
argocd_port   := "30950"                                 
flux_repo := "/home/jtl/home_projects/controll-plane_test/Mgmt-Cluster-demo"
my_project_repo := "/home/jtl/home_projects/controll-plane_test/crossplane-box/apps"
# this list of available targets
# targets marked with * are main targets
default:
  just --list --unsorted

# * setup kind cluster with crossplane, ArgoCD and launch argocd in browser
setup: _replace_repo_user setup_kind setup_crossplane setup_flux bootstrap_capi 

# replace repo user
_replace_repo_user:
  #!/usr/bin/env bash
  if grep -qw "Piotr1215" bootstrap.yaml && grep -qw "Piotr1215" {{apps}}/application_crossplane_resources.yaml; then
    if [[ -z "${GITHUB_USER}" ]]; then
      echo "Please set GITHUB_USER variable with your user name"
      exit 1
    fi
    {{replace}} "s/Piotr1215/${GITHUB_USER}/g" bootstrap.yaml
    {{replace}} "s/Piotr1215/${GITHUB_USER}/g" {{apps}}/application_crossplane_resources.yaml
  fi

# setup kind cluster
setup_kind cluster_name='control-plane':
  #!/usr/bin/env bash
  set -euo pipefail

  echo "Creating kind cluster - {{cluster_name}}"
  envsubst < kind-config.yaml | kind create cluster --config - --wait 3m
  kind get kubeconfig --name {{cluster_name}}
  kubectl config use-context kind-{{cluster_name}}

# setup universal crossplane
setup_crossplane xp_namespace='crossplane-system':
  #!/usr/bin/env bash
  if kubectl get namespace {{xp_namespace}} > /dev/null 2>&1; then
    echo "Namespace {{xp_namespace}} already exists"
  else
    echo "Creating namespace {{xp_namespace}}"
    kubectl create namespace {{xp_namespace}}
  fi

  echo "Installing crossplane version"
  helm repo add crossplane-stable https://charts.crossplane.io/stable
  helm repo update
  helm upgrade --install crossplane --namespace {{xp_namespace}} crossplane-stable/crossplane --devel
  kubectl wait --for condition=Available=True --timeout=300s deployment/crossplane --namespace {{xp_namespace}}

setup_flux:
  #!/usr/bin/bash
  if [[ -z "${GITHUB_USER}" ]] || [[ -z "${GITHUB_TOKEN}" ]]; then
  echo "GITHUB_USER or GITHUB_TOKEN variable is missing"
  exit 1
  fi
  pre_flight=$(bash -c 'flux check --pre' 2>&1)
  exit_code=$?
  if [ $exit_code -eq 0 ]; then
      flux bootstrap github --owner=$GITHUB_USER --repository=crossplane-box --branch=main --path=./apps --personal
  else
      echo $exit_code
  fi

bootstrap_capi cluster_name='control-plane':
  export KUBECONFIG=$(kind get kubeconfig --name {{cluster_name}})
  export CLUSTER_TOPOLOGY=true
  export MachinePool=true
  clusterctl init --infrastructure docker


# sync apps locally
sync:
  #!/usr/bin/env bash
  export argo_pw=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
  yes | argocd login localhost:{{argocd_port}} --username admin --password "${argo_pw}"
  argocd app sync bootstrap --prune --local ./apps 

# * delete KIND cluster
teardown:
  echo "Delete KIND cluster"
  kind delete clusters control-plane
