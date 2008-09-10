#!/bin/sh
app=cdda2wav

 if [ -x /usr/locl/bin/$app ] ; then
 echo "Found cdda2wav in /usr/local/bin " 1>&2
 app=/usr/local/bin/$app
 fi
 
# Next line is only a guess - needs to be edited but redirection of stdout (1) is essential
 echo "cdda2wav script running \n" 1>&2
 echo "command: $* \n"1>&2

 disk=`mount | grep cddafs | cut -d" " -f1`
 if [ -n "$disk" ] ; then 
  diskutil unmount $disk 1>&2
 else
  echo "No mounted cddafs found\n" 1>&2
 fi
 "$app" $*
