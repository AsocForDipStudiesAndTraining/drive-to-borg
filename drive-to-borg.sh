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
vcat () {
    printf "%s" $@
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

# if you don't have a TOKEN, try the first one in your rclone.conf
if [[ -z $TOKEN && -f $HOME/.config/rclone/rclone.conf ]] &&
    grep -qE '^token = ' $HOME/.config/rclone/rclone.conf; then
    TOKEN=${TOKEN:-$(grep '^token = ' $HOME/.config/rclone/rclone.conf |
        head -n 1 | sed -e 's/^token = //')}
fi

# if we're running on a google compute instance, the TOKEN might be in the
# project metadata
if [[ -z $TOKEN ]] && curl metadata.google.internal; then
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
    rclone --config $conf sync dir: shared-with-me
fi

# team drives

# get all team drive ids
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
    ./perm_id=$(
    google-api -X POST /drive/v3/files/$id/permissions \
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
    rclone --config $conf sync dir: "$name ($id)"/
    # if our perm is new, delete it.
    if ! grep -q "^$perm_id$" <<< $old_ids; then
        google-api -X DELETE /drive/v3/files/$id/permissions \
            supportsTeamDrives=true \
            useDomainAdminAccess=true
    fi
done

# if the repo doesn't exist, create it
BORG_KEY_FILE=$HOME/$(basename $REPO).key borg \
    --remote-path borg1 \
    init -e keyfile $REPO

BORG_KEY_FILE=$HOME/$(basename $REPO).key borg \
    --remote-path borg1 \
    create -s --json $REPO::$(date +%Y%m%d%H%M%S)
