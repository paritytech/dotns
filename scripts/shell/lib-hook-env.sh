#!/usr/bin/env bash
# Shared PATH augmentation for the git hooks. Sourced (never executed) by both
# pre-commit and pre-push so they work under GUI git clients (GitHub Desktop and
# similar) that spawn shells with a minimal environment, and so a system
# `/usr/bin/python3` without `tomllib` never outranks the pyenv shims. It mutates
# and exports PATH using move-to-front semantics: any existing occurrence of a dir
# is stripped before prepending, guaranteeing it sits at the head of PATH.

_prepend_path() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  local cleaned=":${PATH:-}:"
  cleaned="${cleaned//:$dir:/:}"
  cleaned="${cleaned#:}"
  cleaned="${cleaned%:}"
  if [ -z "$cleaned" ]; then
    PATH="$dir"
  else
    PATH="$dir:$cleaned"
  fi
}

# Homebrew (Apple Silicon and Intel) and Foundry.
_prepend_path "/opt/homebrew/bin"
_prepend_path "/usr/local/bin"
_prepend_path "$HOME/.foundry/bin"

# Pyenv shims dispatch to the active Python version; TOML validation needs
# tomllib, which ships in Python 3.11+.
_prepend_path "$HOME/.pyenv/shims"

# Nvm: resolve the default alias to its installed version; fall back to the
# newest installed version when no default is pinned.
if [ -d "$HOME/.nvm/versions/node" ]; then
  _nvm_default=""
  if [ -r "$HOME/.nvm/alias/default" ]; then
    _nvm_default="$(tr -d '[:space:]' <"$HOME/.nvm/alias/default")"
  fi
  _nvm_bin=""
  if [ -n "$_nvm_default" ]; then
    for _candidate in "$HOME/.nvm/versions/node/v${_nvm_default}"*/bin; do
      [ -d "$_candidate" ] || continue
      _nvm_bin="$_candidate"
    done
  fi
  if [ -z "$_nvm_bin" ]; then
    for _candidate in "$HOME/.nvm/versions/node"/*/bin; do
      [ -d "$_candidate" ] || continue
      _nvm_bin="$_candidate"
    done
  fi
  [ -n "$_nvm_bin" ] && _prepend_path "$_nvm_bin"
  unset _nvm_default _nvm_bin _candidate
fi

export PATH
unset -f _prepend_path
