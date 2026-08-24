# Agent development VM specifications

**Date:** 2026-08-24
**Status:** Point-in-time specification

This document records the development virtual machine used for the session
captured on 2026-08-24. It describes the observed guest environment, not a
general OpenAgents hosting contract. For a copyable Google Cloud deployment
example, see the [GCE development VM fleet example](examples/gce-dev-vm-fleet/).

## What the VM is

### Hardware

The VM presents the following hardware:

| Resource | Observed value |
| --- | --- |
| Architecture | `x86_64` |
| vCPU | 8 Intel Xeon Platinum 8559C vCPUs |
| CPU platform | Emerald Rapids |
| Sockets | 1 |
| Threads per core | 1 |
| L3 cache | 320 MiB |
| GPU | None detected |

The CPU exposes VT-x and the `vmx` flag. The guest reports one NUMA node and
full KVM virtualization.

### Memory and storage

The VM has 31 GiB of RAM and no configured swap. Its storage is:

| Device | Capacity | Filesystem or mount |
| --- | ---: | --- |
| `/dev/vda` | 128 GB device, 122 GiB filesystem | ext4 root filesystem at `/` |
| `/dev/vdb` | 270 MB device | Host share at `/mnt/host_share` |

The root filesystem uses about 12 GiB, with about 105 GiB available in the
captured state. The root filesystem is an ext4 filesystem created on
2024-11-04. The user home directory has a 2024-12-23 timestamp, which is
consistent with a prebaked image rather than a fresh package installation.

### Network

The guest has a private `/30` network address, `172.16.24.2`, behind NAT. The
observed interfaces include:

| Interface | State | Address |
| --- | --- | --- |
| `eth0` | Up | `172.16.24.2/30` |
| `docker0` | Down | `172.17.0.1/16` |
| `lo` | Unknown | `127.0.0.1/8`, `::1/128` |
| `teql0` | Down | None |

No cloud metadata endpoint responds from the guest. Requests to both the AWS
and Google Cloud metadata endpoints fail.

## Operating system and kernel

The guest runs Ubuntu 22.04.5 LTS, codename `jammy`, on the 5.15.200 Linux
kernel:

```text
Ubuntu 22.04.5 LTS
Linux 5.15.200 #6 SMP Fri Aug 14 19:23:04 UTC 2026 x86_64
```

The image includes a graphical desktop, Docker, browser automation tools, and
development toolchains. It has no GPU and no swap.

## Virtualization findings

The guest runs as a Cloud Hypervisor virtual machine on KVM. The evidence is:

- DMI reports `sys_vendor=Cloud Hypervisor` and
  `product_name=cloud-hypervisor`.
- `systemd-detect-virt` returns `kvm`.
- The guest boots directly with
  `console=ttyS0 reboot=k panic=0 root=/dev/vda rw host_share_root=vdb
  net.ifnames=0`.
- The device model exposes six virtio devices.
- `/dev/vsock` is present.
- The guest uses a real block device for its root filesystem.

The underlying cloud provider is probably Alibaba Cloud based on the
Intel Xeon Platinum 8559C custom SKU. This is an inference, not evidence from
the guest. The failed cloud metadata requests prevent a provider
identification from this session.

The image retains Firecracker-era artifacts. The kernel build references a
host named `sampriti-firecracker`, and the guest has a failed `fcnet.service`.
Those artifacts do not change the live VMM finding: the current guest runs on
Cloud Hypervisor.

## Container versus VM

This environment is a microVM, not a container. The evidence is:

- PID 1 is systemd at `/sbin/init`.
- The process belongs to cgroup `/init.scope`.
- `/.dockerenv` does not exist.
- The root filesystem does not use overlayfs.
- `/dev/vda` is a real block device mounted as the root filesystem.
- DMI and `systemd-detect-virt` identify Cloud Hypervisor on KVM.

These observations distinguish the guest from a container while still
recognizing that Cloud Hypervisor provides a lightweight VM boundary.

## Installed toolchain

The image contains these key tools:

| Tool | Version or detail |
| --- | --- |
| Rust and `rustup` | Rust `1.83.0`, `rustup 1.27.1` |
| Node.js, npm, and Corepack | Node.js `20.18.1`, npm `10.8.2`, Corepack `0.29.4` |
| Python and pip | Python `3.10.12`, pip `22.0.2` |
| GCC and G++ | `11.4.0` |
| OpenJDK | `17.0.13` |
| Make | `4.3` |
| Docker | `27.4.1` |
| Git | `2.55.0` |
| ripgrep | `13.0.0` |
| PostgreSQL client | `psql 16.15` |
| FFmpeg | `4.4.2` |
| Chrome for Testing | `133.0.6943.126` |
| X11 automation | `xvfb`, `wmctrl`, and `xdotool` |

The image does not include Go, Clang or LLVM, Ruby, PHP, Kotlin, Swift,
.NET, CMake, Terraform, `kubectl`, `gcloud`, `pnpm`, `yarn`, `bun`, or Snap.
It has 1084 installed APT packages, 134 pip packages, and the global npm
packages `corepack@0.29.4` and `npm@10.8.2`.

## Appendices

### Appendix A: pip package inventory

The following inventory contains all 134 pip packages captured from the image:

```text
aiohappyeyeballs==2.6.1
aiohttp==3.11.16
aiosignal==1.3.2
altair==5.5.0
async-timeout==5.0.1
attrs==21.2.0
awscli==1.22.34
backcall==0.2.0
beautifulsoup4==4.12.3
bleach==6.2.0
blinker==1.4
botocore==1.23.34
branca==0.8.1
cachetools==5.5.0
certifi==2020.6.20
chardet==4.0.0
charset-normalizer==3.4.0
click==8.1.8
colorama==0.4.4
contourpy==1.3.1
cryptography==3.4.8
cycler==0.12.1
dbus-python==1.2.18
decorator==4.4.2
defusedxml==0.7.1
distro==1.7.0
docutils==0.17.1
entrypoints==0.4
fastjsonschema==2.21.1
flake8==7.1.1
folium==0.19.2
fonttools==4.55.3
frozenlist==1.5.0
gitdb==4.0.11
GitPython==3.1.43
httplib2==0.20.2
idna==3.3
importlib-metadata==4.6.4
ipykernel==6.7.0
ipython==7.31.1
ipython_genutils==0.2.0
jedi==0.18.0
jeepney==0.7.1
Jinja2==3.1.5
jmespath==0.10.0
joblib==1.4.2
jsonschema==3.2.0
jupyter-client==7.1.2
jupyter-console==6.4.0
jupyter_core==5.7.2
jupyterlab_pygments==0.3.0
keyring==23.5.0
kiwisolver==1.4.7
launchpadlib==1.10.16
lazr.restfulclient==0.14.4
lazr.uri==1.0.6
markdown-it-py==3.0.0
MarkupSafe==3.0.2
matplotlib==3.10.0
matplotlib-inline==0.1.3
mccabe==0.7.0
mdurl==0.1.2
mistune==3.0.2
more-itertools==8.10.0
multidict==6.2.0
narwhals==1.19.0
nbclient==0.10.2
nbconvert==7.16.4
nbformat==5.10.4
nest-asyncio==1.5.4
numpy==2.2.1
oauthlib==3.2.0
packaging==24.2
pandas==2.2.3
pandocfilters==1.5.1
parso==0.8.1
pexpect==4.8.0
pickleshare==0.7.5
pillow==11.0.0
pip==22.0.2
platformdirs==4.3.6
prompt-toolkit==3.0.28
propcache==0.3.1
protobuf==5.29.2
psutil==6.1.1
ptyprocess==0.7.0
py==1.10.0
pyarrow==18.1.0
pyasn1==0.4.8
pycodestyle==2.12.1
pydeck==0.9.1
pyflakes==3.2.0
Pygments==2.18.0
PyGObject==3.42.1
PyJWT==2.3.0
pyparsing==2.4.7
pyrsistent==0.18.1
python-apt==2.4.0+ubuntu4
python-dateutil==2.9.0.post0
pytz==2024.2
PyYAML==5.4.1
pyzmq==22.3.0
requests==2.32.3
rich==13.9.4
roman==3.3
rsa==4.8
s3transfer==0.5.0
scikit-learn==1.6.0
scipy==1.14.1
seaborn==0.13.2
SecretStorage==3.3.1
setuptools==59.6.0
six==1.16.0
smmap==5.0.1
soupsieve==2.6
streamlit==1.41.1
tenacity==9.0.0
threadpoolctl==3.5.0
tinycss2==1.4.0
toml==0.10.2
tornado==6.1
traitlets==5.14.3
typing_extensions==4.12.2
tzdata==2024.2
urllib3==1.26.5
wadllib==1.3.6
watchdog==6.0.0
wcwidth==0.2.5
webencodings==0.5.1
websockets==14.1
wheel==0.37.1
xyzservices==2024.9.0
yarl==1.18.3
zipp==1.0.0
```

