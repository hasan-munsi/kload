# kload: pick a Kubernetes cluster with the arrow keys.
# https://github.com/hasan-munsi/kload · MIT License
#
# Source this file from ~/.zshrc:
#   source "$(brew --prefix)/share/kload/kload.zsh"
#
#   kload          menu: ↑/↓ to move, Enter to load, Esc to cancel
#   kload <text>   load the cluster whose file, cluster or context name contains <text>
#   kload -        go back to the cluster this shell used before
#   kload -l       list without switching
#   kload -h       help
#
# Every kubeconfig file in ~/.kube (KLOAD_DIR) is added to KUBECONFIG, so kubectl, helm and k9s
# see every cluster at once. The current context is saved by kubectl in the first of those files
# (normally ~/.kube/config), so a switch applies to every terminal.

typeset -g KLOAD_VERSION=0.1.0

# Settings; set them before sourcing this file.
: ${KLOAD_DIR:=$HOME/.kube}          # where kubeconfig files live: config, *.yaml, *.yml
: ${KLOAD_PROD_MATCH=prod}           # text that marks a production cluster; empty for no warning

# The KUBECONFIG this shell had before kload, kept so that its files stay included.
typeset -g _KLOAD_BASE=${_KLOAD_BASE-$KUBECONFIG}

# Kubeconfig files kubectl could not read; left out of KUBECONFIG, since one bad file breaks kubectl.
typeset -gaU _KLOAD_BAD

