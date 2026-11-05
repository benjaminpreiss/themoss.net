# @cmd Create operator-local .moss in the current directory or Git ancestor
init() {
  local workspace store
  workspace=$(moss_repo_root) || return
  store=$workspace/.moss
  [[ ! -L $store ]] || fail 'refusing linked .moss directory'
  if [[ ! -e $store ]]; then mkdir -m 700 -- "$store"; fi
  [[ -d $store && $(stat -c %a "$store") == 700 ]] || fail '.moss must be a mode-700 directory'
  printf 'Initialized %s (operator-local; no configuration, plan or installer run).\n' "$store"
  if git -C "$workspace" rev-parse --show-toplevel >/dev/null 2>&1; then
    [[ -z $(git -C "$workspace" ls-files -- .moss) ]] || fail 'remove tracked .moss files from Git before using moss'
    if ! git -C "$workspace" check-ignore -q --no-index -- .moss/; then
      printf 'Before planning, add .moss/ to %s/.gitignore and commit the ignore rule.\n' "$workspace" >&2
    fi
  else
    printf 'Not in a Git checkout. If this directory later enters Git, ignore .moss/ before using moss.\n' >&2
  fi
}
