# Operator-local defaults. The Git root, not $HOME or the current subdirectory,
# owns .moss. The caller can always pass explicit paths instead.
moss_repo_root() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || fail 'run from the consumer Git checkout or pass explicit paths'
  [[ -d $root && ! -L $root ]] || fail 'unsafe consumer Git checkout'
  realpath "$root"
}
moss_store() {
  local root
  root=$(moss_repo_root) || return
  [[ -z $(git -C "$root" ls-files -- .moss) ]] || fail 'tracked .moss files; remove them from Git before planning'
  if ! git -C "$root" check-ignore -q --no-index -- .moss/; then
    fail "add .moss/ to $root/.gitignore (and commit that change) before using default storage"
  fi
  [[ ! -L $root/.moss ]] || fail 'linked .moss directory'
  printf '%s/.moss\n' "$root"
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
  [[ ! -L $dir/latest && ( ! -e $dir/latest || ( -f $dir/latest && $(stat -c %a "$dir/latest") == 600 ) ) ]] || fail 'unsafe latest-plan reference'
  tmp=$(mktemp "$dir/.latest.XXXXXXXX")
  printf '%s\n' "$plan" >"$tmp"
  chmod 600 "$tmp"
  mv -fT -- "$tmp" "$dir/latest"
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
  private_file "$dir/latest"
  IFS= read -r plan <"$dir/latest" || fail 'empty latest-plan reference'
  [[ -n $plan ]] || fail 'empty latest-plan reference'
  private_file "$plan"
  [[ $(jq -er .target "$plan") == "$(basename "$dir")" ]] || fail 'latest plan target differs from directory'
  printf '%s\n' "$plan"
}
