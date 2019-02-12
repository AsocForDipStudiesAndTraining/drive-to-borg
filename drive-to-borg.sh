#!/bin/bash

warn () {
    echo "$0:" "$@" >&2
}
die () {
    rc=$1
    shift
    warn "$@"
    exit $rc
}
message () {
    (>&2 $@)
}
vcat () {
    printf "%s" $@
}

update_metadata () {
    project_id=$(curl -s \
        metadata.google.internal/computeMetadata/v1/project/project-id \
        -H 'Metadata-flavor: Google'
    )
    IFS='=' read -r key junk <<< $1
    # remove the key and any leading or trailing quotes made by jq -sR
    value=$(sed -e "1 s/$key=//" -e '1 s/^"//' -e '$ s/"$//' <<< $1)
    new_entry=$(jq -n "{ \"$key\": \"$value\" } | to_entries") ||
        return 1 #die 1 "failed to parse argument"
    new_metadata=$(./google-api /compute/v1/projects/$project_id |
        jq '.commonInstanceMetadata' |
        # only keep fingerprint and items
        jq 'with_entries(select(.key == "fingerprint" or .key == "items"))' |
        # remove the item with this key if it exists
        jq "del(.items[] | select( .key == ($new_entry | .[0].key) ))" |
        # add new item to the list
        jq ".items += $new_entry"
    ) || return 1 #die 1 "failed to process new metadata"
    ./google-api -X POST \
        /compute/v1/projects/$project_id/setCommonInstanceMetadata \
        -p "$new_metadata"
}

add_borg_key () {
    remote=$1
    keyfile=$2
    if ! keylist=$(
    curl -s -H "Metadata-flavor: Google" $(vcat \
        "metadata.google.internal/computeMetadata/" \
        "v1/project/attributes/borg-keys")
    ); then keylist='[]'; fi
    [[ -z $keylist ]] && keylist="[]"
    json=$(jq -nc $( vcat \
    "[ " \
    ".remote = \"$remote\" | " \
    ".\"file-name\" = \"$(basename $keyfile)\" | " \
    ".key = \"$(< $keyfile)\"" \
    " ]")
    )
    keylist=$(jq ". += $json" <<< $keylist | jq -sR '.')
    update_metadata "borg-keys=$keylist"
}


POSITIONAL=()
while [[ $# -gt 0 ]]
do
    key="$1"

    case $key in
        -f|--folder-id)
            DIRS+=($2)
            shift
            shift
            ;;

        -m|--my-drive)
            MY_DRIVE=true
            shift
            ;;

        -s|--shared-with-me)
            SHARED_WITH_ME=true
            shift
            ;;

        -t|--team-drives)
            TEAM_DRIVES=true
            shift
            ;;

        --token)
            TOKEN=$2
            shift
            shift
            ;;

        --token-file)
            if [[ ! -f $2 ]]; then die 1 "token file does not exist"; fi
            TOKEN=$(<$2)
            shift
            shift
            ;;

        *)
            POSITIONAL+=($key)
            shift
            ;;
    esac
done

