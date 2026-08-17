#!/bin/sh
# Runs natural/DEMOUPD.NSP, which changes one vehicle record inside Adabas.
# Demonstration only - invoked by scripts/demo-extract.ps1 -Live.
# Same headless-Natural mechanics as run-extract.sh; see that file for why.
set -e
FUSER=/opt/softwareag/Natural/fuser
NATBIN=/opt/softwareag/Natural/bin

DBMAP=/opt/softwareag/AdabasClient/config/dbmapping.txt
grep -q '^1 = adatcp://adabas:60001' $DBMAP 2>/dev/null || \
  echo '1 = adatcp://adabas:60001' >> $DBMAP

mkdir -p $FUSER/EXTRACT/SRC $FUSER/EXTRACT/GP
cp /poc/natural/DEMOUPD.NSP  $FUSER/EXTRACT/SRC/
cp /poc/natural/VEHICLES.NSD $FUSER/EXTRACT/SRC/

cd $NATBIN
./ftouch lib=EXTRACT sm -b -d >/dev/null

. /opt/softwareag/AdabasClient/INSTALL/aclenv >/dev/null
export TERM=xterm
rm -f /tmp/demo_update.txt
set +e
./natural udb=1 madio=0 "etid=D$$" \
  "stack=(LOGON EXTRACT;READ VEHICLES;CATALOG;RUN DEMOUPD;FIN)" \
  </dev/null >/tmp/demo-screen.out 2>&1
rc=$?
if [ $rc -ne 0 ] || [ ! -f /tmp/demo_update.txt ]; then
  echo "DEMO UPDATE FAILED (natural rc=$rc). Screen output:"
  cat /tmp/demo-screen.out
  exit 1
fi
cat /tmp/demo_update.txt
exit 0
