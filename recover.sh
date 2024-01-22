#!/usr/bin/env bash

case  $(basename $0) in
    hotstandby*)
        HOTSTANDBY='on' ;;
    *)
        HOTSTANDBY='off' ;;
esac

while getopts ":d:l:s:t:" opt; do
    case $opt in
        d) SRCDATADIR=$OPTARG
            ;;
        l) SRCXLOGDIR=$OPTARG
            ;;
        s) TableSpace=$OPTARG
            ;;
        t) Time=$OPTARG
            ;;
        :) exit 1
    esac
done

PG_MAJOR=${PG_MAJOR%.*}  # Older image versions have a . in PG_MAJOR
if [ $PG_MAJOR -lt 10 ]; then
    WAL=xlog
else
    WAL=wal
fi

if [ ! -s "$PGDATA/PG_VERSION" ]; then

    [ -n "$SRCDATADIR" ] || exit 2
    SRCXLOGDIR=${SRCXLOGDIR:=$SRCDATADIR/pg_$WAL}
    Time=${Time:=null}
    
    PGDATADIR="$RecoveryArea/$(basename $SRCDATADIR)"
    PGUID=$(id -u postgres)
    REPORT="$RecoveryArea/recovery_report.txt"
    [ -e $REPORT ] && rm -f $REPORT

    # Clean up
    rm -fr $PGDATADIR
    rm -f  $RecoveryArea/[0-9A-F]*[0-9A-F]
    # Do not recover pg_xlog (this is needed when not symlinked outside)
    echo "$(date '+%m/%d %H:%M:%S'): Recovering Database files"
    cat <<EOF | socat -,ignoreeof $RecoverySocket
    { \
        "client": "$HOSTNAME", \
        "path": "$SRCDATADIR", \
        "uid": "$PGUID", \
        "time": "$Time", \
        "exclude": ["$SRCDATADIR/pg_$WAL/**"] \
    }
EOF
   # Temporary support for tablespaces
   # problem is that they have absolute pathnames
   # This runs unprivilged and hence will fail if the path is not writable
   # by postgres user

   if [ -n "$TableSpace" ]; then
        TableSpaceDir="$RecoveryArea/$(basename $TableSpace)"
        rm -fr $TableSpaceDir
        cat <<EOF | socat -,ignoreeof $RecoverySocket
        { \
            "client": "$HOSTNAME", \
            "path": "$TableSpace", \
            "uid": "$PGUID", \
            "time": "$Time" \
        }
EOF
        [ -d $(dirname $TableSpace) ] || mkdir $(dirname $TableSpace)
        ln -s $TableSpaceDir ${TableSpace%/}
    fi

    # if pg_xlog is a symlink, replace it by a directory:
    [ -L $PGDATADIR/pg_$WAL ] && rm $PGDATADIR/pg_$WAL
    [ -d $PGDATADIR/pg_$WAL ] || mkdir $PGDATADIR/pg_$WAL

    for i in $PGDATADIR/*; do ln -s $i $PGDATA/; done

    [ -e $PGDATA/pg_ident.conf ] || touch $PGDATA/pg_ident.conf
    cp /usr/share/postgresql/postgresql.conf.sample $PGDATA/postgresql.conf
    sed -ri "s/#?\\s*(hot_standby\\s*=)[^#]*/\1 $HOTSTANDBY /" $PGDATA/postgresql.conf
    sed -ri 's/#?\s*(max_connections\s*=)[^#]*/\1 2000 /' $PGDATA/postgresql.conf
    sed -ri 's/#?\s*(max_standby_archive_delay\s*=)[^#]*/\1 -1 /' $PGDATA/postgresql.conf

    # Create recovery.conf file
    if [ $PG_MAJOR -lt 12 ] ; then
        cat <<EOF >$PGDATA/recovery.conf
        standby_mode=$HOTSTANDBY
        restore_command='echo ''{"client": "$HOSTNAME", "path": "$SRCXLOGDIR/%f", "uid": "$PGUID", "time": "$Time"}'' | socat -,ignoreeof $RecoverySocket; mv $RecoveryArea/%f $PGDATA/%p'
