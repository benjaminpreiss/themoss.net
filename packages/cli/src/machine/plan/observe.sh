  discover)
    [[ $# == 3 ]] || usage
    target=$1 disk=$2 record=$3
    [[ $disk == /dev/* ]] || fail 'expected a whole /dev disk'
    [[ ! -e $record && ! -L $record ]] || fail 'refusing to replace record'
    actual=$(probe "$target")
    selected=$(jq -ec --arg disk "$disk" '[.disks[] | select(.path == $disk and .type == "disk")] | if length == 1 then .[0] else error("disk not unique whole disk") end' <<<"$actual")
    jq -n --arg target "$target" --argjson p "$actual" --argjson disk "$selected" '{target:$target,arch:$p.arch,boot:$p.boot,nic:$p.nic,mac:$p.mac,disk:$disk}' >"$record"
    echo "Private machine record created: $record (verify with provider console)"
    ;;
  preflight)
    [[ $# == 1 ]] || usage
    check "$1"
    ;;
