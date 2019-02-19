#!/bin/bash
#
# drive-to-borg: a simple script to sync google drive folders and
# team drives, then back them up with borg
#
# for a production environment, this script is intended to be run
# in a container running on a host in google's compute platform, storing
# secrets and keys in the project metadata

set -e

#############
# FUNCTIONS #
#############

usage() { printf "%s" "
Usage:

drive-to-borg [--option [\"value\"] [...]]
docker run [docker-options] mlgrm/drive-to-borg [--option [\"value\"] [...]]

Options:
    -f, --folder-id FOLDER_ID
            id of a drive or team drive folder to back up. Use once for each
            folder

    -m, --my-drive
            back-up everything in \"My Drive\"

    -s, --shared-with-me
            back-up everything in \"Shared with me\"

    -t, --team-drives
            back-up all the team drives you are a member of, or if you are a
            domain admin, all team drives

    --token TOKEN
            a json string containing a valid set of token values from rclone

    --token-file FILE_NAME
            a json file containing a valid rclone token.  for docker, the
            file must be available from /home/ubuntu on the container's file
            system

    -r, --repo REPOSITORY
            a fully qualified borg repository location.  for remote
            repositories, it should be of the form:
            ssh://user@server/path/to/repo

    --borg-key-file KEYFILE
            if you have a local keyfile, you can specify it here. for docker,
            the file must be available from /home/ubuntu on the container's
            file system

    --help
            print this message and exit
"
    exit 0
}
warn () {
    echo "$(basename $0):" "$@" >&2
}
die () {
    rc=$1
    shift
    warn "$@"
    exit $rc
}
message () {
    (>&2 echo $@)
}

update_metadata () {
    project_id=$(curl -s \
        metadata.google.internal/computeMetadata/v1/project/project-id \
        -H 'Metadata-flavor: Google'
    )
    IFS='=' read -rd '' key value <<< $1
    # remove any leading and trailing quotes made by jq -sR
    value=$(sed -e '1 s/^"//' -e '$ s/"$//' <<< $1)
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
    repo=$1
    keyfile=$2
    if ! keylist=$(
    curl -s -H "Metadata-flavor: Google" \
        $project_metadata/borg-keys
    ); then keylist='[]'; fi
    [[ -z $keylist ]] && keylist="[]"
    json=$(jq -nc "[ .remote = \"$repo\" | .key = \"$(< $keyfile)\" ]")
    keylist=$(jq ". += $json" <<< $keylist | jq -sR '.')
    update_metadata "borg-keys=$keylist"
}


#########
# FLAGS #
#########

POSITIONAL=()
DIRS=()
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

        -r|--repo)
            REPO=$2
            shift
            shift
            ;;

        -k|--borg-key-file)
            BORG_KEY_FILE=$2
            shift
            shift
            ;;

        --help)
            usage
            ;;

        *)
            POSITIONAL+=($key)
            shift
            ;;
    esac
done

#########
# SETUP #
#########

set -- ${POSITIONAL[@]}
if [[ $# -ne 0 ]]; then die 1 "unrecognized args: $@"; fi

[[ -z $REPO ]] && die 1 "need to specify a repo"

# rsync.net uses an old borg by default
if grep -q rsync.net <<< $REPO; then
    export BORG_REMOTE_PATH=${BORG_REMOTE_PATH:-"borg1"}
fi

# use a temp file for the key if we don't have a local file
export BORG_KEY_FILE=${BORG_KEY_FILE:-$(tempfile)}

########
# SYNC #
########

# if you don't have a TOKEN, try the first one in your rclone.conf
if [[ -z $TOKEN && -f $HOME/.config/rclone/rclone.conf ]] &&
    grep -qE '^token = ' $HOME/.config/rclone/rclone.conf; then
    TOKEN=${TOKEN:-$(grep '^token = ' $HOME/.config/rclone/rclone.conf |
        head -n 1 | sed -e 's/^token = //')}
fi

# if we're running on a google compute instance, the TOKEN might be in the
# project metadata
proj_metadata="metadata.google.internal/computeMetadata/v1/project/attributes"
if [[ -z $TOKEN ]] && curl -s metadata.google.internal > /dev/null; then
    TOKEN=$(curl -s $proj_metadata/rclone-token \
        -H "Metadata-flavor: Google")
fi

# if there's still no token, there's no hope
if [[ -z $TOKEN ]]; then die 1 "can't find a token for rclone"; fi

# get google-api script if not present
if [[ ! -x google-api ]]; then
    curl -sL http://bit.ly/mlgrm-google-api > google-api
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
        name=$(./google-api /drive/v3/files/$id | jq -r .name)
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

if [[ $TEAM_DRIVES = "true" ]]; then
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
fi

rm google-api

###########
# BACK-UP #
###########

# if the repo doesn't exist, create it
if ! borg check $REPO 2> /dev/null; then
    borg init -e keyfile $REPO

    # if we're on gce, upload the key to project metadata
    # otherwise store it locally
    if curl -s metadata.google.internal > /dev/null; then
        add_borg_key $REPO $BORG_KEY_FILE
    else cp $BORG_KEY_FILE $HOME/$(basename $REPO).key
    fi
fi

# if there's no key in the file, look for one elsewhere
if [[ ! -s $BORG_KEY_FILE ]] || ! grep BORG_KEY $BORG_KEY_FILE; then
    # if on gce, try to get the key from the project metadata
    if key=$(curl -s -H "Metadata-flavor: Google" \
        $project_metadata/borg-keys |
        jq -r "map(select( .remote == \"$REPO\" )) | .[0].key" > \
        $BORG_KEY_FILE
    ); then :; else
    # otherwise fall back to the local file
    [[ ! -s $BORG_KEY_FILE && ! -s $HOME/$(basename $REPO) ]] && \
        die 1 "can't find a key."
    cp $HOME/$(basename $REPO) $BORG_KEY_FILE
fi
fi

# if there's no local ssh key, look for one in the project metadata
if [[ ! -s $HOME/.ssh/id_rsa ]] && grep -q '^ssh:' <<< $REPO; then
    mkdir -p .ssh
    curl -s $project_metadata/borg-ssh-key > .ssh/id_rsa
fi

archive=$(date +%Y%m%d%H%M%S)
message "backing up to $REPO::$archive..."
borg create -s --json $REPO::$archive .