EOF
    else
        cat <<-EOF >>$PGDATA/postgresql.conf
        restore_command='echo ''{"client": "$HOSTNAME", "path": "$SRCXLOGDIR/%f", "uid": "$PGUID", "Time": "$Time"}'' | socat -,ignoreeof $RecoverySocket; mv $RecoveryArea/%f $PGDATA/%p'
EOF
        [ $HOTSTANDBY == "on" ] &&  touch $PGDATA/standby.signal || touch $PGDATA/recovery.signal
    fi

    [ "$Time" != "null" ] && echo "recovery_target_time='$Time'" >>$PGDATA/recovery.conf

    echo "host all all samenet trust" > "$PGDATA/pg_hba.conf"
    echo "local all all trust"  >> "$PGDATA/pg_hba.conf"

    echo -e "\n$(date '+%m/%d %H:%M:%S'): Recovery report for $HOSTNAME:\n" >>$REPORT
    cat $PGDATADIR/backup_label 2>&1 | tee -a $REPORT
    echo "$(date '+%m/%d %H:%M:%S'): Starting postgres recovery (hot_standby = $HOTSTANDBY)"

    echo "$(date '+%m/%d %H:%M:%S'): Starting postgres recovery"
    # Start postgres without listening on a tcp socket
    coproc tailcop { exec docker-entrypoint.sh -h '' 2>&1; }

    exec 3<&${tailcop[0]}

    # initiate a timeout killer that will stop popstgres if recovery takes too long
    coproc timeout {
        sleep 10800 &&
        echo "$(date '+%m/%d %H:%M:%S'): Timeout during recovery" >&4 &&
        kill $tailcop_PID
    } 4>&2

    # Show progress while waiting untill recovery is complete
    while read -ru 3 line; do
        echo $line
        [ $(expr "$line" : '.*LOG:\s*database system is ready to accept .*connections') -gt 0 ] && break
        [ $(expr "$line" : '.*LOG:\s*redo') -gt 0 ] && echo $line >>$REPORT
        [ $(expr "$line" : '.*LOG:\s*last completed transaction was at log time') -gt 0 ] && echo $line >>$REPORT
        [ $(expr "$line" : '.*LOG:\s*consistent recovery state reached') -gt 0 ] && echo $line >>$REPORT
        if [ $(expr "$line" : '.*LOG:\s*restored log file .* from archive') -gt 0 ]; then 
          psql -qAtc "select 'Last replay timestamp: ' || pg_last_xact_replay_timestamp();"
        fi
    done
    # non-zero exit code occurs when the tailcop file descriptor was closed before
    # we broke out of the loop
    # for example, postgres stopped or was stopped by the timeout killer
    [ $? -ne 0 ] && echo "$(date '+%m/%d %H:%M:%S'): Database recovery failed" | tee -a $REPORT && exit 1

    # continue reading and showing stdout of the coprocess
    cat <&3 &

    # Recovery completed, kill the timeout killer
    [ -n "$timeout_PID" ] && kill $timeout_PID

    psql -qAtc "select 'Last replay timestamp: ' || pg_last_xact_replay_timestamp();" | tee -a $REPORT
    echo "$(date '+%m/%d %H:%M:%S'): Checking database integrity"
    [ $HOTSTANDBY == 'on' ] &&  psql -qc  "select pg_${WAL}_replay_pause();"
    [ $PG_MAJOR -lt 10 ] && pg_dumpall -v -f /dev/null || pg_dumpall -v --no-sync -f /dev/null
    RC=$? # save rc
    [ $HOTSTANDBY == 'on' ] &&  psql -qc  "select pg_${WAL}_replay_resume();"
    echo "$(date '+%m/%d %H:%M:%S'): Database integrity check endend with exit code $RC" | tee -a $REPORT
    [ $RC -ne 0 ] && echo "$(date '+%m/%d %H:%M:%S'): Database integrity check failed" && exit $RC

    echo "$(date '+%m/%d %H:%M:%S'): Shutting down postgres"
    # Stop the coprocess and wait for it to shutdown
    [ -n "$tailcop_PID" ] && kill $tailcop_PID && wait $tailcop_PID
    exit 0
fi

# Xhen called as hotstandby or with docker start with existing PGDATA,
# just start postgres and keep running
exec docker-entrypoint.sh postgres

