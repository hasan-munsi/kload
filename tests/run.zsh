#!/usr/bin/env zsh
# Tests for kload, against throwaway kubeconfig files (no cluster needed, only kubectl).
#   zsh tests/run.zsh

emulate -L zsh
cd ${0:A:h:h}

typeset -i passed=0 failed=0
work=$(mktemp -d)
trap 'rm -rf $work' EXIT

kubeconfig() {  # file, then context:cluster pairs; the first context is current
  local file=$1 pair cluster; shift
  {
    print "apiVersion: v1\nkind: Config\ncurrent-context: ${1%%:*}\nclusters:"
    for cluster in ${(u)@#*:}; do print -- "- name: $cluster\n  cluster:\n    server: https://127.0.0.1:6443"; done
    print "users:\n- name: tester\n  user:\n    token: not-a-real-token\ncontexts:"
    for pair; do print -- "- name: ${pair%%:*}\n  context:\n    cluster: ${pair#*:}\n    user: tester"; done
  } > $file
}

pass() { (( passed++ )); print "ok    $1" }
fail() {
  local nl=$'\n'
  (( failed++ )); print -r -- "FAIL  $1"
  [[ -n $2 ]] && print -r -- "      ${2//$nl/$nl      }"
}

# check <description> <expected text> <command...>: runs the command in this shell, so state carries over.
check() {
  local description=$1 expected=$2; shift 2
  "$@" > $work/out 2>&1
  local output="$(<$work/out)"
  if [[ $output == *$expected* ]]; then pass $description
  else fail $description "expected: $expected"$'\n'"got:"$'\n'"$output"; fi
}

# refute <description> <text that must not appear> <command...>
refute() {
  local description=$1 unexpected=$2; shift 2
  "$@" > $work/out 2>&1
  local output="$(<$work/out)"
  if [[ $output != *$unexpected* ]]; then pass $description
  else fail $description "$output"; fi
}

mkdir -p $work/kube
kubeconfig $work/kube/config local-ctx:docker-desktop
kubeconfig $work/kube/staging.yaml staging-ctx:eks-staging
kubeconfig $work/kube/prod.yml prod-ctx:gke-prod prod-readonly:gke-prod
print "not yaml" > $work/kube/notes.txt
print "settings:\n  theme: dark" > $work/kube/other-tool.yaml   # YAML that is not a kubeconfig

unset KUBECONFIG _KLOAD_BASE
KLOAD_DIR=$work/kube
source ./kload.zsh

check  "KUBECONFIG lists config first, then the kubeconfig files" \
  "$work/kube/config:$work/kube/prod.yml:$work/kube/staging.yaml" print -r -- $KUBECONFIG
refute "other YAML files are left out" "other-tool" print -r -- $KUBECONFIG
check  "version" "kload $KLOAD_VERSION" kload -v
check  "help" "kload <text>" kload -h
check  "list shows the file, then the cluster" "staging.yaml   eks-staging" kload -l
check  "list marks the current cluster" "(current)" kload -l
check  "list shows contexts when one file has two for one cluster" "prod-readonly" kload -l
check  "load by file name" "Loaded eks-staging from staging.yaml" kload staging
check  "the switch is saved by kubectl" "staging-ctx" kubectl config current-context
check  "go back with kload -" "Loaded docker-desktop" kload -
check  "production warning" "This is a production cluster." kload prod-ctx
check  "several matches change nothing" "matches several clusters" kload gke
check  "  and the current context stays" "prod-ctx" kubectl config current-context
check  "nothing matches" "nothing matches 'nope'" kload nope
check  "the menu needs a terminal" "the menu needs a terminal" kload </dev/null
KLOAD_PROD_MATCH=
check  "production warning can be turned off" "Loaded gke-prod" kload prod-readonly
refute "  so no warning is shown" "production" kload prod-readonly
KLOAD_PROD_MATCH=prod

# A broken kubeconfig is reported and left out, so kubectl keeps working.
print "contexts: [unclosed" > $work/kube/broken.yaml
_kload_refresh
check  "a broken file is reported" "skipped" kload -l
refute "  and left out of KUBECONFIG" "broken" print -r -- $KUBECONFIG
check  "  so kubectl still works" "prod-readonly" kubectl config current-context
rm $work/kube/broken.yaml

# A KUBECONFIG set before kload is kept.
KUBECONFIG=$work/kube/notes.txt zsh -c "unset _KLOAD_BASE; KLOAD_DIR=$work/kube; source ./kload.zsh; print -r -- \$KUBECONFIG" > $work/kept
check  "an existing KUBECONFIG file is kept" "$work/kube/config:$work/kube/notes.txt:" cat $work/kept

check  "bin/kload explains how to set it up" "source " ./bin/kload
check  "bin/kload --version" "kload $KLOAD_VERSION" ./bin/kload --version

print "\n$passed passed, $failed failed"
(( failed == 0 ))
