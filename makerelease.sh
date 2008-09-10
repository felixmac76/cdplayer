#!/bin/bash

VERSION=`sed -n 's/.*<version>\(.*\)<\/version>.*/\1/p' CDplayer/install.xml`

mkdir /tmp/cdplayer_release
mkdir /tmp/cdplayer_release/CDplayer

# copy everything
cp --preserve=timestamps -Rf CDplayer/* /tmp/cdplayer_release/CDplayer

# Build the Linux version

# add Linux specifics + remove windows convert confs
rm /tmp/cdplayer_release/CDplayer/custom-convert.conf.osx
rm /tmp/cdplayer_release/CDplayer/custom-convert.conf.win
mv /tmp/cdplayer_release/CDplayer/custom-convert.conf.linux /tmp/cdplayer_release/CDplayer/custom-convert.conf
# remove non-Linux specifics
rm -Rf /tmp/cdplayer_release/CDplayer/Bin

pushd /tmp/cdplayer_release
chmod -R a+r *
tar cfz /tmp/cdplayer-linux-v"$VERSION".tar.gz --numeric-owner --owner=0 --group=0 *
popd
echo "Release available at: /tmp/cdplayer-linux-v"$VERSION".tar.gz"

# Build OSX version

# remove linux specifics and copy OSX conf
rm -f /tmp/cdplayer_release/custom-convert.conf
cp CDplayer/custom-convert.conf.osx /tmp/cdplayer_release/CDplayer/custom-convert.conf

rm /tmp/cdplayer_release/CDplayer/Bin/*
cp CDplayer/Bin/cdda2wavosx.sh /tmp/cdplayer_release/CDplayer/Bin

pushd /tmp/cdplayer_release
chmod -R a+r *
tar cfz /tmp/cdplayer-osx-v"$VERSION".tar.gz --numeric-owner --owner=0 --group=0 *
popd
echo "Release available at: /tmp/cdplayer-osx-v"$VERSION".tar.gz"

# Build Windows version

# remove linux & OSX specifics and copy Windows
rm -f /tmp/cdplayer_release/custom-convert.conf
cp CDplayer/custom-convert.conf.win /tmp/cdplayer_release/CDplayer/custom-convert.conf

rm -Rf /tmp/cdplayer_release/CDplayer/Bin
ls /tmp/cdplayer_release/CDplayer/Bin

unzip  -d /tmp/cdplayer_release/CDplayer/Bin CDplayer/Bin/cdda2wav.exe.ZIP
unzip  -d /tmp/cdplayer_release/CDplayer/Bin CDplayer/Bin/cygwin1.dll.ZIP
unzip  -d /tmp/cdplayer_release/CDplayer/Bin CDplayer/Bin/killorphans.exe.ZIP
ls /tmp/cdplayer_release/CDplayer/Bin

pushd /tmp/cdplayer_release
chmod -R a+r *
zip -rq /tmp/cdplayer-windows-v"$VERSION".zip *
popd
echo "Release available at: /tmp/cdplayer-windows-v"$VERSION"s.zip"

# Remove temporary directory
rm -Rf /tmp/cdplayer_release
