#!/bin/bash
### Build a filesystem image for Nintendo Switch

if [ "$1" == "--help" ]; then
    echo "Usage $0 [--all]"
    exit 1
fi

# Sources:
# https://wiki.debian.org/Debootstrap
# https://wiki.debian.org/EmDebian/CrossDebootstrap
# https://wiki.debian.org/Arm64Qemu

set -e

### settings
os=ubuntu
arch=arm64
suite=bionic
apt_mirror='http://ports.ubuntu.com'
repositories='main restricted universe multiverse'
chroot_dir="/var/chroot/${os}_${arch}_$suite"

### make sure that the required tools are installed
echo "Installing dependencies..."
apt-get install -qy debootstrap qemu-user-static

### Clear chroot_dir to make sure the rebuild is clean
# This is tp prevent a corrupted chroot dir to break repeated failed
# rebuilds that have been observed at the deboostrap minbase stage
echo "Removing existing chroot..."
rm -rf $chroot_dir

### install a minbase system with debootstrap
echo "Creating base image chroot, first stage..."
export DEBIAN_FRONTEND=noninteractive
foreign_arg=''
if [ $arch == 'arm64' ]; then
  foreign_arg='--foreign'
fi
debootstrap $foreign_arg --variant=minbase --arch=$arch $suite $chroot_dir $apt_mirror

echo "Creating base image chroot, second stage..."
cp qemu-aarch64-static $chroot_dir/usr/bin/
LC_ALL=C LANGUAGE=C LANG=C chroot $chroot_dir /debootstrap/debootstrap --second-stage
LC_ALL=C LANGUAGE=C LANG=C chroot $chroot_dir dpkg --configure -a

### set the hostname
echo "switch" > $chroot_dir/etc/hostname

### update the list of package sources
cat <<EOF > $chroot_dir/etc/apt/sources.list
deb $apt_mirror $suite $repositories
deb $apt_mirror $suite-updates $repositories
deb $apt_mirror $suite-backports $repositories
EOF

# prevent init scripts from running during install/update
echo '#!/bin/sh' > $chroot_dir/usr/sbin/policy-rc.d
echo 'exit 101' >> $chroot_dir/usr/sbin/policy-rc.d
chmod +x $chroot_dir/usr/sbin/policy-rc.d

# force dpkg not to call sync() after package extraction (speeding up installs)
echo 'force-unsafe-io' > $chroot_dir/etc/dpkg/dpkg.cfg.d/swibuntu-apt-speedup

# _keep_ us lean by effectively running "apt-get clean" after every install
echo 'DPkg::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };' > $chroot_dir/etc/apt/apt.conf.d/swibuntu-clean
echo 'APT::Update::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };' >> $chroot_dir/etc/apt/apt.conf.d/swibuntu-clean
echo 'Dir::Cache::pkgcache ""; Dir::Cache::srcpkgcache "";' >> $chroot_dir/etc/apt/apt.conf.d/swibuntu-clean

# remove apt-cache translations for fast "apt-get update"
echo 'Acquire::Languages "none";' > $chroot_dir/etc/apt/apt.conf.d/swibuntu-no-languages

# store Apt lists files gzipped on-disk for smaller size
echo 'Acquire::GzipIndexes "true"; Acquire::CompressionTypes::Order:: "gz";' > $chroot_dir/etc/apt/apt.conf.d/swibuntu-gzip-indexes

mount -o bind /proc $chroot_dir/proc

# HACK: Workaround for mandb syscall crash under qemu-user
chroot $chroot_dir MAN_DISABLE_SECCOMP=1 apt-get -qy install man-db

### install ubuntu-desktop
chroot $chroot_dir apt-get update
chroot $chroot_dir apt-get -qy install \
        ubuntu-minimal \
        ubuntu-desktop \
        openssh-server \
        xinput \
        net-tools \
        usbutils \
        pciutils \
        iw \
        accountsservice \
        xserver-xorg-core \
        xserver-xorg \
        xserver-xorg-input-evdev \
        xserver-xorg-video-nouveau \
        linux-firmware \
        libgl1-mesa-dri \
        bluez \
        driconf \
        quicksynergy \
        sudo

### install some newer packages from my PPA
chroot $chroot_dir add-apt-repository -y ppa:cmsj/nintendoswitch
chroot $chroot_dir apt-get -qy install libdrm-common libdrm-nouveau2 libdrm2

### install RetroArch PPA
chroot $chroot_dir add-apt-repository -y ppa:libretro/stable

