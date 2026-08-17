#!/bin/sh
# Extract stage runner (invoked via docker exec by scripts/extract.ps1).
# Installs/refreshes the Natural sources from /poc/natural into the EXTRACT
# library, then runs both extract programs headlessly in one Natural session.
set -e
FUSER=/opt/softwareag/Natural/fuser
NATBIN=/opt/softwareag/Natural/bin

# DBID 1 -> adabas container (idempotent; dbmapping.txt is image-local)
DBMAP=/opt/softwareag/AdabasClient/config/dbmapping.txt
grep -q '^1 = adatcp://adabas:60001' $DBMAP 2>/dev/null || \
  echo '1 = adatcp://adabas:60001' >> $DBMAP

mkdir -p $FUSER/EXTRACT/SRC $FUSER/EXTRACT/GP
cp /poc/natural/EXTRVEH.NSP  $FUSER/EXTRACT/SRC/
cp /poc/natural/EXTRFIN.NSP  $FUSER/EXTRACT/SRC/
cp /poc/natural/VEHICLES.NSD $FUSER/EXTRACT/SRC/
cp /poc/natural/TRAFFINE.NSD $FUSER/EXTRACT/SRC/

cd $NATBIN
./ftouch lib=EXTRACT sm -b -d >/dev/null

. /opt/softwareag/AdabasClient/INSTALL/aclenv >/dev/null
export TERM=xterm
rm -f /poc/data/counts_veh.txt /poc/data/counts_fin.txt
set +e
# unique ETID per run: an aborted session leaves a stale ET user in the Adabas
# user queue (times out after TNAE); a fixed ETID would then hit resp 48/8
# READ+CATALOG regenerates the .NGD from the hand-authored DDM sources
# (CE has no SYSDDM; the compiler needs the cataloged DDM, source is not enough)
./natural udb=1 madio=0 "etid=X$$" \
  "stack=(LOGON EXTRACT;READ VEHICLES;CATALOG;READ TRAFFINE;CATALOG;RUN EXTRVEH;RUN EXTRFIN;FIN)" \
  </dev/null >/tmp/extract-screen.out 2>&1
rc=$?
if [ $rc -ne 0 ] || [ ! -f /poc/data/counts_veh.txt ] || [ ! -f /poc/data/counts_fin.txt ]; then
  echo "EXTRACT FAILED (natural rc=$rc). Screen output:"
  cat /tmp/extract-screen.out
  exit 1
fi
cat /poc/data/counts_veh.txt /poc/data/counts_fin.txt
exit 0
