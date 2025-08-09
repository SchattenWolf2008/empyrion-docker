FROM debian:bookworm-slim

RUN export DEBIAN_FRONTEND noninteractive && \
    apt-get update && \
    apt-get install -y --no-install-recommends --no-install-suggests net-tools tar unzip curl xvfb locales ca-certificates lib32gcc-s1 wine64 && \
    echo en_US.UTF-8 UTF-8 >> /etc/locale.gen && locale-gen && \
    rm -rf /var/lib/apt/lists/*
RUN ln -s '/home/container/Steam/steamapps/common/Empyrion - Dedicated Server/' /server && \
    mkdir /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix && \
    useradd -m user

# create both dirs and give to non-root user
RUN mkdir -p /home/container /opt/steamcmd && chown -R user:user /home/container /opt/steamcmd

USER user
ENV HOME=/home/container

# install SteamCMD into /opt/steamcmd (NOT /home/container, which Pterodactyl mounts over)
WORKDIR /opt/steamcmd
RUN curl -sqL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" | tar xz
RUN /opt/steamcmd/steamcmd.sh +login anonymous +quit || :

# switch back to the app working dir
WORKDIR /home/container

EXPOSE 30000/udp
ADD entrypoint.sh /
ENTRYPOINT ["/entrypoint.sh"]