### install Dolphin PPA
chroot $chroot_dir add-apt-repository -y ppa:dolphin-emu/ppa

### install RetrpArch and Dolphin
if [ "$1" == "--all" ]; then
    chroot $chroot_dir apt-get -qy install dolphin-emu-master
    chroot $chroot_dir apt-get -qy install retroarch libretro-*
fi

# Configuration: DNS
cat <<EOF > $chroot_dir/etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# Configuration: user (username: switch password: switch)
chroot $chroot_dir useradd -m -s /bin/bash -d /home/switch -p Q4OiRew2o/3Fk switch
if ! [ -d $chroot_dir/home/switch ]; then
  # Really not sure why useradd isn't making this
  mkdir -p $chroot_dir/home/switch
  chown 1000:1000 $chroot_dir/home/switch
fi
chroot $chroot_dir adduser switch sudo

# Configuration: autologin
cat <<EOF > $chroot_dir/etc/gdm3/custom.conf
[daemon]
AutomaticLoginEnable = true
AutomaticLogin = switch
[security]
[xdcmp]
[chooser]
[debug]
EOF

# Configuration: touchscreen config
# https://github.com/fail0verflow/shofel2/blob/master/configs/xinitrc-header.sh
# FIXME: Not sure if this is actually getting applied.
cat <<EOF > $chroot_dir/etc/X11/Xsession.d/01-nintendo-switch-fixups
xinput set-float-prop stmfts 'Coordinate Transformation Matrix' 0 -1 1 1 0 0 0 0 1
xrandr --output DSI-1 --rotate left
EOF

# FIXME: Not sure if this is actually getting applied. Xorg log suggests yes, but something isn't working
cat <<EOF > $chroot_dir/usr/share/X11/xorg.conf.d/99-nintendo-switch-touchscreen.conf
Section "InputClass"
        Identifier "evdev touchscreen catchall"
        MatchIsTouchscreen "on"
        MatchDevicePath "/dev/input/event*"
        Driver "evdev"
        Option "InvertX" "no"
        Option "InvertY" "yes"
        Option "SwapAxes" "yes"
        Option "Calibration" "0 1279 0 719"
EndSection
EOF

# FIXME: Above didn't work, so there's a hack below
# FIXME: This sucks, and since the touch input is still wrong, this doesn't help very much
#cat <<EOF > $chroot_dir/etc/xdg/autostart/switch-rotate.desktop
#[Desktop Entry]
#Name=Set Screen Rotation
#Exec=/bin/bash -c "sleep 10 && xrandr --output DSI-1 --rotate left"
#Type=Application
#EOF

