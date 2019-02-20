#!/bin/bash

# the name of the docker host in your google cloud project.  will be created
# if it doesn't already exist.
DOCKER_HOST_NAME=${DOCKER_HOST_NAME:-cosima}

# need to specify folder ids.  can also be (in) team drives you have access to
FOLDERS=${FOLDERS:-"XXXXXXXXXXXXXXXXXXXXXXXX"}

# whether to back up your whole "My Drive" folder
MY_DRIVE=${MY_DRIVE:-"false"}

# whether to back up all items in the "Shared with me" folder
SHARED_WITH_ME=${SHARED_WITH_ME:-"true"}

# whether to back up all team drives you have access to
# (mainly for domain admins)
TEAM_DRIVES=${TEAM_DRIVES="true"}

# this has to be changed
REPO=${REPO:-"ssh://12345@ch-012.rsync.net/~/drive"}

# if you already have a disk from previous backups, you
# can speed up rclone by (re)-using it
USE_DISK=${USE_DISK:-"true"}
DISK_NAME=${DISK_NAME:-"drive-backup"}

DISK_SIZE=${DISK_SIZE:-"200GB"}

trap clean_up ERR SIGINT SIGTERM

clean_up () {
    if [[ ! -z $mount_point ]]; then
        gcloud compute ssh $DOCKER_HOST_NAME --command "umount $mount_point"
    fi
    gcloud compute instances detach-disk $DOCKER_HOST_NAME $DISK_NAME
}

# if our docker host doesn't exist, create her
if [[ -z $(gcloud compute instances list \
    --filter "name~^$DOCKER_HOST_NAME$" \
    --format "value(name)") ]]; then
    eval(curl -sL bit.ly/mlgrm-gcp-make-docker-host | bash)
# otherwise, it was presumably created from here previously, so all the tls
# keys and such should be available locally.
else
    export DOCKER_HOST="tcp://$(
    gcloud compute instances describe cosima \
        --format 'value(networkInterfaces[0].accessConfigs[0].natIP)'
    ):2376" DOCKER_TLS_VERIFY=1
fi

# check if we have a disk and it's attached
if [[ $USE_DISK = "true" ]]; then
    # if the disk is not attached
    if ! gcloud compute instances describe $DOCKER_HOST_NAME \
        --format "json(disks[].deviceName)" |
        jq -r ".disks[].deviceName" |
        grep -q "^$DISK_NAME$"; then
        # if the disk does not exist
        if ! gcloud compute disks list \
            --format "value(name)" |
            grep -q "^$DISK_NAME"; then
            # create it
            gcloud compute disks create $DISK_NAME --size $DISK_SIZE
            new_disk=true
        fi
        # attach it
        gcloud compute disks attach-disk $DOCKER_HOST_NAME \
            --disk $DISK_NAME \
            --device-name $DISK_NAME
    fi
    if [[ "$new_disk" = "true" ]]; then
        gcloud compute ssh $DOCKER_HOST_NAME \
            --command "sudo mkfs.ext4 -m 0 /dev/disk/by-id/google-$DISK_NAME"
    fi
fi

if [[ "$USE_DISK" == "true" ]]; then
    mount_point=$(gcloud compute ssh $DOCKER_HOST_NAME --command "mktemp -d")
    gcloud compute ssh $DOCKER_HOST_NAME \
        --command "sudo mount $/dev/disk/by-id/google-$DISK_NAME $mount_point"
fi

# build the docker command arguments from the environment vars
args=()
[[ "$USE_DISK" = "true" ]] && args+=("-v '$mount_point:/home/ubuntu/drive/'")
args+=("mlgrm/drive-to-borg")
if [[ ! -z $FOLDERS ]]; then
    for f in ${FOLDERS[@]}; do
        args+=("--folder $f")
    done
fi
[[ "$MY_DRIVE" == "true" ]] && args+=("--my-drive")
[[ "$SHARED_WITH_ME" == "true" ]] && args+=("--shared-with-me")
[[ "$TEAM_DRIVES" == "true" ]] && args+=("--team-drives")

eval docker run ${args[@]}

clean_up
