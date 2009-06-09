#!/bin/bash

VERSION71=`sed -n 's/.*<version>\(.*\)<\/version>.*/\1/p' CDplayer/install.xml`
VERSION73=`sed -n 's/.*<version>\(.*\)<\/version>.*/\1/p' CDplayer/install.xml.7_3`


mkdir /tmp/cdplayer_release
mkdir /tmp/cdplayer_release/CDplayer

# copy everything 
cp --preserve=timestamps -Rf CDplayer/* /tmp/cdplayer_release/CDplayer

# remove svn and leftover backups 
find /tmp/cdplayer_release/CDplayer -name \.svn | xargs rm -Rf
rm /tmp/cdplayer_release/CDplayer/*.pm~
rm /tmp/cdplayer_release/CDplayer/*.xml~
rm /tmp/cdplayer_release/CDplayer/*.conf~
rm /tmp/cdplayer_release/CDplayer/*.7_3~


# Build the Linux version

# add Linux specifics + remove windows convert confs
rm /tmp/cdplayer_release/CDplayer/custom-convert.conf.osx
rm /tmp/cdplayer_release/CDplayer/custom-convert.conf.win
mv /tmp/cdplayer_release/CDplayer/custom-convert.conf.linux /tmp/cdplayer_release/CDplayer/custom-convert.conf
# remove non-Linux specifics
rm -Rf /tmp/cdplayer_release/CDplayer/Bin


# remove 7.3 specifics
rm /tmp/cdplayer_release/CDplayer/install.xml.7_3
rm /tmp/cdplayer_release/CDplayer/CDPLAY.pm.7_3
rm /tmp/cdplayer_release/CDplayer/custom-convert.conf.osx.7_3
rm /tmp/cdplayer_release/CDplayer/custom-convert.conf.win.7_3
rm /tmp/cdplayer_release/CDplayer/custom-convert.conf.linux.7_3


pushd /tmp/cdplayer_release
chmod -R a+r *
tar cfz /tmp/cdplayer-linux-v"$VERSION71".tar.gz --numeric-owner --owner=0 --group=0 *
popd
echo "Release available at: /tmp/cdplayer-linux-v"$VERSION71".tar.gz"

# Copy 7.3 specifics
cp --preserve=timestamps CDplayer/install.xml.7_3               /tmp/cdplayer_release/CDplayer/install.xml
cp --preserve=timestamps CDplayer/CDPLAY.pm.7_3                 /tmp/cdplayer_release/CDplayer/CDPLAY.pm
cp --preserve=timestamps CDplayer/custom-convert.conf.linux.7_3 /tmp/cdplayer_release/CDplayer/custom-convert.conf

pushd /tmp/cdplayer_release
chmod -R a+r *
tar cfz /tmp/cdplayer-linux-v"$VERSION73".tar.gz --numeric-owner --owner=0 --group=0 *
zip -rq /tmp/cdplayer-linux-v"$VERSION73".zip *
popd
echo "Release available at: /tmp/cdplayer-linux-v"$VERSION73".tar.gz"
echo "Release available at: /tmp/cdplayer-linux-v"$VERSION73".zip"


# Build OSX version

# Restore 7.1 specifics
rm -f /tmp/cdplayer_release/CDPLAY.pm
rm -f /tmp/cdplayer_release/install.xml
cp --preserve=timestamps CDplayer/CDPLAY.pm   /tmp/cdplayer_release/CDplayer/CDPLAY.pm
cp --preserve=timestamps CDplayer/install.xml /tmp/cdplayer_release/CDplayer/install.xml


# remove linux specifics and copy OSX conf
rm -f /tmp/cdplayer_release/custom-convert.conf
cp CDplayer/custom-convert.conf.osx /tmp/cdplayer_release/CDplayer/custom-convert.conf

rm /tmp/cdplayer_release/CDplayer/Bin/*
mkdir /tmp/cdplayer_release/CDplayer/Bin
cp CDplayer/Bin/cdda2wavosx.sh /tmp/cdplayer_release/CDplayer/Bin

pushd /tmp/cdplayer_release
chmod -R a+r *
tar cfz /tmp/cdplayer-osx-v"$VERSION71".tar.gz --numeric-owner --owner=0 --group=0 *

popd
echo "Release available at: /tmp/cdplayer-osx-v"$VERSION71".tar.gz"

# Copy 7.3 specifics
cp --preserve=timestamps CDplayer/install.xml.7_3               /tmp/cdplayer_release/CDplayer/install.xml
cp --preserve=timestamps CDplayer/CDPLAY.pm.7_3                 /tmp/cdplayer_release/CDplayer/CDPLAY.pm
cp --preserve=timestamps CDplayer/custom-convert.conf.osx.7_3   /tmp/cdplayer_release/CDplayer/custom-convert.conf

pushd /tmp/cdplayer_release
chmod -R a+r *
tar cfz /tmp/cdplayer-osx-v"$VERSION73".tar.gz --numeric-owner --owner=0 --group=0 *
zip -rq /tmp/cdplayer-osx-v"$VERSION73".zip *

popd
echo "Release available at: /tmp/cdplayer-osx-v"$VERSION73".tar.gz"
echo "Release available at: /tmp/cdplayer-osx-v"$VERSION73".zip"

# Build Windows version

# Restore 7.1 specifics
rm -f /tmp/cdplayer_release/CDPLAY.pm
rm -f /tmp/cdplayer_release/install.xml
cp --preserve=timestamps CDplayer/CDPLAY.pm   /tmp/cdplayer_release/CDplayer/CDPLAY.pm
cp --preserve=timestamps CDplayer/install.xml /tmp/cdplayer_release/CDplayer/install.xml

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
zip -rq /tmp/cdplayer-windows-v"$VERSION71".zip *
popd
echo "Release available at: /tmp/cdplayer-windows-v"$VERSION71".zip"

# Copy 7.3 specifics
cp --preserve=timestamps CDplayer/install.xml.7_3               /tmp/cdplayer_release/CDplayer/install.xml
cp --preserve=timestamps CDplayer/CDPLAY.pm.7_3                 /tmp/cdplayer_release/CDplayer/CDPLAY.pm
cp --preserve=timestamps CDplayer/custom-convert.conf.win.7_3   /tmp/cdplayer_release/CDplayer/custom-convert.conf

pushd /tmp/cdplayer_release
chmod -R a+r *
zip -rq /tmp/cdplayer-windows-v"$VERSION73".zip *
popd
echo "Release available at: /tmp/cdplayer-windows-v"$VERSION73".zip"


# Remove temporary directory
rm -Rf /tmp/cdplayer_release