# Configuration: Add missing firmware definition file for Broadcom driver
# https://bugzilla.kernel.org/show_bug.cgi?id=185661
cat <<EOF > $chroot_dir/lib/firmware/brcm/brcmfmac4356-pcie.txt
# Sample variables file for BCM94356Z NGFF 22x30mm iPA, iLNA board with PCIe for production package
NVRAMRev=$Rev: 492104 $
#4356 chip = 4354 A2 chip
sromrev=11
boardrev=0x1102
boardtype=0x073e
boardflags=0x02400201
#0x2000 enable 2G spur WAR
boardflags2=0x00802000
boardflags3=0x0000000a
#boardflags3 0x00000100 /* to read swctrlmap from nvram*/
#define BFL3_5G_SPUR_WAR   0x00080000   /* enable spur WAR in 5G band */
#define BFL3_AvVim   0x40000000   /* load AvVim from nvram */
macaddr=00:90:4c:1a:10:01
ccode=0x5854
regrev=205
antswitch=0
pdgain5g=4
pdgain2g=4
tworangetssi2g=0
tworangetssi5g=0
paprdis=0
femctrl=10
vendid=0x14e4
devid=0x43ec
manfid=0x2d0
#prodid=0x052e
nocrc=1
otpimagesize=502
xtalfreq=37400
rxgains2gelnagaina0=0
rxgains2gtrisoa0=7
rxgains2gtrelnabypa0=0
rxgains5gelnagaina0=0
rxgains5gtrisoa0=11
rxgains5gtrelnabypa0=0
rxgains5gmelnagaina0=0
rxgains5gmtrisoa0=13
rxgains5gmtrelnabypa0=0
rxgains5ghelnagaina0=0
rxgains5ghtrisoa0=12
rxgains5ghtrelnabypa0=0
rxgains2gelnagaina1=0
rxgains2gtrisoa1=7
rxgains2gtrelnabypa1=0
rxgains5gelnagaina1=0
rxgains5gtrisoa1=10
rxgains5gtrelnabypa1=0
rxgains5gmelnagaina1=0
rxgains5gmtrisoa1=11
rxgains5gmtrelnabypa1=0
rxgains5ghelnagaina1=0
rxgains5ghtrisoa1=11
rxgains5ghtrelnabypa1=0
rxchain=3
txchain=3
aa2g=3
aa5g=3
agbg0=2
agbg1=2
aga0=2
aga1=2
tssipos2g=1
extpagain2g=2
tssipos5g=1
extpagain5g=2
tempthresh=255
tempoffset=255
rawtempsense=0x1ff
pa2ga0=-147,6192,-705
pa2ga1=-161,6041,-701
pa5ga0=-194,6069,-739,-188,6137,-743,-185,5931,-725,-171,5898,-715
pa5ga1=-190,6248,-757,-190,6275,-759,-190,6225,-757,-184,6131,-746
subband5gver=0x4
pdoffsetcckma0=0x4
pdoffsetcckma1=0x4
pdoffset40ma0=0x0000
pdoffset80ma0=0x0000
pdoffset40ma1=0x0000
pdoffset80ma1=0x0000
maxp2ga0=76
maxp5ga0=74,74,74,74
maxp2ga1=76
maxp5ga1=74,74,74,74
cckbw202gpo=0x0000
cckbw20ul2gpo=0x0000
mcsbw202gpo=0x99644422
mcsbw402gpo=0x99644422
dot11agofdmhrbw202gpo=0x6666
ofdmlrbw202gpo=0x0022
mcsbw205glpo=0x88766663
mcsbw405glpo=0x88666663
mcsbw805glpo=0xbb666665
mcsbw205gmpo=0xd8666663
mcsbw405gmpo=0x88666663
mcsbw805gmpo=0xcc666665
mcsbw205ghpo=0xdc666663
mcsbw405ghpo=0xaa666663
mcsbw805ghpo=0xdd666665
mcslr5glpo=0x0000
mcslr5gmpo=0x0000
mcslr5ghpo=0x0000
sb20in40hrpo=0x0
sb20in80and160hr5glpo=0x0
sb40and80hr5glpo=0x0
sb20in80and160hr5gmpo=0x0
sb40and80hr5gmpo=0x0
sb20in80and160hr5ghpo=0x0
sb40and80hr5ghpo=0x0
sb20in40lrpo=0x0
sb20in80and160lr5glpo=0x0
sb40and80lr5glpo=0x0
sb20in80and160lr5gmpo=0x0
sb40and80lr5gmpo=0x0
sb20in80and160lr5ghpo=0x0
sb40and80lr5ghpo=0x0
dot11agduphrpo=0x0
dot11agduplrpo=0x0
phycal_tempdelta=255
temps_period=15
temps_hysteresis=15
rssicorrnorm_c0=4,4
rssicorrnorm_c1=4,4
rssicorrnorm5g_c0=1,2,3,1,2,3,6,6,8,6,6,8
rssicorrnorm5g_c1=1,2,3,2,2,2,7,7,8,7,7,8
EOF

# Configuration: Capture lots of information onto SD, since I still can't actually execute stuff directly on the Switch
cat <<EOF > $chroot_dir/etc/rc.local
#!/bin/sh
journalctl --flush
ifconfig -a >/tmp/ifconfig.txt
lsusb >/tmp/lsusb.txt
lspci >/tmp/lspci.txt
iw list >/tmp/iw.txt
journalctl -b >/tmp/syslog.txt
cat /sys/class/graphics/fb0/modes >/tmp/fb0_modes.txt
cat /sys/class/drm/card1/device/pstate >/tmp/gpu_pstate.txt
cat /sys/kernel/debug/dri/1/pstate >>/tmp/gpu_pstate.txt
sync
EOF
chmod +x $chroot_dir/etc/rc.local

# Cleanup: man-db does not work via qemu-user
chroot $chroot_dir rm /usr/bin/mandb
chroot $chroot_dir dpkg-divert --local --rename --remove /usr/bin/mandb

### cleanup and unmount /proc
chroot $chroot_dir apt-get autoclean
chroot $chroot_dir apt-get clean
chroot $chroot_dir apt-get autoremove
rm $chroot_dir/etc/resolv.conf
umount $chroot_dir/proc

### create a tar archive from the chroot directory
tar cfz $os_$arch_$suite.tgz -C $chroot_dir .

# ### cleanup
#rm $os_$arch_$suite.tgz
#rm -rf $chroot_dir
