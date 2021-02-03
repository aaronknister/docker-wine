ARG BASE_IMAGE="scottyhardy/docker-remote-desktop@sha256"
ARG TAG="266605ed833c0aa8b48ce5f19c261e02d3babf945e6e59aa01b1a1a7a9b918b5"
##############################
##### winebuilder-source #####
##############################
FROM ubuntu@sha256:6852f9e05c5bce8aa77173fa83ce611f69f271ee3a16503c5f80c199969fd1eb as winebuilder-source

# eoan is now "old"
RUN sed -i -re 's/([a-z]{2}\.)?archive.(ubuntu|canonical).com|security.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list

# install dev tools
RUN apt-get update \
    && DEBIAN_FRONTEND="noninteractive" apt-get install -y \
        build-essential \
        dpkg-dev \
        ubuntu-dev-tools \
	equivs

# Make this a separate step so the above can be cached by docker and re-used  for the 64-bit build section below
RUN rm -rf /var/lib/apt/lists/*

# Create build directories
RUN mkdir -p /build/orig /build/new 

# Copy patches
COPY patches/ /build/patches/

# Download sources
RUN cd /build/orig \
    && wget https://dl.winehq.org/wine-builds/ubuntu/dists/eoan/main/source/wine_5.0.1~eoan.dsc \
    && wget https://dl.winehq.org/wine-builds/ubuntu/dists/eoan/main/source/wine_5.0.1~eoan.tar.xz

# Apply quilt patches 
## (Extract old dsc, apply quilt patches and create new source)
RUN cd /build \
    && ( cd /build/orig && dpkg-source -x *.dsc BUILD \
         &&  ( cd BUILD && QUILT_PATCHES=/build/patches quilt push -a ) \
       ) \
    && ( cd /build/new && dpkg-source -b ../orig/BUILD/ )

#############################
##### winebuilder-amd64 #####
#############################
FROM ubuntu@sha256:6852f9e05c5bce8aa77173fa83ce611f69f271ee3a16503c5f80c199969fd1eb as winebuilder-amd64

# eoan is now "old"
RUN sed -i -re 's/([a-z]{2}\.)?archive.(ubuntu|canonical).com|security.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list

# install dev tools
RUN apt-get update \
    && DEBIAN_FRONTEND="noninteractive" apt-get install -y \
        build-essential \
        dpkg-dev \
        ubuntu-dev-tools \
	equivs

# copy source package
COPY --from=winebuilder-source /build/new /build/new

# Build amd64 package
RUN cd /build/new && dpkg-source -x *.dsc BUILD \
    && ( cd /build/new/BUILD \
         && mk-build-deps -ir -t "apt-get -o Debug::pkgProblemResolver=yes -y --no-install-recommends" \
         && debuild -b -uc -us \
       )
RUN rm -rf /var/lib/apt/lists/*

############################
##### winebuilder-i386 #####
############################
FROM ubuntu@sha256:429af080292016ce01450774a6ea9cc08712e53521460845fb6d5c76d130cb9d as winebuilder-i386

# eoan is now "old"
RUN sed -i -re 's/([a-z]{2}\.)?archive.(ubuntu|canonical).com|security.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list

# install dev tools
RUN apt-get update \
    && DEBIAN_FRONTEND="noninteractive" apt-get install -y \
        build-essential \
        dpkg-dev \
        ubuntu-dev-tools \
	equivs 

# copy source package
COPY --from=winebuilder-source /build/new /build/new

# Build i386 package
RUN cd /build/new && dpkg-source -x *.dsc BUILD \
    && ( cd /build/new/BUILD \
         && mk-build-deps -ir -t "apt-get -o Debug::pkgProblemResolver=yes -y --no-install-recommends" \
         && debuild -b -uc -us \
       )
RUN rm -rf /var/lib/apt/lists/*

################
##### MAIN #####
################
FROM ${BASE_IMAGE}:${TAG} as winebuilder-repo

# eoan is now "old"
RUN sed -i -re 's/([a-z]{2}\.)?archive.(ubuntu|canonical).com|security.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list

# Install build tools
RUN sed -i -E 's/^# deb-src /deb-src /g' /etc/apt/sources.list \
    && apt-get update \
    && DEBIAN_FRONTEND="noninteractive" apt-get install -y --no-install-recommends \
        dpkg-dev \
    && rm -rf /var/lib/apt/lists/*

# copy source package
COPY --from=winebuilder-i386  /build/new/*.deb /build/repo-staging/i386/
COPY --from=winebuilder-amd64 /build/new/*.deb /build/repo-staging/amd64/

# create repo from above (using dpkg-dev tools)
RUN mkdir -p /build/repo \
    && cd /build/repo-staging \
    && mv amd64/*.deb /build/repo \
    && mv i386/wine-stable-i386*.deb /build/repo \
    && ( cd /build/repo && ( dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz ) )

FROM ${BASE_IMAGE}:${TAG}

# eoan is now "old"
RUN sed -i -re 's/([a-z]{2}\.)?archive.(ubuntu|canonical).com|security.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list

# Install prerequisites
RUN apt-get update \
    && DEBIAN_FRONTEND="noninteractive" apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        cabextract \
        git \
        gosu \
        gpg-agent \
        p7zip \
        pulseaudio \
        pulseaudio-utils \
        software-properties-common \
        tzdata \
        unzip \
        wget \
        winbind \
        xvfb \
        zenity \
    && rm -rf /var/lib/apt/lists/*

# Install wine
ARG WINE_BRANCH="stable"
COPY --from=winebuilder-repo /build/repo/ /usr/share/wine/repo/
RUN echo "deb [trusted=yes] file:///usr/share/wine/repo/ /" >> /etc/apt/sources.list \
    && dpkg --add-architecture i386 \
    && apt-get update \
    && DEBIAN_FRONTEND="noninteractive" apt-get install -y --install-recommends winehq-${WINE_BRANCH} \
    && rm -rf /var/lib/apt/lists/*

# Install winetricks
RUN wget -nv -O /usr/bin/winetricks https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
    && chmod +x /usr/bin/winetricks

# Download gecko and mono installers
COPY download_gecko_and_mono.sh /root/download_gecko_and_mono.sh
RUN chmod +x /root/download_gecko_and_mono.sh \
    && /root/download_gecko_and_mono.sh "$(dpkg -s wine-${WINE_BRANCH} | grep "^Version:\s" | awk '{print $2}' | sed -E 's/~.*$//')"

COPY pulse-client.conf /root/pulse/client.conf
COPY entrypoint.sh /usr/bin/entrypoint
ENTRYPOINT ["/usr/bin/entrypoint"]