### Appendix B: APT package inventory

The complete 1084-package APT inventory is recorded in the report used to
produce this document and is reproduced below.

```text
accountsservice 22.07.5-2ubuntu1.5
adduser 3.118ubuntu5
adwaita-icon-theme 41.0-1ubuntu1
apparmor 3.0.4-2ubuntu2.4
apt 2.4.13
apt-transport-https 2.4.13
apt-utils 2.4.13
awscli 1.22.34-1
baloo-kf5 5.92.0-0ubuntu1
bc 1.07.1-3build1
binutils 2.38-4ubuntu2.6
binutils-common 2.38-4ubuntu2.6
binutils-x86-64-linux-gnu 2.38-4ubuntu2.6
breeze 4:5.24.7-0ubuntu0.2
breeze-cursor-theme 4:5.24.7-0ubuntu0.2
breeze-icon-theme 4:5.92.0-0ubuntu1
build-essential 12.9ubuntu3
bzip2 1.0.8-5build1
ca-certificates 20260601~22.04.1
ca-certificates-java 20190909ubuntu1.2
catdoc 1:0.95-5
containerd.io 1.7.24-1
coreutils 8.32-4.1ubuntu1.2
cpp 4:11.2.0-1ubuntu1
cpp-11 11.4.0-1ubuntu1~22.04
curl 7.81.0-1ubuntu1.26
dbus 1.12.20-2ubuntu4.1
dbus-user-session 1.12.20-2ubuntu4.1
dbus-x11 1.12.20-2ubuntu4.1
dconf-gsettings-backend 0.40.0-3
dconf-service 0.40.0-3
debconf 1.5.79ubuntu1
debconf-i18n 1.5.79ubuntu1
direnv 2.25.2-2
dirmngr 2.2.27-3ubuntu2.1
distro-info-data 0.52ubuntu0.8
dmidecode 3.3-3ubuntu0.2
docker-buildx-plugin 0.19.3-1~ubuntu.22.04~jammy
docker-ce 5:27.4.1-1~ubuntu.22.04~jammy
docker-ce-cli 5:27.4.1-1~ubuntu.22.04~jammy
docker-ce-rootless-extras 5:27.4.1-1~ubuntu.22.04~jammy
docker-compose-plugin 2.32.1-1~ubuntu.22.04~jammy
docutils-common 0.17.1+dfsg-2
dolphin 4:21.12.3-0ubuntu1
dpkg 1.21.1ubuntu2.3
dpkg-dev 1.21.1ubuntu2.3
drkonqi 5.24.5-0ubuntu0.1
e2fsprogs 1.46.5-2ubuntu1.2
expect 5.45.4-2build1
fdisk 2.37.2-4ubuntu3.4
ffmpeg 7:4.4.2-0ubuntu0.22.04.1
fontconfig 2.13.1-4.2ubuntu5
fontconfig-config 2.13.1-4.2ubuntu5
fonts-dejavu-core 2.37-2build1
fonts-freefont-ttf 20120503-10build1
fonts-ipafont-gothic 00303-21ubuntu1
fonts-jetbrains-mono 2.242+ds-2
fonts-liberation 1:1.07.4-11
fonts-noto-color-emoji 2.042-0ubuntu0.22.04.1
fonts-tlwg-loma-otf 1:0.7.3-1
fonts-unifont 1:14.0.01-1
fonts-wqy-zenhei 0.9.45-8
frameworkintegration 5.92.0-0ubuntu1
g++ 4:11.2.0-1ubuntu1
g++-11 11.4.0-1ubuntu1~22.04
gamin 0.1.10-6
gcc 4:11.2.0-1ubuntu1
gcc-11 11.4.0-1ubuntu1~22.04
gcc-11-base 11.4.0-1ubuntu1~22.04
gcc-12-base 12.3.0-1ubuntu1~22.04.2
gdb 12.1-0ubuntu1~22.04.2
gdisk 1.0.8-4build1
gh 2.72.0
gir1.2-glib-2.0 1.72.0-1
gir1.2-packagekitglib-1.0 1.2.5-2ubuntu3
git 1:2.55.0-0ppa1~ubuntu22.04.2
git-lfs 3.0.2-1ubuntu0.3
git-man 1:2.55.0-0ppa1~ubuntu22.04.2
gnupg 2.2.27-3ubuntu2.1
gnupg-l10n 2.2.27-3ubuntu2.1
gnupg-utils 2.2.27-3ubuntu2.1
gpg 2.2.27-3ubuntu2.1
gpg-agent 2.2.27-3ubuntu2.1
gpg-wks-client 2.2.27-3ubuntu2.1
gpg-wks-server 2.2.27-3ubuntu2.1
gpgconf 2.2.27-3ubuntu2.1
gpgsm 2.2.27-3ubuntu2.1
gpgv 2.2.27-3ubuntu2.1
groff 1.22.4-8build1
groff-base 1.22.4-8build1
gtk-update-icon-cache 3.24.33-1ubuntu2.2
hicolor-icon-theme 0.17-2
htop 3.0.5-7build2
humanity-icon-theme 0.6.16
hwdata 0.357-1
imagemagick 8:6.9.11.60+dfsg-1.3ubuntu0.22.04.5
imagemagick-6-common 8:6.9.11.60+dfsg-1.3ubuntu0.22.04.5
imagemagick-6.q16 8:6.9.11.60+dfsg-1.3ubuntu0.22.04.5
init-system-helpers 1.62
inotify-tools 3.22.1.0-2
iproute2 5.15.0-1ubuntu2
iptables 1.8.7-1ubuntu5.2
iso-codes 4.9.0-1
java-common 0.72build2
jq 1.6-2.1ubuntu3.2
jupyter 4.9.1-1
jupyter-client 7.1.2-1
jupyter-console 6.4.0-3
jupyter-core 4.9.1-1
jupyter-nbformat 5.1.3-1
kactivitymanagerd 5.24.4-0ubuntu1
kde-baseapps 4:21.08.0+5.118ubuntu1
kde-cli-tools 4:5.24.4-0ubuntu1
kde-cli-tools-data 4:5.24.4-0ubuntu1
kde-plasma-desktop 5:118ubuntu1
kde-style-breeze 4:5.24.7-0ubuntu0.2
kded5 5.92.0-0ubuntu1
kdialog 4:21.12.3-0ubuntu1
keditbookmarks 21.12.3-0ubuntu1
kfind 4:21.12.3-0ubuntu1
kinit 5.92.0-0ubuntu1
kio 5.92.0-0ubuntu1
kmod 29-1ubuntu1
konsole 4:21.12.3-0ubuntu1
konsole-kpart 4:21.12.3-0ubuntu1
kpackagetool5 5.92.0-0ubuntu1
krb5-locales 1.19.2-2ubuntu0.4
ktexteditor-data 5.92.0-0ubuntu1
ktexteditor-katepart 5.92.0-0ubuntu1
kwayland-data 4:5.92.0-0ubuntu1
kwin-common 4:5.24.7-0ubuntu0.2
kwin-data 4:5.24.7-0ubuntu0.2
kwin-style-breeze 4:5.24.7-0ubuntu0.2
kwin-x11 4:5.24.7-0ubuntu0.2
kwrite 4:21.12.3-0ubuntu1
less 590-1ubuntu0.22.04.3
liba52-0.7.4 0.7.4-20
libaa1 1.4p5-50build1
libaccounts-glib0 1.25-1
libaccounts-qt5-1 1.16-2
libaccountsservice0 22.07.5-2ubuntu1.5
libacl1 2.3.1-1
libaom3 3.3.0-1ubuntu0.1
libapparmor1 3.0.4-2ubuntu2.4
libappimage0 0.1.10+dfsg-0ubuntu1
libappstream4 0.15.2-2
libappstreamqt2 0.15.2-2
libapt-pkg6.0 2.4.13
libarchive13 3.6.0-1ubuntu1.5
libargon2-1 0~20171227-0.3
libaribb24-0 1.0.3-2
libasan6 11.4.0-1ubuntu1~22.04
libasound2 1.2.6.1-1ubuntu1
libasound2-data 1.2.6.1-1ubuntu1
libass9 1:0.15.2-1
libassuan0 2.5.5-1build1
libasyncns0 0.8-6build2
libatasmart4 0.19-5build2
libatk-bridge2.0-0 2.38.0-3
libatk1.0-0 2.36.0-3build1
libatk1.0-data 2.36.0-3build1
libatomic1 12.3.0-1ubuntu1~22.04.2
libatspi2.0-0 2.44.0-3
libattr1 1:2.5.1-1build1
libaudit-common 1:3.0.7-1build1
libaudit1 1:3.0.7-1build1
libavahi-client3 0.8-5ubuntu5.2
libavahi-common-data 0.8-5ubuntu5.2
libavahi-common3 0.8-5ubuntu5.2
libavc1394-0 0.5.4-5build2
libavcodec58 7:4.4.2-0ubuntu0.22.04.1
libavdevice58 7:4.4.2-0ubuntu0.22.04.1
libavfilter7 7:4.4.2-0ubuntu0.22.04.1
libavformat58 7:4.4.2-0ubuntu0.22.04.1
libavutil56 7:4.4.2-0ubuntu0.22.04.1
libbabeltrace1 1.5.8-2build1
libbinutils 2.38-4ubuntu2.6
libblas3 3.10.0-2ubuntu1
libblkid1 2.37.2-4ubuntu3.4
libblockdev-fs2 2.26-1ubuntu0.1
libblockdev-loop2 2.26-1ubuntu0.1
libblockdev-part-err2 2.26-1ubuntu0.1
libblockdev-part2 2.26-1ubuntu0.1
libblockdev-swap2 2.26-1ubuntu0.1
libblockdev-utils2 2.26-1ubuntu0.1
libblockdev2 2.26-1ubuntu0.1
libbluray2 1:1.3.1-1
libboost-regex1.74.0 1.74.0-14ubuntu3
libbpf0 1:0.5.0-1ubuntu22.04.1
libbrotli1 1.0.9-2build6
libbs2b0 3.1.0+dfsg-2.2build1
libbsd0 0.11.5-1
libbz2-1.0 1.0.8-5build1
libbz2-dev 1.0.8-5build1
libc-bin 2.35-0ubuntu3.14
libc-dev-bin 2.35-0ubuntu3.8
libc6 2.35-0ubuntu3.8
libc6-dev 2.35-0ubuntu3.8
libcaca0 0.99.beta19-2.2ubuntu4
libcairo-gobject2 1.16.0-5ubuntu2
libcairo2 1.16.0-5ubuntu2
libcanberra0 0.30-10ubuntu1.22.04.1
libcap-ng0 0.7.9-2.2build3
libcap2 1:2.44-1ubuntu0.22.04.1
libcap2-bin 1:2.44-1ubuntu0.22.04.1
libcbor0.8 0.8.0-2ubuntu1
libcc1-0 12.3.0-1ubuntu1~22.04.2
libcddb2 1.3.2-7fakesync1
libcdio-cdda2 10.2+2.0.0-1build3
libcdio-paranoia2 10.2+2.0.0-1build3
libcdio19 2.1.0-3ubuntu0.2
libchromaprint1 1.5.1-2
libcodec2-1.0 1.0.1-3
libcolorcorrect5 4:5.24.7-0ubuntu0.2
libcolord2 1.4.6-1
libcom-err2 1.46.5-2ubuntu1.2
libcommon-sense-perl 3.75-2build1
libcrypt-dev 1:4.4.27-1
libcrypt1 1:4.4.27-1
libcryptsetup12 2:2.4.3-1ubuntu1.2
libctf-nobfd0 2.38-4ubuntu2.6
libctf0 2.38-4ubuntu2.6
libcups2 2.4.1op1-1ubuntu4.11
libcurl3-gnutls 7.81.0-1ubuntu1.20
libcurl4 7.81.0-1ubuntu1.26
libdatrie1 0.2.13-2
libdav1d5 0.9.2-1
libdb5.3 5.3.28+dfsg1-0.8ubuntu3
libdbus-1-3 1.12.20-2ubuntu4.1
libdbusmenu-qt5-2 0.9.3+16.04.20160218-2build1
libdc1394-25 2.2.6-4
libdca0 0.0.7-2
libdconf1 0.40.0-3
libde265-0 1.0.8-1ubuntu0.3
libdebuginfod-common 0.186-1ubuntu0.1
libdebuginfod1 0.186-1ubuntu0.1
libdecor-0-0 0.1.0-3build1
libdeflate0 1.10-2
libdevmapper1.02.1 2:1.02.175-2.1ubuntu4
libdmtx0b 0.7.5-3
libdolphinvcs5 4:21.12.3-0ubuntu1
libdouble-conversion3 3.1.7-4
libdpkg-perl 1.21.1ubuntu2.3
libdrm-amdgpu1 2.4.113-2~ubuntu0.22.04.1
libdrm-common 2.4.113-2~ubuntu0.22.04.1
libdrm-intel1 2.4.113-2~ubuntu0.22.04.1
libdrm-nouveau2 2.4.113-2~ubuntu0.22.04.1
libdrm-radeon1 2.4.113-2~ubuntu0.22.04.1
libdrm2 2.4.113-2~ubuntu0.22.04.1
libdvbpsi10 1.3.3-1
libdvdnav4 6.1.1-1
libdvdread8 6.1.2-1
libdw1 0.186-1ubuntu0.1
libebml5 1.4.2-2
libedit2 3.1-20210910-1build1
libeditorconfig0 0.12.5-2
libegl-mesa0 23.2.1-1ubuntu3.1~22.04.3
libegl1 1.4.0-1
libelf1 0.186-1ubuntu0.1
libepoxy0 1.5.10-1
libepub0 0.2.2-4ubuntu3
liberror-perl 0.17029-1
libev4 1:4.33-1
libevdev2 1.12.1+dfsg-1
libevent-2.1-7 2.1.12-stable-1build3
libexiv2-27 0.27.5-3ubuntu1
libexpat1 2.4.7-1ubuntu0.5
libext2fs2 1.46.5-2ubuntu1.2
libfaad2 2.10.0-2
libfdisk1 2.37.2-4ubuntu3.4
libffi-dev 3.4.2-4
libffi8 3.4.2-4
libfftw3-double3 3.3.8-2ubuntu8
libfido2-1 1.10.0-1
libfile-readbackwards-perl 1.06-1
libflac8 1.3.3-2ubuntu0.2
libflite1 2.2-3
libfontconfig1 2.13.1-4.2ubuntu5
libfontenc1 1:1.1.4-1build3
libfreetype6 2.11.1+dfsg-1ubuntu0.2
libfribidi0 1.0.8-2ubuntu3.1
libfuse2 2.9.9-5ubuntu3
libgamin0 0.1.10-6
libgbm1 23.2.1-1ubuntu3.1~22.04.3
libgcc-11-dev 11.4.0-1ubuntu1~22.04
libgcc-s1 12.3.0-1ubuntu1~22.04.2
libgcrypt20 1.9.4-3ubuntu3
libgdbm-compat4 1.23-1
libgdbm6 1.23-1
libgdk-pixbuf-2.0-0 2.42.8+dfsg-1ubuntu0.3
libgdk-pixbuf2.0-common 2.42.8+dfsg-1ubuntu0.3
libgfortran5 12.3.0-1ubuntu1~22.04.2
libgif7 5.1.9-2ubuntu0.1
libgirepository-1.0-1 1.72.0-1
libgl1 1.4.0-1
libgl1-mesa-dri 23.2.1-1ubuntu3.1~22.04.3
libglapi-mesa 23.2.1-1ubuntu3.1~22.04.3
libgles2 1.4.0-1
libglib2.0-0 2.72.4-0ubuntu2.4
libglib2.0-bin 2.72.4-0ubuntu2.4
libglib2.0-data 2.72.4-0ubuntu2.4
libglvnd0 1.4.0-1
libglx-mesa0 23.2.1-1ubuntu3.1~22.04.3
libglx0 1.4.0-1
libgme0 0.6.3-2
libgmp10 2:6.2.1+dfsg-3ubuntu1
libgnutls30 3.7.3-4ubuntu1.5
libgomp1 12.3.0-1ubuntu1~22.04.2
libgpg-error-l10n 1.43-3
libgpg-error0 1.43-3
libgpgme11 1.16.0-1.2ubuntu4.2
libgpgmepp6 1.16.0-1.2ubuntu4.2
libgpm2 1.20.7-10build1
libgps28 3.22-4ubuntu2
libgraphite2-3 1.3.14-1build2
libgsm1 1.0.19-1
libgssapi-krb5-2 1.19.2-2ubuntu0.4
libgstreamer1.0-0 1.20.3-0ubuntu1.1
libgtk-3-0 3.24.33-1ubuntu2.2
libgtk-3-common 3.24.33-1ubuntu2.2
libgtk2.0-0 2.24.33-2ubuntu2.1
libgtk2.0-common 2.24.33-2ubuntu2.1
libgudev-1.0-0 1:237-2build1
libharfbuzz0b 2.7.4-1ubuntu3.1
libheif1 1.12.0-2build1
libhogweed6 3.7.3-1build2
libibus-1.0-5 1.5.26-4
libice6 2:1.0.10-1build2
libicu70 70.1-2
libid3tag0 0.15.1b-14
libidn12 1.38-4ubuntu1
libidn2-0 2.3.2-2build1
libiec61883-0 1.2.0-4build3
libimlib2 1.7.4-1build1
libimobiledevice6 1.3.0-6build3
libinotifytools0 3.22.1.0-2
libinput-bin 1.20.0-1ubuntu0.3
libinput10 1.20.0-1ubuntu0.3
libip4tc2 1.8.7-1ubuntu5.2
libip6tc2 1.8.7-1ubuntu5.2
libipt2 2.0.5-1
libisl23 0.24-2build1
libitm1 12.3.0-1ubuntu1~22.04.2
libixml10 1:1.8.4-2ubuntu2
libjack-jackd2-0 1.9.20~dfsg-1
libjbig0 2.1-3.1ubuntu0.22.04.1
libjpeg-turbo8 2.1.2-0ubuntu1
libjpeg8 8c-2ubuntu10
libjq1 1.6-2.1ubuntu3.2
libjs-underscore 1.13.2~dfsg-2
libjson-c5 0.15-3~ubuntu1.22.04.2
libjson-perl 4.04000-1
libjson-xs-perl 4.040-0ubuntu0.22.04.1
libk5crypto3 1.19.2-2ubuntu0.4
libkaccounts2 4:21.12.3-0ubuntu1
libkate1 0.4.1-11build1
libkdecorations2-5v5 4:5.24.4-0ubuntu1
libkdecorations2private9 4:5.24.4-0ubuntu1
libkeyutils1 1.6.1-2ubuntu3
libkf5activities5 5.92.0-0ubuntu1
libkf5activitiesstats1 5.92.0-0ubuntu1
libkf5archive5 5.92.0-0ubuntu1
libkf5attica5 5.92.0-0ubuntu1
libkf5auth-data 5.92.0-0ubuntu1
libkf5auth5 5.92.0-0ubuntu1
libkf5authcore5 5.92.0-0ubuntu1
libkf5baloo5 5.92.0-0ubuntu1
libkf5balooengine5 5.92.0-0ubuntu1
libkf5baloowidgets-data 4:21.12.3-0ubuntu1
libkf5baloowidgets5 4:21.12.3-0ubuntu1
libkf5bookmarks-data 5.92.0-0ubuntu1
libkf5bookmarks5 5.92.0-0ubuntu1
libkf5calendarevents5 5.92.0-0ubuntu1
libkf5codecs-data 5.92.0-0ubuntu1
libkf5codecs5 5.92.0-0ubuntu1
libkf5completion-data 5.92.0-0ubuntu1
libkf5completion5 5.92.0-0ubuntu1
libkf5config-bin 5.92.0-0ubuntu1
libkf5config-data 5.92.0-0ubuntu1
libkf5configcore5 5.92.0-0ubuntu1
libkf5configgui5 5.92.0-0ubuntu1
libkf5configwidgets-data 5.92.0-0ubuntu1
libkf5configwidgets5 5.92.0-0ubuntu1
libkf5coreaddons-data 5.92.0-0ubuntu1
libkf5coreaddons5 5.92.0-0ubuntu1
libkf5crash5 5.92.0-0ubuntu1
libkf5dbusaddons-data 5.92.0-0ubuntu1
libkf5dbusaddons5 5.92.0-0ubuntu1
libkf5declarative-data 5.92.0-0ubuntu1
libkf5declarative5 5.92.0-0ubuntu1
libkf5doctools5 5.92.0-0ubuntu1
libkf5filemetadata-bin 5.92.0-0ubuntu1
libkf5filemetadata-data 5.92.0-0ubuntu1
libkf5filemetadata3 5.92.0-0ubuntu1
libkf5globalaccel-bin 5.92.0-0ubuntu1
libkf5globalaccel-data 5.92.0-0ubuntu1
libkf5globalaccel5 5.92.0-0ubuntu1
libkf5globalaccelprivate5 5.92.0-0ubuntu1
libkf5guiaddons-bin 5.92.0-0ubuntu1
libkf5guiaddons-data 5.92.0-0ubuntu1
libkf5guiaddons5 5.92.0-0ubuntu1
libkf5holidays-data 1:5.92.0-0ubuntu1
libkf5holidays5 1:5.92.0-0ubuntu1
libkf5i18n-data 5.92.0-0ubuntu2
libkf5i18n5 5.92.0-0ubuntu2
libkf5iconthemes-data 5.92.0-0ubuntu1
libkf5iconthemes5 5.92.0-0ubuntu1
libkf5idletime5 5.92.0-0ubuntu1
libkf5itemmodels5 5.92.0-0ubuntu1
libkf5itemviews-data 5.92.0-0ubuntu1
libkf5itemviews5 5.92.0-0ubuntu1
libkf5jobwidgets-data 5.92.0-0ubuntu1
libkf5jobwidgets5 5.92.0-0ubuntu1
libkf5kcmutils-data 5.92.0-0ubuntu1
libkf5kcmutils5 5.92.0-0ubuntu1
libkf5kdelibs4support-data 5.92.0-0ubuntu1
libkf5kdelibs4support5 5.92.0-0ubuntu1
libkf5kiocore5 5.92.0-0ubuntu1
libkf5kiofilewidgets5 5.92.0-0ubuntu1
libkf5kiogui5 5.92.0-0ubuntu1
libkf5kiontlm5 5.92.0-0ubuntu1
libkf5kiowidgets5 5.92.0-0ubuntu1
libkf5kirigami2-5 5.92.0-0ubuntu2
libkf5networkmanagerqt6 5.92.0-0ubuntu1
libkf5newstuff-data 5.92.0-0ubuntu1.1
libkf5newstuff5 5.92.0-0ubuntu1.1
libkf5newstuffcore5 5.92.0-0ubuntu1.1
libkf5notifications-data 5.92.0-0ubuntu1
libkf5notifications5 5.92.0-0ubuntu1
libkf5notifyconfig-data 5.92.0-0ubuntu1
libkf5notifyconfig5 5.92.0-0ubuntu1
libkf5package-data 5.92.0-0ubuntu1
libkf5package5 5.92.0-0ubuntu1
libkf5parts-data 5.92.0-0ubuntu1
libkf5parts5 5.92.0-0ubuntu1
libkf5people-data 5.92.0-0ubuntu1
libkf5people5 5.92.0-0ubuntu1
libkf5peoplebackend5 5.92.0-0ubuntu1
libkf5peoplewidgets5 5.92.0-0ubuntu1
libkf5plasma5 5.92.0-0ubuntu1
libkf5plasmaquick5 5.92.0-0ubuntu1
libkf5prison5 5.92.0-0ubuntu1
libkf5pty-data 5.92.0-0ubuntu1
libkf5pty5 5.92.0-0ubuntu1
libkf5quickaddons5 5.92.0-0ubuntu1
libkf5runner5 5.92.0-0ubuntu1
libkf5screen-bin 4:5.24.4-0ubuntu1
libkf5screen7 4:5.24.4-0ubuntu1
libkf5service-bin 5.92.0-0ubuntu1
libkf5service-data 5.92.0-0ubuntu1
libkf5service5 5.92.0-0ubuntu1
libkf5solid5 5.92.0-0ubuntu1
libkf5solid5-data 5.92.0-0ubuntu1
libkf5sonnet5-data 5.92.0-0ubuntu1
libkf5sonnetcore5 5.92.0-0ubuntu1
libkf5sonnetui5 5.92.0-0ubuntu1
libkf5style5 5.92.0-0ubuntu1
libkf5su-bin 5.92.0-0ubuntu1.1
libkf5su-data 5.92.0-0ubuntu1.1
libkf5su5 5.92.0-0ubuntu1.1
libkf5syndication5abi1 1:5.92.0-0ubuntu1
libkf5syntaxhighlighting-data 5.92.0-0ubuntu1
libkf5syntaxhighlighting5 5.92.0-0ubuntu1
libkf5sysguard-data 4:5.24.6-0ubuntu0.2
libkf5texteditor-bin 5.92.0-0ubuntu1
libkf5texteditor5 5.92.0-0ubuntu1
libkf5textwidgets-data 5.92.0-0ubuntu1
libkf5textwidgets5 5.92.0-0ubuntu1
libkf5threadweaver5 5.92.0-0ubuntu1
libkf5wallet-bin 5.92.0-0ubuntu1
libkf5wallet-data 5.92.0-0ubuntu1
libkf5wallet5 5.92.0-0ubuntu1
libkf5waylandclient5 4:5.92.0-0ubuntu1
libkf5waylandserver5 4:5.92.0-0ubuntu1
libkf5widgetsaddons-data 5.92.0-0ubuntu1
libkf5widgetsaddons5 5.92.0-0ubuntu1
libkf5windowsystem-data 5.92.0-0ubuntu1
libkf5windowsystem5 5.92.0-0ubuntu1
libkf5xmlgui-data 5.92.0-0ubuntu2
libkf5xmlgui5 5.92.0-0ubuntu2
libkfontinst5 4:5.24.7-0ubuntu0.2
libkfontinstui5 4:5.24.7-0ubuntu0.2
libkmod2 29-1ubuntu1
libkrb5-3 1.19.2-2ubuntu0.4
libkrb5support0 1.19.2-2ubuntu0.4
libksba8 1.6.0-2ubuntu0.2
libkscreenlocker5 5.24.4-0ubuntu1
libksgrd9 4:5.24.6-0ubuntu0.2
libksysguardformatter1 4:5.24.6-0ubuntu0.2
libksysguardsensorfaces1 4:5.24.6-0ubuntu0.2
libksysguardsensors1 4:5.24.6-0ubuntu0.2
libksysguardsystemstats1 4:5.24.6-0ubuntu0.2
libkuserfeedbackcore1 1.2.0-2
libkuserfeedbackwidgets1 1.2.0-2
libkwalletbackend5-5 5.92.0-0ubuntu1
libkwaylandserver5 5.24.6-0ubuntu0.2
libkwineffects13 4:5.24.7-0ubuntu0.2
libkwinglutils13 4:5.24.7-0ubuntu0.2
libkwinxrenderutils13 4:5.24.7-0ubuntu0.2
libkworkspace5-5 4:5.24.7-0ubuntu0.2
liblapack3 3.10.0-2ubuntu1
liblayershellqtinterface5 5.24.6-0ubuntu0.2
liblcms2-2 2.12~rc1-2build2
libldap-2.5-0 2.5.18+dfsg-0ubuntu0.22.04.2
libldap-common 2.5.18+dfsg-0ubuntu0.22.04.2
liblilv-0-0 0.24.12-2
liblirc-client0 0.10.1-6.3ubuntu1
libllvm15 1:15.0.7-0ubuntu0.22.04.3
liblmdb0 0.9.24-1build2
liblocale-gettext-perl 1.07-4build3
liblqr-1-0 0.4.2-2.1
liblsan0 12.3.0-1ubuntu1~22.04.2
libltdl7 2.4.6-15build2
liblua5.2-0 5.2.4-2
liblz4-1 1.9.3-2build2
liblzma-dev 5.2.5-2ubuntu1
liblzma5 5.2.5-2ubuntu1
liblzo2-2 2.10-2build3
libmad0 0.15.1b-10ubuntu1
libmagickcore-6.q16-6 8:6.9.11.60+dfsg-1.3ubuntu0.22.04.5
libmagickwand-6.q16-6 8:6.9.11.60+dfsg-1.3ubuntu0.22.04.5
libmatroska7 1.6.3-2
libmd0 1.0.4-1build1
libmd4c0 0.4.8-1
libmfx1 22.3.0-1
libminizip1 1.1-8build1
libmnl0 1.0.4-3build2
libmount1 2.37.2-4ubuntu3.4
libmp3lame0 3.100-3build2
libmpc3 1.2.1-2build1
libmpcdec6 2:0.1~r495-2
libmpdec3 2.5.1-2build2
libmpeg2-4 0.5.1-9
libmpfr6 4.1.0-3build3
libmpg123-0 1.29.3-1ubuntu0.1
libmtdev1 1.1.6-1build4
libmtp-common 1.1.19-1build1
libmtp9 1.1.19-1build1
libmysofa1 1.2.1~dfsg0-1
libncurses-dev 6.3-2ubuntu0.2
libncurses6 6.3-2ubuntu0.2
libncursesw6 6.3-2ubuntu0.2
libnetfilter-conntrack3 1.0.9-1
libnettle8 3.7.3-1build2
libnfnetlink0 1.0.1-3build3
libnfs13 4.0.0-1build2
libnftnl11 1.2.1-1build1
libnghttp2-14 1.43.0-1ubuntu0.2
libnl-3-200 3.5.0-0.1
libnl-genl-3-200 3.5.0-0.1
libnorm1 1.5.9+dfsg-2
libnotificationmanager1 4:5.24.7-0ubuntu0.2
libnpth0 1.6-3build2
libnsl-dev 1.3.0-2build2
libnsl2 1.3.0-2build2
libnspr4 2:4.35-0ubuntu0.22.04.1
libnss-nis 3.1-0ubuntu6
libnss-nisplus 1.3-0ubuntu6
libnss3 2:3.98-0ubuntu0.22.04.2
libnuma1 2.0.14-3ubuntu2
libogg0 1.3.5-0ubuntu3
libonig5 6.9.7.1-2build1
libopenal-data 1:1.19.1-2build3
libopenal1 1:1.19.1-2build3
libopengl0 1.4.0-1
libopenjp2-7 2.4.0-6ubuntu0.4
libopenmpt-modplug1 0.8.9.0-openmpt1-2
libopenmpt0 0.6.1-1
libopus0 1.3.1-0.1build2
libp11-kit0 0.24.0-6build1
libpackagekit-glib2-18 1.2.5-2ubuntu3
libpackagekitqt5-1 1.0.2-1
libpam-modules 1.4.0-11ubuntu2.4
libpam-modules-bin 1.4.0-11ubuntu2.4
libpam-runtime 1.4.0-11ubuntu2.4
libpam-systemd 249.11-0ubuntu3.17
libpam0g 1.4.0-11ubuntu2.4
libpango-1.0-0 1.50.6+ds-2ubuntu1
libpangocairo-1.0-0 1.50.6+ds-2ubuntu1
libpangoft2-1.0-0 1.50.6+ds-2ubuntu1
libparted-fs-resize0 3.4-2build1
libparted2 3.4-2build1
libpciaccess0 0.16-3
libpcre2-16-0 10.39-3ubuntu0.1
libpcre2-8-0 10.39-3ubuntu0.1
libpcre3 2:8.39-13ubuntu0.22.04.1
libpcsclite1 1.9.5-3ubuntu1
libperl5.34 5.34.0-3ubuntu1.3
libpgm-5.3-0 5.3.128~dfsg-2
libphonon4qt5-4 4:4.11.1-4
libphonon4qt5-data 4:4.11.1-4
libpipewire-0.3-0 0.3.48-1ubuntu3
libpixman-1-0 0.40.0-1ubuntu0.22.04.1
libpkcs11-helper1 1.28-1ubuntu0.22.04.1
libplacebo192 4.192.1-1
libplasma-geolocation-interface5 4:5.24.7-0ubuntu0.2
libplist3 2.2.0-6build2
libpng16-16 1.6.37-3build5
libpocketsphinx3 0.8.0+real5prealpha+1-14ubuntu1
libpolkit-agent-1-0 0.105-33
libpolkit-gobject-1-0 0.105-33
libpolkit-qt5-1-1 0.114.0-2
libpoppler-qt5-1 22.02.0-2ubuntu0.11
libpoppler118 22.02.0-2ubuntu0.11
libpopt0 1.18-3build1
libpostproc55 7:4.4.2-0ubuntu0.22.04.1
libpq5 18.6-1.pgdg22.04+2
libprocesscore9 4:5.24.6-0ubuntu0.2
libprocessui9 4:5.24.6-0ubuntu0.2
libprocps8 2:3.3.17-6ubuntu2.1
libprotobuf-lite23 3.12.4-1ubuntu7.22.04.4
libpsl5 0.21.0-1.2build2
libpulse-mainloop-glib0 1:15.99.1+dfsg1-1ubuntu2.2
libpulse0 1:15.99.1+dfsg1-1ubuntu2.2
libpython3-stdlib 3.10.6-1~22.04.1
libpython3.10 3.10.12-1~22.04.7
libpython3.10-minimal 3.10.12-1~22.04.7
libpython3.10-stdlib 3.10.12-1~22.04.7
libqaccessibilityclient-qt5-0 0.4.1-1build1
libqalculate-data 3.22.0-3build1
libqalculate22 3.22.0-3build1
libqmobipocket2 4:21.12.3-0ubuntu1
libqrencode4 4.1.1-1
libqt5concurrent5 5.15.3+dfsg-2ubuntu0.2
libqt5core5a 5.15.3+dfsg-2ubuntu0.2
libqt5dbus5 5.15.3+dfsg-2ubuntu0.2
libqt5gui5 5.15.3+dfsg-2ubuntu0.2
libqt5multimedia5 5.15.3-1
libqt5multimediaquick5 5.15.3-1
libqt5network5 5.15.3+dfsg-2ubuntu0.2
libqt5positioning5 5.15.3+dfsg-3
libqt5printsupport5 5.15.3+dfsg-2ubuntu0.2
libqt5qml5 5.15.3+dfsg-1
libqt5qmlmodels5 5.15.3+dfsg-1
libqt5qmlworkerscript5 5.15.3+dfsg-1
libqt5quick5 5.15.3+dfsg-1
libqt5quickcontrols2-5 5.15.3+dfsg-1
libqt5quickshapes5 5.15.3+dfsg-1
libqt5quicktemplates2-5 5.15.3+dfsg-1
libqt5quickwidgets5 5.15.3+dfsg-1
libqt5sql5 5.15.3+dfsg-2ubuntu0.2
libqt5sql5-sqlite 5.15.3+dfsg-2ubuntu0.2
libqt5svg5 5.15.3-1
libqt5texttospeech5 5.15.3-1
libqt5waylandclient5 5.15.3-1
libqt5webchannel5 5.15.3-1
libqt5webengine-data 5.15.9+dfsg-1
libqt5webenginecore5 5.15.9+dfsg-1
libqt5webenginewidgets5 5.15.9+dfsg-1
libqt5widgets5 5.15.3+dfsg-2ubuntu0.2
libqt5x11extras5 5.15.3-1
libqt5xml5 5.15.3+dfsg-2ubuntu0.2
libquadmath0 12.3.0-1ubuntu1~22.04.2
librabbitmq4 0.10.0-1ubuntu2
libraw1394-11 2.1.2-2build2
libre2-9 20220201+dfsg-1
libreadline-dev 8.1.2-1
libreadline8 8.1.2-1
libresid-builder0c2a 2.1.1-15ubuntu2
librsvg2-2 2.52.5+dfsg-3ubuntu0.2
librtmp1 2.4+20151223.gitfa8646d.1-2build4
librubberband2 2.0.0-2
libsamplerate0 0.2.2-1build1
libsasl2-2 2.1.27+dfsg2-3ubuntu1.2
libsasl2-modules 2.1.27+dfsg2-3ubuntu1.2
libsasl2-modules-db 2.1.27+dfsg2-3ubuntu1.2
libscim8v5 1.4.18+git20211204-0.1
libsdl-image1.2 1.2.12-13build1
libsdl1.2debian 1.2.15+dfsg2-6
libsdl2-2.0-0 2.0.20+dfsg-2ubuntu1.22.04.1
libseccomp2 2.5.3-2ubuntu2
libsecret-1-0 0.20.5-2
libsecret-common 0.20.5-2
libselinux1 3.3-1build2
libsemanage-common 3.3-1build2
libsemanage2 3.3-1build2
libsensors-config 1:3.6.0-7ubuntu1
libsensors5 1:3.6.0-7ubuntu1
libsepol2 3.3-1build1
libserd-0-0 0.30.10-2
libshine3 3.1.1-2
libshout3 2.4.5-1build3
libsidplay2 2.1.1-15ubuntu2
libsignon-qt5-1 8.59+17.10.20170606-0ubuntu3
libslang2 2.3.2-5build4
libslirp0 4.6.1-1build1
libsm6 2:1.2.3-1build2
libsmartcols1 2.37.2-4ubuntu3.4
libsnappy1v5 1.1.8-1build3
libsndfile1 1.0.31-2ubuntu0.2
libsndio7.0 1.8.1-1.1
libsodium23 1.0.18-1build2
libsord-0-0 0.16.8-2
libsource-highlight-common 3.1.9-4.1build2
libsource-highlight4v5 3.1.9-4.1build2
libsoxr0 0.1.3-4build2
libspa-0.2-modules 0.3.48-1ubuntu3
libspatialaudio0 0.3.0+git20180730+dfsg1-2build1
libspeex1 1.2~rc1.2-1.1ubuntu3
libspeexdsp1 1.2~rc1.2-1.1ubuntu3
libsphinxbase3 0.8+5prealpha+1-13build1
libsqlite3-0 3.37.2-2ubuntu0.3
libsqlite3-dev 3.37.2-2ubuntu0.3
libsquashfuse0 0.1.103-3
libsratom-0-0 0.6.8-1
libsrt1.4-gnutls 1.4.4-4
libss2 1.46.5-2ubuntu1.2
libssh-4 0.9.6-2ubuntu0.22.04.3
libssh-gcrypt-4 0.9.6-2ubuntu0.22.04.5
libssh2-1 1.10.0-3
libssl-dev 3.0.2-0ubuntu1.26
libssl3 3.0.2-0ubuntu1.26
libstdc++-11-dev 11.4.0-1ubuntu1~22.04
libstdc++6 12.3.0-1ubuntu1~22.04.2
libstemmer0d 2.2.0-1build1
libswresample3 7:4.4.2-0ubuntu0.22.04.1
libswscale5 7:4.4.2-0ubuntu0.22.04.1
libsystemd0 249.11-0ubuntu3.17
libtag1v5 1.11.1+dfsg.1-3ubuntu3
libtag1v5-vanilla 1.11.1+dfsg.1-3ubuntu3
libtaskmanager6 4:5.24.7-0ubuntu0.2
libtasn1-6 4.18.0-4build1
libtcl8.6 8.6.12+dfsg-1build1
libtdb1 1.4.5-2build1
libtext-charwidth-perl 0.04-10build3
libtext-iconv-perl 1.7-7build3
libtext-wrapi18n-perl 0.06-9
libthai-data 0.1.29-1build1
libthai0 0.1.29-1build1
libtheora0 1.1.1+dfsg.1-15ubuntu4
libtiff5 4.3.0-6ubuntu0.10
libtinfo6 6.3-2ubuntu0.2
libtirpc-common 1.3.2-2ubuntu0.1
libtirpc-dev 1.3.2-2ubuntu0.1
libtirpc3 1.3.2-2ubuntu0.1
libtsan0 11.4.0-1ubuntu1~22.04
libtwolame0 0.4.0-2build2
libtypes-serialiser-perl 1.01-1
libubsan1 12.3.0-1ubuntu1~22.04.2
libuchardet0 0.0.7-1build2
libudev1 249.11-0ubuntu3.17
libudfread0 1.1.2-1
libudisks2-0 2.9.4-1ubuntu2.3
libunistring2 1.0-1
libunwind8 1.3.2-2build2.1
libupnp13 1:1.8.4-2ubuntu2
libupower-glib3 0.99.17-1
libusb-1.0-0 2:1.0.25-1ubuntu2
libusbmuxd6 2.0.2-3build2
libuuid1 2.37.2-4ubuntu3.4
libuv1 1.43.0-1ubuntu0.1
libva-drm2 2.14.0-1
libva-wayland2 2.14.0-1
libva-x11-2 2.14.0-1
libva2 2.14.0-1
libvdpau1 1.4-3build2
libvidstab1.1 1.1.0-2
libvlc5 3.0.16-1build7
libvlccore9 3.0.16-1build7
libvorbis0a 1.3.7-1build2
libvorbisenc2 1.3.7-1build2
libvorbisfile3 1.3.7-1build2
libvpx7 1.11.0-2ubuntu2.4
libvulkan1 1.3.204.1-2
libwacom-common 2.2.0-1
libwacom9 2.2.0-1
libwayland-client0 1.20.0-1ubuntu0.1
libwayland-cursor0 1.20.0-1ubuntu0.1
libwayland-egl1 1.20.0-1ubuntu0.1
libwayland-server0 1.20.0-1ubuntu0.1
libweather-ion7 4:5.24.7-0ubuntu0.2
libwebp7 1.2.2-2ubuntu0.22.04.2
libwebpdemux2 1.2.2-2ubuntu0.22.04.2
libwebpmux3 1.2.2-2ubuntu0.22.04.2
libwebrtc-audio-processing1 0.3.1-0ubuntu5
libwrap0 7.6.q-31build2
libx11-6 2:1.7.5-1ubuntu0.3
libx11-data 2:1.7.5-1ubuntu0.3
libx11-xcb1 2:1.7.5-1ubuntu0.3
libx264-163 2:0.163.3060+git5db6aa6-2build1
libx265-199 3.5-2
libxau6 1:1.0.9-1build5
libxaw7 2:1.0.14-1
libxcb-composite0 1.14-3ubuntu3
libxcb-cursor0 0.1.1-4ubuntu1
libxcb-damage0 1.14-3ubuntu3
libxcb-dri2-0 1.14-3ubuntu3
libxcb-dri3-0 1.14-3ubuntu3
libxcb-glx0 1.14-3ubuntu3
libxcb-icccm4 0.4.1-1.1build2
libxcb-image0 0.4.0-2
libxcb-keysyms1 0.4.0-1build3
libxcb-present0 1.14-3ubuntu3
libxcb-randr0 1.14-3ubuntu3
libxcb-record0 1.14-3ubuntu3
libxcb-render-util0 0.3.9-1build3
libxcb-render0 1.14-3ubuntu3
libxcb-res0 1.14-3ubuntu3
libxcb-shape0 1.14-3ubuntu3
libxcb-shm0 1.14-3ubuntu3
libxcb-sync1 1.14-3ubuntu3
libxcb-util1 0.4.0-1build2
libxcb-xfixes0 1.14-3ubuntu3
libxcb-xinerama0 1.14-3ubuntu3
libxcb-xinput0 1.14-3ubuntu3
libxcb-xkb1 1.14-3ubuntu3
libxcb-xv0 1.14-3ubuntu3
libxcb1 1.14-3ubuntu3
libxcomposite1 1:0.4.5-1build2
libxcursor1 1:1.2.0-2build4
libxdamage1 1:1.1.5-2build2
libxdmcp6 1:1.1.3-0ubuntu5
libxext6 2:1.3.4-1build1
libxfixes3 1:6.0.0-1
libxfont2 1:2.0.5-1build1
libxft2 2.3.4-1
libxi6 2:1.8-1build1
libxinerama1 2:1.1.4-3
libxkbcommon-x11-0 1.4.0-1
libxkbcommon0 1.4.0-1
libxkbfile1 1:1.1.0-1build3
libxml2 2.9.13+dfsg-1ubuntu0.4
libxmlb2 0.3.6-2build1
libxmu6 2:1.1.3-3
libxmuu1 2:1.1.3-3
libxpm4 1:3.5.12-1ubuntu0.22.04.2
libxrandr2 2:1.5.2-1build1
libxrender1 1:0.9.10-1build4
libxres1 2:1.2.1-1
libxshmfence1 1.3-1build4
libxslt1.1 1.1.34-4ubuntu0.22.04.4
libxss1 1:1.2.3-1build2
libxt6 1:1.2.1-1
libxtables12 1.8.7-1ubuntu5.2
libxtst6 2:1.2.3-1build4
libxv1 2:1.0.11-1build2
libxvidcore4 2:1.3.7-1
libxxf86dga1 2:1.1.5-0ubuntu3
libxxf86vm1 1:1.1.4-1build3
libxxhash0 0.8.1-1
libyaml-0-2 0.2.2-1build2
libzimg2 3.0.3+ds1-1
libzip4 1.7.3-1ubuntu2
libzmq5 4.3.4-2
libzstd1 1.4.8+dfsg-3build1
libzvbi-common 0.2.35-19
libzvbi0 0.2.35-19
libzxingcore1 1.2.0-1
linux-libc-dev 5.15.0-130.140
locales 2.35-0ubuntu3.14
logrotate 3.19.0-1ubuntu1.1
logsave 1.46.5-2ubuntu1.2
lsb-base 11.1.0ubuntu4
lsb-release 11.1.0ubuntu4
lto-disabled-list 24
make 4.3-4.1build1
media-types 7.0.0
milou 4:5.24.6-0ubuntu0.1
mount 2.37.2-4ubuntu3.4
nano 6.2-1ubuntu0.1
ncurses-bin 6.3-2ubuntu0.1
netbase 6.3
ngrok 3.19.0
nodejs 20.18.1-1nodesource1
ocl-icd-libopencl1 2.2.14-3
openjdk-17-jdk 17.0.13+11-2ubuntu1~22.04
openjdk-17-jdk-headless 17.0.13+11-2ubuntu1~22.04
openjdk-17-jre 17.0.13+11-2ubuntu1~22.04
openjdk-17-jre-headless 17.0.13+11-2ubuntu1~22.04
openssh-client 1:8.9p1-3ubuntu0.10
openssl 3.0.2-0ubuntu1.18
openvpn 2.5.11-0ubuntu0.22.04.1
oxygen-sounds 4:5.24.6-0ubuntu0.1
packagekit 1.2.5-2ubuntu3
parted 3.4-2build1
passwd 1:4.8.1-2ubuntu2.2
patch 2.7.6-7build2
pci.ids 0.0~2022.01.22-1ubuntu0.1
perl 5.34.0-3ubuntu1.3
perl-base 5.34.0-3ubuntu1.3
perl-modules-5.34 5.34.0-3ubuntu1.3
phonon4qt5 4:4.11.1-4
phonon4qt5-backend-vlc 0.11.3-1
pigz 2.6-1
pinentry-curses 1.1.1-1build2
pkexec 0.105-33
plasma-desktop 4:5.24.7-0ubuntu0.1
plasma-desktop-data 4:5.24.7-0ubuntu0.1
plasma-framework 5.92.0-0ubuntu1
plasma-integration 5.24.4-0ubuntu1
plasma-workspace 4:5.24.7-0ubuntu0.2
plasma-workspace-data 4:5.24.7-0ubuntu0.2
policykit-1 0.105-33
polkit-kde-agent-1 4:5.24.4-0ubuntu1
polkitd 0.105-33
postgresql-16 16.15-1.pgdg22.04+2
postgresql-16-pgvector 0.8.6-1.pgdg22.04+1
postgresql-client-16 16.15-1.pgdg22.04+2
postgresql-client-common 293.pgdg22.04+1
postgresql-common 293.pgdg22.04+1
procps 2:3.3.17-6ubuntu2.1
psmisc 23.4-2build3
publicsuffix 20211207.1025-1
python-apt-common 2.4.0ubuntu4
python-is-python3 3.9.2-2
python3 3.10.6-1~22.04.1
python3-apt 2.4.0ubuntu4
python3-attr 21.2.0-1
python3-backcall 0.2.0-2
python3-blinker 1.4+dfsg1-0.4
python3-botocore 1.23.34+repack-1
python3-certifi 2020.6.20-1
python3-cffi-backend 1.15.0-1build2
python3-chardet 4.0.0-1
python3-colorama 0.4.4-1
python3-cryptography 3.4.8-1ubuntu2.2
python3-dateutil 2.8.1-6
python3-dbus 1.2.18-3build1
python3-decorator 4.4.2-0ubuntu1
python3-distro 1.7.0-1
python3-distutils 3.10.8-1~22.04
python3-docutils 0.17.1+dfsg-2
python3-entrypoints 0.4-1
python3-gi 3.42.1-0ubuntu1
python3-httplib2 0.20.2-2
python3-idna 3.3-1ubuntu0.1
python3-importlib-metadata 4.6.4-1
python3-ipykernel 6.7.0-1
python3-ipython 7.31.1-1
python3-ipython-genutils 0.2.0-5
python3-jedi 0.18.0-1
python3-jeepney 0.7.1-3
python3-jmespath 0.10.0-1
python3-jsonschema 3.2.0-0ubuntu2
python3-jupyter-client 7.1.2-1
python3-jupyter-console 6.4.0-3
python3-jupyter-core 4.9.1-1
python3-jwt 2.3.0-1ubuntu0.2
python3-keyring 23.5.0-1
python3-launchpadlib 1.10.16-1
python3-lazr.restfulclient 0.14.4-1
python3-lazr.uri 1.0.6-2
python3-lib2to3 3.10.8-1~22.04
python3-matplotlib-inline 0.1.3-1
python3-minimal 3.10.6-1~22.04.1
python3-more-itertools 8.10.0-2
python3-nbformat 5.1.3-1
python3-nest-asyncio 1.5.4-1
python3-oauthlib 3.2.0-1ubuntu0.1
python3-parso 0.8.1-1
python3-pexpect 4.8.0-2ubuntu1
python3-pickleshare 0.7.5-5
python3-pip 22.0.2+dfsg-1ubuntu0.5
python3-pip-whl 22.0.2+dfsg-1ubuntu0.5
python3-pkg-resources 59.6.0-1.2ubuntu0.22.04.2
python3-prompt-toolkit 3.0.28-1
python3-ptyprocess 0.7.0-3
python3-py 1.10.0-1
python3-pyasn1 0.4.8-1
python3-pygments 2.11.2+dfsg-2ubuntu0.1
python3-pyparsing 2.4.7-1
python3-pyrsistent 0.18.1-1build1
python3-requests 2.25.1+dfsg-2ubuntu0.1
python3-roman 3.3-1
python3-rsa 4.8-1
python3-s3transfer 0.5.0-1
python3-secretstorage 3.3.1-1
python3-setuptools 59.6.0-1.2ubuntu0.22.04.2
python3-setuptools-whl 59.6.0-1.2ubuntu0.22.04.2
python3-six 1.16.0-3ubuntu1
python3-software-properties 0.99.22.9
python3-tornado 6.1.0-3build1
python3-traitlets 5.1.1-1
python3-urllib3 1.26.5-1~exp1ubuntu0.2
python3-venv 3.10.6-1~22.04.1
python3-wadllib 1.3.6-1
python3-wcwidth 0.2.5+dfsg1-1
python3-wheel 0.37.1-2ubuntu0.22.04.1
python3-yaml 5.4.1-1ubuntu1
python3-zipp 1.0.0-3ubuntu0.1
python3-zmq 22.3.0-1build1
python3.10 3.10.12-1~22.04.7
python3.10-minimal 3.10.12-1~22.04.7
python3.10-venv 3.10.12-1~22.04.7
qdbus-qt5 5.15.3-1
qml-module-org-kde-activities 5.92.0-0ubuntu1
qml-module-org-kde-draganddrop 5.92.0-0ubuntu1
qml-module-org-kde-kcm 5.92.0-0ubuntu1
qml-module-org-kde-kconfig 5.92.0-0ubuntu1
qml-module-org-kde-kcoreaddons 5.92.0-0ubuntu1
qml-module-org-kde-kholidays 1:5.92.0-0ubuntu1
qml-module-org-kde-kirigami2 5.92.0-0ubuntu2
qml-module-org-kde-kitemmodels 5.92.0-0ubuntu1
qml-module-org-kde-kquickcontrols 5.92.0-0ubuntu1
qml-module-org-kde-kquickcontrolsaddons 5.92.0-0ubuntu1
qml-module-org-kde-ksysguard 4:5.24.6-0ubuntu0.2
qml-module-org-kde-kwindowsystem 5.92.0-0ubuntu1
qml-module-org-kde-newstuff 5.92.0-0ubuntu1.1
qml-module-org-kde-prison 5.92.0-0ubuntu1
qml-module-org-kde-qqc2desktopstyle 5.92.0-0ubuntu1
qml-module-org-kde-quickcharts 5.92.0-0ubuntu1
qml-module-org-kde-solid 5.92.0-0ubuntu1
qml-module-org-kde-sonnet 5.92.0-0ubuntu1
qml-module-org-kde-userfeedback 1.2.0-2
qml-module-qt-labs-folderlistmodel 5.15.3+dfsg-1
qml-module-qt-labs-settings 5.15.3+dfsg-1
qml-module-qtgraphicaleffects 5.15.3-1
qml-module-qtmultimedia 5.15.3-1
qml-module-qtqml 5.15.3+dfsg-1
qml-module-qtqml-models2 5.15.3+dfsg-1
qml-module-qtquick-controls 5.15.3-1
qml-module-qtquick-controls2 5.15.3+dfsg-1
qml-module-qtquick-dialogs 5.15.3-1
qml-module-qtquick-layouts 5.15.3+dfsg-1
qml-module-qtquick-privatewidgets 5.15.3-1
qml-module-qtquick-shapes 5.15.3+dfsg-1
qml-module-qtquick-templates2 5.15.3+dfsg-1
qml-module-qtquick-window2 5.15.3+dfsg-1
qml-module-qtquick2 5.15.3+dfsg-1
qtchooser 66-2build1
readline-common 8.1.2-1
ripgrep 13.0.0-2ubuntu0.1
rpcsvc-proto 1.4.2-0ubuntu6
scrot 1.7-1
sed 4.8-1ubuntu2
sensible-utils 0.0.17
sgml-base 1.30
shared-mime-info 2.1-2
slirp4netns 1.0.1-2
socat 1.7.4.1-3ubuntu4
software-properties-common 0.99.22.9
sound-theme-freedesktop 0.8-2ubuntu1
ssl-cert 1.1.2
sudo 1.9.9-1ubuntu2.4
sysstat 12.5.2-2ubuntu0.2
systemd 249.11-0ubuntu3.17
systemd-sysv 249.11-0ubuntu3.17
systemsettings 4:5.24.6-0ubuntu0.1
tar 1.34+dfsg-1ubuntu0.1.22.04.2
tcl-expect 5.45.4-2build1
tcl8.6 8.6.12+dfsg-1build1
tigervnc-common 1.12.0+dfsg-4ubuntu0.22.04.1
tigervnc-scraping-server 1.12.0+dfsg-4ubuntu0.22.04.1
tigervnc-standalone-server 1.12.0+dfsg-4ubuntu0.22.04.1
tigervnc-tools 1.12.0+dfsg-4ubuntu0.22.04.1
tzdata 2024a-0ubuntu0.22.04.1
ubuntu-keyring 2021.03.26
ubuntu-mono 20.10-0ubuntu2
ucf 3.0043
udev 249.11-0ubuntu3.17
udisks2 2.9.4-1ubuntu2.3
unzip 6.0-26ubuntu3.2
upower 0.99.17-1
usb.ids 2022.04.02-1
util-linux 2.37.2-4ubuntu3.4
uuid-runtime 2.37.2-4ubuntu3.4
vim 2:8.2.3995-1ubuntu2.21
vim-common 2:8.2.3995-1ubuntu2.21
vim-runtime 2:8.2.3995-1ubuntu2.21
vlc-data 3.0.16-1build7
vlc-plugin-base 3.0.16-1build7
vlc-plugin-video-output 3.0.16-1build7
wget 1.21.2-2ubuntu1.1
wmctrl 1.07-7build1
x11-common 1:7.7+23ubuntu2
x11-utils 7.7+5build2
x11-xkb-utils 7.7+5build4
x11-xserver-utils 7.7+9build1
xauth 1:1.1-1build2
xdg-user-dirs 0.17-2ubuntu4
xdg-utils 1.1.3-4.1ubuntu3~22.04.1
xfonts-cyrillic 1:1.0.5
xfonts-encodings 1:1.0.5-0ubuntu2
xfonts-scalable 1:1.0.3-1.2ubuntu1
xfonts-utils 1:7.7+6build2
xkb-data 2.33-1
xml-core 0.18+nmu1
xserver-common 2:21.1.4-2ubuntu1.7~22.04.12
xvfb 2:21.1.4-2ubuntu1.7~22.04.12
xxd 2:8.2.3995-1ubuntu2.21
xz-utils 5.2.5-2ubuntu1
zip 3.0-12build2
zlib1g 1:1.2.11.dfsg-2ubuntu9.2
zlib1g-dev 1:1.2.11.dfsg-2ubuntu9.2
```

The pip and APT inventories are point-in-time captures of this session's image,
not maintained package contracts.