set -- ${POSITIONAL[@]}
if [[ $# -ne 0 ]]; then die 1 "unrecognized args: $@"; fi

# if you don't have a TOKEN, try the first one in your rclone.conf
if [[ -z $TOKEN && -f $HOME/.config/rclone/rclone.conf ]] &&
    grep -qE '^token = ' $HOME/.config/rclone/rclone.conf; then
    TOKEN=${TOKEN:-$(grep '^token = ' $HOME/.config/rclone/rclone.conf |
        head -n 1 | sed -e 's/^token = //')}
fi

# if we're running on a google compute instance, the TOKEN might be in the
# project metadata
if [[ -z $TOKEN ]] && curl -s metadata.google.internal > /dev/null; then
    TOKEN=$(curl -s $(vcat metadata.google.internal/ \
        computeMetadata/v1/project/attributes/rclone-token) \
        -H "Metadata-flavor: Google")
fi

# if there's still no token, there's no hope
if [[ -z $TOKEN ]]; then die 1 "can't find a token for rclone"; fi

# get google-api script if not present
if [[ ! -f google-api ]]; then
    curl -sl http://bit.ly/mlgrm-google-api > google-api
    chmod +x google-api
fi

# folders
if [[ ${#DIRS[@]} -gt 0 ]]; then
    for id in $DIRS; do
        # check if we are a team drive
        if [[ $(./google-api /drive/v3/files/$id supportsTeamDrives=true |
            jq -r '.teamDriveId != null') = "true" ]]; then
        mkdir -p team-drives
        name=$(./google-api /drive/v3/teamdrives/$id |
            jq -r .name)
        prefix="team-drives"
        conf_lines=(
        '[dir]'
        'type = drive'
        'scope = drive.readonly'
        "token = $TOKEN"
        "team_drive = $id"
        )
    else
        mkdir -p folders
        name=$(google-api /drive/v3/files/$id | jq -r .name)
        prefix="folders"
        conf_lines=(
        '[dir]'
        'type = drive'
        'scope = drive.readonly'
        "root_folder_id = $id"
        "token = $TOKEN"
        )
    fi
    conf=$(tempfile)
    printf "%s\n" "${conf_lines[@]}" > $conf
    message "synching folder $name to to $prefix/$name ($id)..."
    rclone --config $conf sync dir: "$prefix/$name ($id)"
done
fi

# my drive
if [[ $MY_DRIVE = "true" ]]; then
    conf_lines=(
    '[dir]'
    'type = drive'
    'scope = drive.readonly'
    "token = $TOKEN"
    )
    conf=$(tempfile)
    printf "%s\n" "${conf_lines[@]}" > $conf
    message "synching My Drive to to my-drive/..."
    rclone --config $conf sync dir: my-drive
fi

# shared with me
if [[ $SHARED_WITH_ME = "true" ]]; then
    conf_lines=(
    '[dir]'
    'type = drive'
    'scope = drive.readonly'
    'shared_with_me = true'
    "token = $TOKEN"
    )
    conf=$(tempfile)
    printf "%s\n" "${conf_lines[@]}" > $conf
    message "synching Shared with me to to shared-with-me/..."
    rclone --config $conf sync dir: shared-with-me
fi

# team drives

for entry in $(
    ./google-api /drive/v3/teamdrives \
        useDomainAdminAccess=true \
        -l teamDrives | \
        jq -c .teamDrives[]
    ); do
    name=$(jq -r .name <<< $entry)
    id=$(jq -r .id <<< $entry)
    # check the permissions
    old_ids=$(
    ./google-api /drive/v3/files/$id/permissions \
        supportsTeamDrives=true \
        useDomainAdminAccess=true |
        jq -cr '.permissions[].id'
    )
    # create a permission if necessary
    perm_id=$(
    ./google-api -X POST /drive/v3/files/$id/permissions \
        supportsTeamDrives=true \
        useDomainAdminAccess=true \
        -p '{"role":"reader","type":"user","emailAddress":"'$EMAIL'}' |
        jq -r '.id'
    )
    conf_lines=(
    '[dir]'
    'type = drive'
    'scope = drive.readonly'
    'token = $TOKEN'
    'team_drive = $id'
    )
    printf "%s\n" "${conf_lines[@]}"
    message "synching $name to team-drives/$name ($id)/..."
    rclone --config $conf sync dir: "$name ($id)"/
    # if our perm is new, delete it.
    if ! grep -q "^$perm_id$" <<< $old_ids; then
        google-api -X DELETE /drive/v3/files/$id/permissions \
            supportsTeamDrives=true \
            useDomainAdminAccess=true
    fi
done

# if the repo doesn't exist, create it
login=$(sed -e 's/^\([^\/]*\).*$/\1/' <<< $REPO)
if ssh $login ls -d $(basename $REPO); then
    BORG_KEY_FILE=$HOME/$(basename $REPO).key borg \
        --remote-path borg1 \
        init -e keyfile $REPO

    # if we're on gce, upload it to metadata
    if curl -s metadata.google.internal > /dev/null; then
        update_metada "borg-key=$(< $BORG_KEY_FILE)"
    fi
fi

archive=$(date +%Y%m%d%H%M%S)
message "backing up to $REPO::$archive"
BORG_KEY_FILE=$HOME/$(basename $REPO).key borg \
    --remote-path borg1 \
    create -s --json $REPO::$archive
