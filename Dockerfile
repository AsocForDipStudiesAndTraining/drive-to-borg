FROM ubuntu

RUN apt-get update && apt-get install -y \
        borgbackup \
        curl \
        unzip \
        man-db \
        ssh \
        jq

RUN curl https://rclone.org/install.sh | bash

RUN useradd -m ubuntu

WORKDIR /home/ubuntu

COPY drive-to-borg.sh .

USER ubuntu

ENTRYPOINT ["./drive-to-borg.sh"]