_kload_files() {
  emulate -L zsh
  local -aU files
  local f
  for f in $KLOAD_DIR/config ${(s.:.)_KLOAD_BASE}; do
    [[ -f $f && ${_KLOAD_BAD[(Ie)$f]} -eq 0 ]] && files+=($f)
  done
  # Other YAML files may share the folder; only kubeconfig files have contexts.
  for f in $KLOAD_DIR/*.(yaml|yml)(N); do
    [[ ${_KLOAD_BAD[(Ie)$f]} -eq 0 && $(<$f) == *contexts:* ]] && files+=($f)
  done
  print -r -- ${(j.:.)files}
}

_kload_refresh() {
  local files="$(_kload_files)"
  [[ -n $files ]] && export KUBECONFIG=$files
}

_kload_refresh

_kload_help() {
  print -r -- "kload $KLOAD_VERSION: pick a Kubernetes cluster with the arrow keys

  kload          menu: ↑/↓ to move, Enter to load, Esc to cancel
  kload <text>   load the cluster whose file, cluster or context name contains <text>
  kload -        go back to the cluster this shell used before
  kload -l       list without switching
  kload -v       version

Kubeconfig files: $KLOAD_DIR/config and $KLOAD_DIR/*.yaml (KLOAD_DIR)
Production warning for names containing: ${KLOAD_PROD_MATCH:-(off)} (KLOAD_PROD_MATCH)"
}

# Arrow-key menu. Arguments: header, index to start on, then the items.
# Sets REPLY to the chosen index; returns 1 when cancelled.
_kload_menu() {
  emulate -L zsh
  local header=$1
  local -i sel=$2 n i top=1 height cols
  shift 2
  local -a items=("$@")
  n=${#items}
  cols=$(( ${COLUMNS:-80} - 4 )); (( cols < 20 )) && cols=20
  height=$(( ${LINES:-24} - 3 )); (( height < 3 )) && height=3; (( height > n )) && height=n
  local key rest hint

  trap 'printf "\e[?25h"' EXIT
  trap 'printf "\r\e[%dA\e[J\e[?25h" $(( height + 1 )); return 1' INT
  printf '\e[?25l'
  while true; do
    (( sel < top )) && top=$sel
    (( sel >= top + height )) && top=$(( sel - height + 1 ))

    printf '\e[2m%s\e[0m\n' "${header[1,cols]}"
    for (( i = top; i < top + height; i++ )); do
      if (( i == sel )); then
        printf '\e[7m> %s \e[0m\n' "${items[i][1,cols]}"
      else
        printf '  %s\n' "${items[i][1,cols]}"
      fi
    done
    hint="↑/↓ move · Enter load · Esc cancel"
    (( height < n )) && hint+="  ($sel/$n)"
    printf '\e[2m%s\e[0m' "$hint"

    read -sk1 key
    rest=
    [[ $key == $'\e' ]] && read -sk2 -t 0.05 rest
    printf '\r\e[%dA\e[J' $(( height + 1 ))   # back to the header line, erase the menu

    case "$key$rest" in
      $'\e[A'|$'\eOA'|k) (( sel = sel > 1 ? sel - 1 : n )) ;;
      $'\e[B'|$'\eOB'|j) (( sel = sel < n ? sel + 1 : 1 )) ;;
      $'\e[H'|$'\eOH'|g) sel=1 ;;
      $'\e[F'|$'\eOF'|G) sel=$n ;;
      $'\n'|$'\r')       REPLY=$sel; return 0 ;;
      $'\e'|q|$'\x03')   return 1 ;;
    esac
  done
}

kload() {
  emulate -L zsh
  case $1 in
    -h|--help)    _kload_help; return 0 ;;
    -v|--version) print -r -- "kload $KLOAD_VERSION"; return 0 ;;
  esac
  if (( ! $+commands[kubectl] )); then
    print -u2 "kload: kubectl is not installed (brew install kubernetes-cli)"; return 1
  fi
  _KLOAD_BAD=()
  _kload_refresh

  # One entry per context in each file, in KUBECONFIG order.
  local -a files clusters ctxs
  local f line out
  for f in ${(s.:.)KUBECONFIG}; do
    if ! out="$(kubectl --kubeconfig "$f" config view \
        -o jsonpath='{range .contexts[*]}{.name}{"\t"}{.context.cluster}{"\n"}{end}' 2>&1)"; then
      print -u2 "kload: skipped ${f/#$HOME/~}, which kubectl cannot read: ${${(@f)out}[1]#error: }"
      _KLOAD_BAD+=($f)
      continue
    fi
    for line in ${(f)out}; do
      [[ -n $line ]] || continue
      files+=(${f:t})
      ctxs+=("${line%%$'\t'*}")
      clusters+=("${${line#*$'\t'}:-${line%%$'\t'*}}")
    done
  done
  (( ${#_KLOAD_BAD} )) && _kload_refresh
  if (( ! ${#ctxs} )); then
    print -u2 "kload: no clusters found; put kubeconfig files in $KLOAD_DIR (config, *.yaml)"; return 1
  fi

  local current="$(kubectl config current-context 2>/dev/null)"
  local -i i choice=0 width=4 cwidth=7 showctx=0
  local -A seen
  for i in {1..${#ctxs}}; do
    (( ${#files[i]} > width )) && width=${#files[i]}
    (( ${#clusters[i]} > cwidth )) && cwidth=${#clusters[i]}
    # Two contexts for one cluster in one file would look identical: show context names then.
    (( ${+seen[${files[i]}/${clusters[i]}]} )) && showctx=1
    seen[${files[i]}/${clusters[i]}]=1
  done

  local header
  local -a rows
  if (( showctx )); then
    header=$(printf "  %-${width}s   %-${cwidth}s   %s" FILE CLUSTER CONTEXT)
  else
    header=$(printf "  %-${width}s   %s" FILE CLUSTER)
  fi
  for i in {1..${#ctxs}}; do
    if (( showctx )); then
      rows+=("$(printf "%-${width}s   %-${cwidth}s   %s" "${files[i]}" "${clusters[i]}" "${ctxs[i]}")")
    else
      rows+=("$(printf "%-${width}s   %s" "${files[i]}" "${clusters[i]}")")
    fi
    [[ ${ctxs[i]} == "$current" ]] && rows[i]+="  (current)"
  done

  if [[ $1 == -l ]]; then
    print -r -- "$header"
    printf '  %s\n' "${rows[@]}"
    return 0
  elif [[ $1 == - ]]; then
    if [[ -z $_KLOAD_PREVIOUS ]]; then
      print -u2 "kload: no previous cluster in this shell"; return 1
    fi
    choice=${ctxs[(i)$_KLOAD_PREVIOUS]}
    if (( choice > ${#ctxs} )); then
      print -u2 "kload: the previous context $_KLOAD_PREVIOUS no longer exists"; return 1
    fi
  elif [[ -z $1 ]]; then
    if [[ ! -t 0 || ! -t 1 ]]; then
      print -u2 "kload: the menu needs a terminal; use kload <text> or kload -l"; return 1
    fi
    local -i start=${ctxs[(i)$current]}
    (( start > ${#ctxs} )) && start=1
    _kload_menu "$header" $start "${rows[@]}" || return 0
    choice=$REPLY
  else
    local -a hits
    local -aU hitctxs
    for i in {1..${#ctxs}}; do
      if [[ ${(L)files[i]} == *${(L)1}* || ${(L)clusters[i]} == *${(L)1}* || ${(L)ctxs[i]} == *${(L)1}* ]]; then
        hits+=($i); hitctxs+=("${ctxs[i]}")
      fi
    done
    if (( ${#hits} == 0 )); then
      print -u2 "kload: nothing matches '$1' (kload -l lists them)"; return 1
    elif (( ${#hitctxs} > 1 )); then
      print -u2 "kload: '$1' matches several clusters:"
      for i in $hits; do print -u2 "  ${files[i]}   ${clusters[i]}   (${ctxs[i]})"; done
      return 1
    fi
    choice=${hits[1]}
  fi

  local ctx=${ctxs[choice]}
  kubectl config use-context "$ctx" >/dev/null || return 1
  [[ $ctx != "$current" && -n $current ]] && typeset -g _KLOAD_PREVIOUS=$current
  local ns="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)"
  local green= red= dim= bold= off=
  [[ -t 1 ]] && green=$'\e[32m' red=$'\e[31m' dim=$'\e[2m' bold=$'\e[1m' off=$'\e[0m'
  print -r -- "${green}Loaded${off} ${bold}${clusters[choice]}${off} from ${files[choice]} ${dim}(context $ctx, namespace ${ns:-default})${off}"

  # kubectl uses the first definition of a context name; say so when that is in another file.
  local first=${files[${ctxs[(i)$ctx]}]}
  if [[ $first != ${files[choice]} ]]; then
    print -r -- "${dim}kubectl reads context $ctx from $first, which comes first in KUBECONFIG.${off}"
  fi

  local m=${(L)KLOAD_PROD_MATCH}
  if [[ -n $m && ( ${(L)ctx} == *$m* || ${(L)clusters[choice]} == *$m* || ${(L)files[choice]} == *$m* ) ]]; then
    print -r -- "${red}This is a production cluster.${off}"
  fi
}

# Tab completion of context names, when the completion system is loaded.
_kload() { compadd -- ${(f)"$(kubectl config get-contexts -o name 2>/dev/null)"} }
if (( ${+functions[compdef]} )); then compdef _kload kload; fi
