# drive-to-borg
a simple utility to back up google drive folders to a borg repository.

the script can (hopefully) be run stand-alone on any linux machine with borg, jq, and rclone, or it can be run in docker using
```
docker run -v <home-dir>:/home/ubuntu mlgrm/drive-to-borg \
    [--my-drive] [--team-drives] [--shared-with-me] [--folder <folder-id>>]
 ```

see https://gist.github.com/mlgrm/5ecb9012a8d54590bbedbfcb9b03acdb for setup info to use the google api.
