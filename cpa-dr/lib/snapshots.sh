#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2094
# Native snapshots: private staging, complete manifest validation, then publication.

cpa_snapshot_dir() {
    cpa_id_valid "${1-}" || { cpa_fail '快照ID无效。'; return 1; }
    printf '%s/snapshots/%s\n' "$CPA_STATE_DIR" "$1"
}

_cpa_tree_safe() {
    local root=$1 mode=${2:-source} list entry relative device
    cpa_path_validate "$root" || return 1
    [[ -e $root ]] || return 0
    list=$(mktemp "$CPA_STATE_DIR/tmp/tree.XXXXXXXX") || return 1
    device=$(stat -c %d -- "$root") || { rm -f -- "$list"; return 1; }
    if ! find -P "$root" -print0 > "$list"; then rm -f -- "$list"; return 1; fi
    while IFS= read -r -d '' entry; do
        relative=${entry#"$root"}
        if [[ $relative == *\\* || $relative =~ [[:cntrl:]] || ( ! -f $entry && ! -d $entry ) || -L $entry ]]; then rm -f -- "$list"; cpa_fail '数据中含控制字符、链接或特殊文件。'; return 1; fi
        # In-place restore must not write through another alias of a live file.
        # Source hardlinks remain supported: snapshot copying breaks the links.
        if [[ $mode == restore && -f $entry && $(stat -c %h -- "$entry") != 1 ]]; then rm -f -- "$list"; cpa_fail '恢复目标含硬链接文件。'; return 1; fi
        if [[ $(stat -c %d -- "$entry") != "$device" ]]; then rm -f -- "$list"; cpa_fail '数据树不可跨文件系统挂载点。'; return 1; fi
    done < "$list"
    rm -f -- "$list"
}

_cpa_payload_path() {
    local path=${1-} part
    [[ $path == payload || $path == payload/* ]] || return 1
    [[ $path != */ && $path != *\\* && ! $path =~ [[:cntrl:]] && $path != *//* ]] || return 1
    local -a parts=()
    IFS=/ read -r -a parts <<< "$path"
    for part in "${parts[@]}"; do [[ -n $part && $part != . && $part != .. ]] || return 1; done
}

_cpa_json_file() {
    local path=$1
    [[ $path != *.json ]] || jq -e 'true' "$path" >/dev/null || { cpa_fail 'JSON数据无效。'; return 1; }
}

_cpa_flush_tree() {
    # GNU sync -f uses syncfs, covering file content and directory entries together.
    sync -f "$1" || return 1
}

_cpa_snapshot_validate_dir() {
    local directory=$1 manifest="$1/manifest.json" max total=0 count=0 entry size hash path id kind exists name row actual expected tmp parent
    [[ -f $manifest && ! -L $manifest && $(stat -c %s -- "$manifest") -le 33554432 ]] || { cpa_fail '缺失或超量清单。'; return 1; }
    max=$(jq -r .max_snapshot_bytes "$CPA_STATE_DIR/config.json") || return 1
    jq -e --argjson max "$max" '
      type=="object" and .format_version==1 and (.id|type=="string") and (.node_id|type=="string") and
      (.node_role=="primary" or .node_role=="backup") and (.epoch|type=="number" and floor==. and .>=0) and
      (.purpose|type=="string") and (.created_at|type=="string") and
      (.total_bytes|type=="number" and floor==. and .>=0 and .<=$max) and (.file_count|type=="number" and .>=0 and .<=100000) and
      (.items|type=="array" and length>0 and length<=128) and (.files|type=="array" and length<=100000) and
      (.directories|type=="array" and length<=100000) and
      ([.items[].name]|length == (unique|length)) and ([.files[].path]|length == (unique|length)) and
      (.directories|length == (unique|length)) and
      all(.files[]; (.path|type=="string") and (.size|type=="number" and floor==. and .>=0 and .<=$max) and (.sha256|type=="string" and test("^[a-f0-9]{64}$"))) and
      all(.items[]; (.name|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")) and (.kind=="file" or .kind=="directory" or .kind=="sqlite") and (.existed|type=="boolean")) and
      all(.directories[];type=="string" and (explode|all(.[];.>=32 and .!=92 and .!=127)))
    ' "$manifest" >/dev/null || { cpa_fail '快照清单格式无效。'; return 1; }
    id=$(jq -r .id "$manifest") && name=$(jq -r .node_id "$manifest") || return 1
    cpa_id_valid "$id" && cpa_id_valid "$name" || return 1
    _cpa_tree_safe "$directory" || return 1
    tmp=$(mktemp -d "$CPA_STATE_DIR/tmp/verify.XXXXXXXX") || return 1
    expected=$tmp/expected; actual=$tmp/actual
    printf 'manifest.json\n' > "$expected" || { rm -rf -- "$tmp"; return 1; }
    while IFS= read -r path; do
        _cpa_payload_path "$path" && [[ -d $directory/$path && ! -L $directory/$path ]] || { rm -rf -- "$tmp"; cpa_fail '清单目录路径无效或目录缺失。'; return 1; }
        printf '%s\n' "$path" >> "$expected"
    done < <(jq -r '.directories[]' "$manifest")
    while IFS= read -r row; do
        path=$(jq -r .path <<< "$row") && size=$(jq -r .size <<< "$row") && hash=$(jq -r .sha256 <<< "$row") || { rm -rf -- "$tmp"; return 1; }
        _cpa_payload_path "$path" && [[ $path == payload/* && -f $directory/$path && ! -L $directory/$path ]] || { rm -rf -- "$tmp"; cpa_fail '清单文件路径无效或文件缺失。'; return 1; }
        [[ $(stat -c %h -- "$directory/$path") == 1 ]] || { rm -rf -- "$tmp"; cpa_fail '快照文件为硬链接。'; return 1; }
        [[ $(stat -c %s -- "$directory/$path") == "$size" ]] || { rm -rf -- "$tmp"; cpa_fail '快照文件大小不符。'; return 1; }
        [[ $(sha256sum -- "$directory/$path" | cut -d ' ' -f1) == "$hash" ]] || { rm -rf -- "$tmp"; cpa_fail '快照SHA256不符。'; return 1; }
        if [[ $(jq -r .purpose "$manifest") != rollback ]] && ! _cpa_json_file "$directory/$path"; then rm -rf -- "$tmp"; return 1; fi
        total=$((total+size)); count=$((count+1))
        printf '%s\n' "$path" >> "$expected"
    done < <(jq -c '.files[]' "$manifest")
    if ! find -P "$directory" -mindepth 1 -printf '%P\n' > "$actual" || ! LC_ALL=C sort "$actual" -o "$actual" || ! LC_ALL=C sort "$expected" -o "$expected" || ! cmp -s -- "$expected" "$actual"; then rm -rf -- "$tmp"; cpa_fail '归档包含未登记、重复或缺失条目。'; return 1; fi
    [[ $total == "$(jq -r .total_bytes "$manifest")" && $count == "$(jq -r .file_count "$manifest")" && $total -le $max ]] || { rm -rf -- "$tmp"; cpa_fail '快照合计大小或数量不符。'; return 1; }
    while IFS= read -r row; do
        name=$(jq -r .name <<< "$row") && kind=$(jq -r .kind <<< "$row") && exists=$(jq -r .existed <<< "$row") || { rm -rf -- "$tmp"; return 1; }
        [[ -d $directory/payload/$name ]] || { rm -rf -- "$tmp"; return 1; }
        if [[ $kind != directory ]]; then
            [[ $exists == false || -f $directory/payload/$name/data ]] || { rm -rf -- "$tmp"; return 1; }
            [[ $(find "$directory/payload/$name" -mindepth 1 | wc -l) == "$([[ $exists == true ]] && printf 1 || printf 0)" ]] || { rm -rf -- "$tmp"; cpa_fail '单文件来源含额外内容。'; return 1; }
        fi
        if [[ $(jq -r .purpose "$manifest") != rollback && $exists == true ]]; then
            if [[ $kind == sqlite ]]; then
                [[ $(sqlite3 -readonly "$directory/payload/$name/data" 'PRAGMA quick_check;') == ok ]] || { rm -rf -- "$tmp"; cpa_fail 'SQLite副本无效。'; return 1; }
            elif [[ $kind == file ]]; then
                path=$(jq -r .original_path <<< "$row") || { rm -rf -- "$tmp"; return 1; }
                if [[ $path == *.json ]] && ! jq -e true "$directory/payload/$name/data" >/dev/null; then rm -rf -- "$tmp"; cpa_fail 'JSON副本无效。'; return 1; fi
            fi
        fi
    done < <(jq -c '.items[]' "$manifest")
    # Every payload entry must belong to a declared source; ancestors are explicit.
    if ! jq -e '. as $m | [.files[].path,.directories[]] | all(.[]; . as $path | $path=="payload" or any($m.items[]; .name as $name | $path==("payload/"+$name) or ($path|startswith("payload/"+$name+"/"))))' "$manifest" >/dev/null; then rm -rf -- "$tmp"; cpa_fail 'payload来源标签未登记。'; return 1; fi
    rm -rf -- "$tmp"
}

_cpa_snapshot_publish() {
    local directory=$1 id destination
    _cpa_snapshot_validate_dir "$directory" || return 1
    id=$(jq -r .id "$directory/manifest.json") || return 1
    destination=$(cpa_snapshot_dir "$id") || return 1
    [[ ! -e $destination ]] || { cpa_fail '快照ID已存在。'; return 1; }
    _cpa_flush_tree "$directory" || return 1
    mv -T -- "$directory" "$destination" && sync -- "$CPA_STATE_DIR/snapshots" || return 1
    cat -- "$destination/manifest.json"
}

_cpa_snapshot_create() {
    local purpose=$1 epoch=$2 config=${3:-$CPA_STATE_DIR/config.json} stage id created max total=0 count=0 row path name kind existed destination size hash node role entry rel escaped
    [[ $purpose =~ ^[a-z][a-z_-]{0,31}$ && $epoch =~ ^[0-9]{1,12}$ ]] || return 1
    cpa_config_validate "$config" || return 1
    [[ $(jq '.sources|length' "$config") -gt 0 ]] || { cpa_fail '尚未配置备份内容。'; return 1; }
    stage=$(mktemp -d "$CPA_STATE_DIR/tmp/snapshot.XXXXXXXX") || return 1
    id="$(date -u +%Y%m%dT%H%M%SZ)_$(cpa_uuid)"; created=$(cpa_now)
    mkdir -- "$stage/payload" || { rm -rf -- "$stage"; return 1; }
    : > "$stage/items.jsonl"; : > "$stage/files.jsonl"; : > "$stage/dirs.jsonl"
    max=$(jq -r .max_snapshot_bytes "$config") || { rm -rf -- "$stage"; return 1; }
    while IFS= read -r row; do
        path=$(jq -r .path <<< "$row") && name=$(jq -r .name <<< "$row") && kind=$(jq -r .kind <<< "$row") || { rm -rf -- "$stage"; return 1; }
        existed=true; [[ -e $path ]] || existed=false
        [[ $purpose == rollback || $existed == true ]] || { rm -rf -- "$stage"; cpa_fail '备份来源不存在。'; return 1; }
        if [[ $kind == auto ]]; then [[ -d $path ]] && kind=directory || kind='file'; fi
        destination=$stage/payload/$name
        if [[ $existed == true ]]; then
            _cpa_tree_safe "$path" || { rm -rf -- "$stage"; return 1; }
            size=$(find "$path" -type f -printf '%s\n' | awk '{total+=$1} END{printf "%.0f\n",total}') || { rm -rf -- "$stage"; return 1; }
            [[ $size -le $max ]] || { rm -rf -- "$stage"; cpa_fail '来源超出快照容量上限。'; return 1; }
        fi
        if [[ $kind == directory && $existed == true ]]; then
            if ! cp -R --preserve=mode,timestamps --reflink=auto --no-dereference -- "$path" "$destination"; then rm -rf -- "$stage"; return 1; fi
        else
            mkdir -- "$destination" || { rm -rf -- "$stage"; return 1; }
            if [[ $existed == true ]]; then
                if [[ $kind == sqlite && $purpose != rollback ]]; then
                    # sqlite3 dot-command quoting is not SQL string quoting.
                    escaped=${destination//\"/\\\"}
                    if ! sqlite3 "$path" ".backup \"$escaped/data\""; then rm -rf -- "$stage"; cpa_fail 'SQLite一致性备份失败。'; return 1; fi
                elif ! cp --preserve=mode,timestamps --reflink=auto -- "$path" "$destination/data"; then rm -rf -- "$stage"; return 1; fi
                if [[ $purpose != rollback && $kind != sqlite ]] && ! _cpa_json_file "$path"; then rm -rf -- "$stage"; return 1; fi
            fi
        fi
        jq -cn --arg name "$name" --arg kind "$kind" --arg path "$path" --argjson existed "$existed" '{name:$name,kind:$kind,original_path:$path,existed:$existed}' >> "$stage/items.jsonl" || { rm -rf -- "$stage"; return 1; }
    done < <(jq -c '.sources[]' "$config")
    _cpa_tree_safe "$stage/payload" || { rm -rf -- "$stage"; return 1; }
    if ! find "$stage/payload" -type f -print0 > "$stage/entries"; then rm -rf -- "$stage"; return 1; fi
    while IFS= read -r -d '' entry; do
        rel=${entry#"$stage/"}; size=$(stat -c %s -- "$entry") && hash=$(sha256sum -- "$entry" | cut -d ' ' -f1) || { rm -rf -- "$stage"; return 1; }
        total=$((total+size)); count=$((count+1))
        [[ $total -le $max && $count -le 100000 ]] || { rm -rf -- "$stage"; cpa_fail '快照超过容量或文件数量限制。'; return 1; }
        jq -cn --arg path "$rel" --argjson size "$size" --arg sha "$hash" '{path:$path,size:$size,sha256:$sha}' >> "$stage/files.jsonl" || { rm -rf -- "$stage"; return 1; }
    done < "$stage/entries"
    if ! find "$stage/payload" -type d -print0 > "$stage/entries"; then rm -rf -- "$stage"; return 1; fi
    while IFS= read -r -d '' entry; do jq -Rn --arg path "${entry#"$stage/"}" '$path' >> "$stage/dirs.jsonl" || { rm -rf -- "$stage"; return 1; }; done < "$stage/entries"
    node=$(jq -r .node_id "$config") && role=$(jq -r .node_role "$config") || { rm -rf -- "$stage"; return 1; }
    if ! jq -n --arg id "$id" --arg node "$node" --arg role "$role" --arg purpose "$purpose" --arg created "$created" --argjson epoch "$epoch" --argjson total "$total" --argjson count "$count" --slurpfile items "$stage/items.jsonl" --slurpfile files "$stage/files.jsonl" --slurpfile directories "$stage/dirs.jsonl" '{format_version:1,id:$id,node_id:$node,node_role:$role,epoch:$epoch,purpose:$purpose,created_at:$created,total_bytes:$total,file_count:$count,items:$items,files:$files,directories:$directories}' > "$stage/manifest.json"; then rm -rf -- "$stage"; return 1; fi
    rm -f -- "$stage/items.jsonl" "$stage/files.jsonl" "$stage/dirs.jsonl" "$stage/entries"
    if ! _cpa_snapshot_publish "$stage"; then rm -rf -- "$stage"; return 1; fi
}
cpa_snapshot_create() { _cpa_snapshot_create "$1" "$2"; }

cpa_snapshot_verify() {
    local directory
    directory=$(cpa_snapshot_dir "$1") || return 1
    [[ -d $directory && ! -L $directory ]] && _cpa_snapshot_validate_dir "$directory" || return 1
    [[ $(jq -r .id "$directory/manifest.json") == "$1" ]] || return 1
    cat -- "$directory/manifest.json"
}

cpa_snapshot_list() {
    local file directory
    local -a manifests=()
    shopt -s nullglob
    for file in "$CPA_STATE_DIR"/snapshots/*/manifest.json; do
        directory=$(dirname -- "$file")
        [[ ! -L $directory && ! -L $file ]] && jq -e 'type=="object" and (.id|type=="string")' "$file" >/dev/null || continue
        manifests+=("$file")
    done
    # Legacy second-only stamps denote the beginning of their second; normalize
    # only the sorting key, retaining the authenticated manifest unchanged.
    if [[ ${#manifests[@]} == 0 ]]; then printf '[]\n'; else jq -s 'sort_by((.created_at|if endswith("Z") and (contains(".")|not) then sub("Z$";".000000000Z") else . end),.id)|reverse' "${manifests[@]}"; fi
}

cpa_snapshot_export() {
    local id=$1 destination=$2 directory
    cpa_snapshot_verify "$id" >/dev/null || return 1
    directory=$(cpa_snapshot_dir "$id") || return 1
    if ! tar --format=posix --hard-dereference -C "$directory" -cf "$destination" manifest.json payload; then rm -f -- "$destination"; return 1; fi
    printf '%s\n' "$destination"
}

# Tar listing is safe only because names containing control characters or a
# backslash are rejected. PAX-resolved names and entry types are checked first.
cpa_snapshot_import() {
    local archive=$1 expected_node=$2 expected_epoch=$3 expected_role=${4-} stage names verbose path max id limit
    [[ -f $archive && ! -L $archive ]] || return 1
    cpa_id_valid "$expected_node" && [[ $expected_epoch =~ ^[0-9]{1,12}$ ]] || return 1
    max=$(jq -r .max_snapshot_bytes "$CPA_STATE_DIR/config.json") || return 1
    limit=$((max+134217728))
    [[ $(stat -c %s -- "$archive") -le $limit ]] || { cpa_fail '传输归档超量。'; return 1; }
    stage=$(mktemp -d "$CPA_STATE_DIR/tmp/import.XXXXXXXX") || return 1
    names=$stage/names; verbose=$stage/verbose
    if ! LC_ALL=C timeout 60 tar --absolute-names --quoting-style=escape -tf "$archive" > "$names" || ! LC_ALL=C timeout 60 tar --absolute-names --quoting-style=escape --full-time -tvf "$archive" > "$verbose"; then rm -rf -- "$stage"; cpa_fail '归档目录读取失败。'; return 1; fi
    if [[ $(wc -l < "$names") -gt 200001 || $(wc -l < "$names") != "$(wc -l < "$verbose")" ]]; then rm -rf -- "$stage"; cpa_fail '归档条目超量或异常。'; return 1; fi
    if ! awk -v max="$max" 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1} $3 !~ /^[0-9]+$/ {exit 1} {total+=$3; if(total>max+33554432) exit 1}' "$verbose"; then rm -rf -- "$stage"; cpa_fail '归档包含链接、特殊类型或超量文件。'; return 1; fi
    : > "$stage/normalized"
    while IFS= read -r path; do
        path=${path%/}
        if [[ $path != manifest.json ]] && ! _cpa_payload_path "$path"; then rm -rf -- "$stage"; cpa_fail '归档路径无效。'; return 1; fi
        [[ $path != *\\* && ! $path =~ [[:cntrl:]] ]] || { rm -rf -- "$stage"; return 1; }
        printf '%s\n' "$path" >> "$stage/normalized"
    done < "$names"
    if [[ -n $(LC_ALL=C sort "$stage/normalized" | uniq -d) ]] || [[ $(grep -cx manifest.json "$stage/normalized") != 1 ]]; then rm -rf -- "$stage"; cpa_fail '归档条目重复或缺失清单。'; return 1; fi
    rm -f -- "$names" "$verbose" "$stage/normalized"
    # A file-size resource limit bounds sparse/expanded output before validation.
    if ! (umask 077; ulimit -f "$(( (max+33554432+1023)/1024 ))"; timeout 120 tar --no-same-owner --no-same-permissions --delay-directory-restore -C "$stage" -xf "$archive"); then rm -rf -- "$stage"; cpa_fail '归档解包失败。'; return 1; fi
    if ! _cpa_snapshot_validate_dir "$stage"; then rm -rf -- "$stage"; return 1; fi
    if [[ $(jq -r .node_id "$stage/manifest.json") != "$expected_node" || $(jq -r .epoch "$stage/manifest.json") != "$expected_epoch" ]]; then rm -rf -- "$stage"; cpa_fail '快照来源或代次不符。'; return 1; fi
    if [[ -n $expected_role && $(jq -r .node_role "$stage/manifest.json") != "$expected_role" ]]; then rm -rf -- "$stage"; cpa_fail '快照来源角色不符。'; return 1; fi
    id=$(jq -r .id "$stage/manifest.json") || { rm -rf -- "$stage"; return 1; }
    if [[ -e $CPA_STATE_DIR/snapshots/$id ]]; then
        if cpa_snapshot_verify "$id" >/dev/null && cmp -s "$stage/manifest.json" "$CPA_STATE_DIR/snapshots/$id/manifest.json"; then rm -rf -- "$stage"; cat "$CPA_STATE_DIR/snapshots/$id/manifest.json"; return 0; fi
        rm -rf -- "$stage"; cpa_fail '已存在相同ID但内容冲突。'; return 1
    fi
    if ! _cpa_snapshot_publish "$stage"; then rm -rf -- "$stage"; return 1; fi
}

cpa_snapshot_clone() {
    local id=$1 purpose=$2 source stage newid
    [[ $purpose =~ ^[a-z][a-z_-]{0,31}$ ]] || return 1
    cpa_snapshot_verify "$id" >/dev/null || return 1
    source=$(cpa_snapshot_dir "$id") && stage=$(mktemp -d "$CPA_STATE_DIR/tmp/clone.XXXXXXXX") || return 1
    if ! cp -R --preserve=mode,timestamps --reflink=auto -- "$source/payload" "$stage/payload"; then rm -rf -- "$stage"; return 1; fi
    newid="$(date -u +%Y%m%dT%H%M%SZ)_$(cpa_uuid)"
    if ! jq --arg id "$newid" --arg purpose "$purpose" --arg created "$(cpa_now)" '.id=$id|.purpose=$purpose|.created_at=$created' "$source/manifest.json" > "$stage/manifest.json"; then rm -rf -- "$stage"; return 1; fi
    if ! _cpa_snapshot_publish "$stage"; then rm -rf -- "$stage"; return 1; fi
}

cpa_snapshot_plan() {
    local id=$1 directory row name kind target configured_kind temporary wal
    cpa_snapshot_verify "$id" >/dev/null || return 1
    directory=$(cpa_snapshot_dir "$id") && temporary=$(mktemp "$CPA_STATE_DIR/tmp/plan.XXXXXXXX") || return 1
    : > "$temporary"
    while IFS= read -r row; do
        name=$(jq -r .name <<< "$row") && kind=$(jq -r .kind <<< "$row") || { rm -f -- "$temporary"; return 1; }
        target=$(jq -er --arg name "$name" '.sources[]|select(.name==$name)|.path' "$CPA_STATE_DIR/config.json") && configured_kind=$(jq -er --arg name "$name" '.sources[]|select(.name==$name)|.kind' "$CPA_STATE_DIR/config.json") || { rm -f -- "$temporary"; cpa_fail '本机缺少快照标签的恢复映射。'; return 1; }
        cpa_path_validate "$target" || { rm -f -- "$temporary"; return 1; }
        [[ $configured_kind == auto || $configured_kind == "$kind" ]] || { rm -f -- "$temporary"; cpa_fail '恢复映射的数据类型不匹配。'; return 1; }
        [[ ! -e $target || ( $kind == directory && -d $target ) || ( $kind != directory && -f $target ) ]] || { rm -f -- "$temporary"; cpa_fail '恢复目标实际类型不符。'; return 1; }
        _cpa_tree_safe "$target" restore || { rm -f -- "$temporary"; return 1; }
        wal=false
        if [[ $kind == sqlite && ( -e $target-wal || -e $target-shm ) ]]; then wal=true; fi
        jq -cn --arg name "$name" --arg kind "$kind" --arg target "$target" --argjson source "$row" --argjson wal "$wal" '{name:$name,kind:$kind,target:$target,existed:$source.existed,sqlite_sidecar_present:$wal,operation:(if $source.existed then "replace_contents" else "remove_target" end)}' >> "$temporary" || { rm -f -- "$temporary"; return 1; }
    done < <(jq -c '.items[]' "$directory/manifest.json")
    jq -n --arg id "$id" --slurpfile items "$temporary" '{snapshot_id:$id,items:$items,warnings:["恢复前须停止CPA及全部后台写入。","文件/目录恢复反映删除，覆盖前保存本机回滚副本。",(if any($items[];.sqlite_sidecar_present) then "SQLite目标仍有WAL/SHM；实际恢复将拒绝，先正确停止/检查数据库。" else empty end)]}'
    rm -f -- "$temporary"
}

_cpa_restore_item() {
    local directory=$1 row=$2 name kind target existed source path parent
    name=$(jq -r .name <<< "$row") && kind=$(jq -r .kind <<< "$row") && target=$(jq -r .target <<< "$row") && existed=$(jq -r .existed <<< "$row") || return 1
    source=$directory/payload/$name
    cpa_path_validate "$target" && _cpa_tree_safe "$target" restore || return 1
    parent=$(dirname -- "$target") || return 1
    if [[ $existed == false ]]; then
        if [[ -e $target ]]; then rm -rf --one-file-system -- "$target" || return 1; fi
        [[ -d $parent ]] && sync -- "$parent" || return 1
        return 0
    fi
    [[ -d $parent ]] || { cpa_fail '恢复目标的父目录须预先准备。'; return 1; }
    local -A previous=()
    local list
    list=$(mktemp "$CPA_STATE_DIR/tmp/restore-tree.XXXXXXXX") || return 1
    if [[ -e $target ]]; then
        find -P "$target" -print0 > "$list" || { rm -f -- "$list"; return 1; }
        while IFS= read -r -d '' path; do previous["$path"]=1; done < "$list"
    fi
    if [[ $kind == directory ]]; then
        if [[ ! -e $target ]]; then mkdir -- "$target" && chown --reference="$parent" -- "$target" || { rm -f -- "$list"; return 1; }; fi
        if ! rsync -rlt --checksum --inplace --delete --no-links --no-devices --no-specials -- "$source/" "$target/"; then rm -f -- "$list"; return 1; fi
    elif ! rsync -lt --checksum --inplace -- "$source/data" "$target"; then rm -f -- "$list"; return 1; fi
    find -P "$target" -print0 > "$list" || { rm -f -- "$list"; return 1; }
    while IFS= read -r -d '' path; do
        if [[ ! ${previous["$path"]+exists} ]]; then
            parent=$(dirname -- "$path") || { rm -f -- "$list"; return 1; }
            chown --reference="$parent" -- "$path" || { rm -f -- "$list"; return 1; }
        fi
    done < "$list"
    rm -f -- "$list"
    _cpa_flush_tree "$target" && sync -- "$(dirname -- "$target")" || return 1
}

cpa_snapshot_restore() {
    local id=$1 directory plan temporary rollback_config rollback rollback_id row kind target epoch failed=false compensation_failed=false
    cpa_config_validate "$CPA_STATE_DIR/config.json" || return 1
    directory=$(cpa_snapshot_dir "$id") && plan=$(cpa_snapshot_plan "$id") || return 1
    if jq -e 'any(.items[];.sqlite_sidecar_present)' <<< "$plan" >/dev/null; then cpa_fail 'SQLite仍有WAL/SHM日志，拒绝覆盖。'; return 1; fi
    temporary=$(mktemp -d "$CPA_STATE_DIR/tmp/restore.XXXXXXXX") || return 1
    rollback_config=$temporary/config.json
    if ! jq --argjson plan "$plan" '.sources = [$plan.items[]|{name,path:.target,kind}]' "$CPA_STATE_DIR/config.json" > "$rollback_config"; then rm -rf -- "$temporary"; return 1; fi
    epoch=$(jq -r .epoch "$directory/manifest.json") || { rm -rf -- "$temporary"; return 1; }
    rollback=$(_cpa_snapshot_create rollback "$epoch" "$rollback_config") || { rm -rf -- "$temporary"; cpa_fail '回滚副本生成失败，未覆盖目标。'; return 1; }
    rollback_id=$(jq -r .id <<< "$rollback") || { rm -rf -- "$temporary"; return 1; }
    while IFS= read -r row; do
        if ! _cpa_restore_item "$directory" "$row"; then failed=true; break; fi
    done < <(jq -c '.items[]' <<< "$plan")
    if [[ $failed == true ]]; then
        local rollback_plan rollback_directory
        rollback_plan=$(cpa_snapshot_plan "$rollback_id") && rollback_directory=$(cpa_snapshot_dir "$rollback_id") || { rm -rf -- "$temporary"; cpa_fail "恢复失败；回滚副本 $rollback_id 保留，补偿预览失败。"; return 1; }
        while IFS= read -r row; do _cpa_restore_item "$rollback_directory" "$row" || compensation_failed=true; done < <(jq -c '.items[]' <<< "$rollback_plan")
        rm -rf -- "$temporary"
        cpa_fail "恢复失败；回滚副本 $rollback_id 已保留；补偿失败=$compensation_failed。"
        return 1
    fi
    rm -rf -- "$temporary"
    jq -n --arg rollback "$rollback_id" --argjson plan "$plan" '{rollback_id:$rollback,restored:$plan.items}'
}

cpa_snapshot_prune() {
    local retention latest protected list id directory group candidate
    local -A valid=()
    retention=$(jq -r .retention_count "$CPA_STATE_DIR/config.json") || return 1
    latest=''
    if [[ -f $CPA_STATE_DIR/runtime.json ]]; then latest=$(jq -r '.latest_received.id // empty' "$CPA_STATE_DIR/runtime.json") || return 1; fi
    list=$(cpa_snapshot_list) || return 1
    protected=$(jq -r 'map(select(.purpose=="rollback"))|first.id//empty' <<< "$list") || return 1
    # A corrupted newest archive must not cause the last usable before-image
    # in its source/purpose group to be removed by the retention window.
    while IFS= read -r group; do
        while IFS= read -r candidate; do
            if cpa_snapshot_verify "$candidate" >/dev/null 2>&1; then valid["$candidate"]=1; break; fi
        done < <(jq -r 'sort_by((.created_at|if endswith("Z") and (contains(".")|not) then sub("Z$";".000000000Z") else . end),.id)|reverse|.[].id' <<< "$group")
    done < <(jq -c 'group_by([.node_id,.purpose])[]' <<< "$list")
    while IFS= read -r id; do
        [[ $id != "$latest" && $id != "$protected" && ! ${valid["$id"]+exists} ]] || continue
        directory=$(cpa_snapshot_dir "$id") || return 1
        [[ ! -L $directory ]] && rm -rf --one-file-system -- "$directory" || return 1
    done < <(jq -r --argjson keep "$retention" 'group_by([.node_id,.purpose])[] | sort_by((.created_at|if endswith("Z") and (contains(".")|not) then sub("Z$";".000000000Z") else . end),.id)|reverse|.[$keep:][]|.id' <<< "$list")
    sync -- "$CPA_STATE_DIR/snapshots" || return 1
}
