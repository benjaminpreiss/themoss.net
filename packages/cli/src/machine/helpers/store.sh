# Operator-local defaults. Inside Git, use the worktree root; elsewhere use
# the current directory. Neither case stores machine data in $HOME or the store.
moss_repo_root() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$(pwd -P)
  [[ -d $root && ! -L $root ]] || fail 'unsafe operator directory'
  realpath "$root"
}
moss_check_workspace() {
  local root=$1
  [[ ! -L $root/.moss ]] || fail 'linked .moss directory'
  [[ ! -e $root/.moss ]] && return 0
  [[ -d $root/.moss && $(stat -c %a "$root/.moss") == 700 ]] || fail '.moss must be a mode-700 directory'
  if git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then
    [[ -z $(git -C "$root" ls-files -- .moss) ]] || fail 'tracked .moss files; remove them from Git'
    git -C "$root" check-ignore -q --no-index -- .moss/ || fail "add .moss/ to $root/.gitignore and commit the rule before planning"
  fi
}
moss_store() {
  local root
  root=$(moss_repo_root) || return
  moss_check_workspace "$root"
  [[ -d $root/.moss ]] || fail "run 'moss init' in $root before planning"
  printf '%s/.moss\n' "$root"
}
# Check every operator-owned path, including explicit overrides outside .moss.
# Consumer Git sources and executable hooks are not operator state.
moss_private_path() {
  local path=$1 parent repo relative workspace
  workspace=$(moss_repo_root) || return
  moss_check_workspace "$workspace"
  [[ $path == /* && $path != *..* ]] || fail "expected absolute operator file path: $path"
  parent=$(dirname "$path")
  [[ -d $parent && ! -L $parent && ! -L $path && $(realpath -m "$parent") == "$(realpath "$parent")" ]] || fail "unsafe operator file path: $path"
  repo=$(git -C "$parent" rev-parse --show-toplevel 2>/dev/null) || return 0
  moss_check_workspace "$repo"
  [[ $path == "$repo/"* ]] || fail 'operator path outside detected Git root'
  relative=${path#"$repo/"}
  [[ -z $(git -C "$repo" ls-files -- "$relative") ]] || fail "tracked operator file: $path"
  git -C "$repo" check-ignore -q --no-index -- "$relative" || fail "operator file must be Git-ignored: $path"
}
moss_private_dir() {
  local dir=$1 repo relative workspace
  workspace=$(moss_repo_root) || return
  moss_check_workspace "$workspace"
  [[ $dir == /* && $dir != *..* && -d $dir && ! -L $dir && $(realpath -m "$dir") == "$(realpath "$dir")" ]] || fail "unsafe operator directory: $dir"
  repo=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
  moss_check_workspace "$repo"
  [[ $dir == "$repo/"* ]] || fail 'operator directory outside detected Git root'
  relative=${dir#"$repo/"}
  [[ -z $(git -C "$repo" ls-files -- "$relative") ]] || fail "tracked operator directory: $dir"
  git -C "$repo" check-ignore -q --no-index -- "$relative/" || fail "operator directory must be Git-ignored: $dir"
}
moss_target_store() {
  local target=$1
  [[ $target =~ ^root@[a-zA-Z0-9_.:-]+$ ]] || fail 'invalid SSH target'
  local store
  store=$(moss_store) || return
  printf '%s/%s\n' "$store" "$target"
}
moss_prepare_store() {
  local dir=$1 root=${1%/.moss/*}
  [[ ! -L $root/.moss && ! -L $dir && ! -L $dir/plans ]] || fail 'linked .moss path'
  mkdir -p -m 700 -- "$dir/plans"
  [[ $(stat -c %a "$root/.moss") == 700 && $(stat -c %a "$dir") == 700 && $(stat -c %a "$dir/plans") == 700 ]] || fail '.moss directories must be mode 700'
}
moss_new_plan_path() {
  local dir=$1 name
  name="$(date -u +%Y%m%dT%H%M%S)-$RANDOM-$RANDOM.json"
  printf '%s/plans/%s\n' "$dir" "$name"
}
moss_publish_latest() {
  local dir=$1 plan=$2 tmp
  [[ ! -e $dir/latest || -L $dir/latest ]] || fail 'latest must be a symlink'
  # Create the replacement beside latest, then rename it atomically. The plan
  # remains an immutable mode-600 file; the symlink itself has no access mode.
  tmp=$(mktemp -d "$dir/.latest.XXXXXXXX")
  ln -s -- "$plan" "$tmp/latest"
  mv -fT -- "$tmp/latest" "$dir/latest"
  rmdir -- "$tmp"
}
moss_latest_plan() {
  local requested=${1:-} dir store latest plan found='' count=0
  if [[ -n $requested ]]; then
    dir=$(moss_target_store "$requested") || return
  else
    store=$(moss_store) || return
    [[ -d $store && ! -L $store ]] || fail 'no .moss plans; pass an explicit plan'
    for latest in "$store"/*/latest; do
      [[ -e $latest || -L $latest ]] || continue
      ((count += 1))
      found=${latest%/latest}
    done
    ((count == 1)) || fail 'no unique latest plan; pass --target root@HOST or an explicit plan'
    dir=$found
  fi
  [[ -d $dir && ! -L $dir && $(stat -c %a "$dir") == 700 ]] || fail 'unsafe target plan directory'
  [[ -L $dir/latest ]] || fail 'latest must be a symlink to a plan'
  plan=$(readlink -- "$dir/latest") || fail 'cannot read latest-plan symlink'
  private_file "$plan"
  [[ $(jq -er .target "$plan") == "$(basename "$dir")" ]] || fail 'latest plan target differs from directory'
  printf '%s\n' "$plan"
}
