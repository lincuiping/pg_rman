#!/bin/bash

#============================================================================
# This is a test script for backup command from standby server of pg_rman.
#============================================================================

BASE_PATH=`pwd`
TEST_BASE=${BASE_PATH}/results/backup_from_standby
PGDATA_PATH=${TEST_BASE}/data
SBYDATA_PATH=${TEST_BASE}/standby_data
BACKUP_PATH=${TEST_BASE}/backup
ARCLOG_PATH=${TEST_BASE}/arclog
SRVLOG_PATH=${TEST_BASE}/srvlog
TBLSPC_PATH=${TEST_BASE}/tblspc
TEST_PGPORT=54321
TEST_SBYPGPORT=54322
SCALE=2
DURATION=10
USE_DATA_CHECKSUM=""

# Clear environment variables used by pg_rman .
# List of environment variables is defined in catalog.c.
unset PGUSER
unset PGPORT
unset PGDATABASE
unset COMPRESS_DATA
unset BACKUP_MODE
unset WITH_SERVLOG
unset SMOOTH_CHECKPOINT
unset KEEP_DATA_GENERATIONS
unset KEEP_DATA_DAYS
unset KEEP_ARCLOG_FILES
unset KEEP_ARCLOG_DAYS
unset KEEP_SRVLOG_FILES
unset KEEP_SRVLOG_DAYS
unset RECOVERY_TARGET_TIME
unset RECOVERY_TARGET_XID
unset RECOVERY_TARGET_INCLUSIVE
unset RECOVERY_TARGET_TIMELINE
unset HARD_COPY


## command line option handling for this script 
while [ $# -gt 0 ]; do
	case $1 in
		"-d")
			DURATION=`expr $2 + 0`
			if [ $? -ne 0 ]; then
				echo "invalid duration"
				exit 1
			fi
			shift 2
			;;
		"-s")
			SCALE=`expr $2 + 0`
			if [ $? -ne 0 ]; then
				echo "invalid scale"
				exit 1
			fi
			shift 2
			;;
		"--with-checksum")
			USE_DATA_CHECKSUM="--data-checksum"
			shift
			;;
		*)
			shift
			;;
	esac
done

# Check presence of pgbench command and initialize environment
which pgbench > /dev/null 2>&1
ERR_NUM=$?
if [ $ERR_NUM != 0 ]
then
    echo "pgbench is not installed in this environment."
    echo "It is needed in PATH for those regression tests."
    exit 1
fi

# Check target PostgreSQL version
TOP_NUMBER_OF_PGVERSION=`pg_ctl -V | cut -d ' ' -f 3 | cut -d '.' -f 1`
if [ ${TOP_NUMBER_OF_PGVERSION} -lt 9 ]; then
    echo "The target PostgreSQL version does not support Streaming Replication."
    echo "Aborting regression tests..."
    exit
fi

function cleanup()
{
    # cleanup environment
    pg_ctl stop -m immediate -D ${PGDATA_PATH} > /dev/null 2>&1
    pg_ctl stop -m immediate -D ${SBYDATA_PATH} > /dev/null 2>&1
    rm -fr ${PGDATA_PATH}
    rm -fr ${SBYDATA_PATH}
    rm -fr ${BACKUP_PATH}
    rm -fr ${ARCLOG_PATH}
    rm -fr ${SRVLOG_PATH}
    rm -fr ${TBLSPC_PATH}
    mkdir -p ${ARCLOG_PATH}
    mkdir -p ${SRVLOG_PATH}
    mkdir -p ${TBLSPC_PATH}
}

function init_backup()
{
    # cleanup environment
    cleanup

    # create new database cluster
    initdb ${USE_DATA_CHECKSUM} --no-locale -D ${PGDATA_PATH} > ${TEST_BASE}/initdb.log 2>&1
    cp ${PGDATA_PATH}/postgresql.conf ${PGDATA_PATH}/postgresql.conf_org
    cat << EOF >> ${PGDATA_PATH}/postgresql.conf
port = ${TEST_PGPORT}
logging_collector = on
wal_level = hot_standby
max_wal_senders = 2
log_directory = '${SRVLOG_PATH}'
log_filename = 'postgresql-%F_%H%M%S-%p.log'
archive_mode = on
archive_command = 'cp %p ${ARCLOG_PATH}/%f'
checkpoint_segments = 10
EOF

	cat << EOF >> ${PGDATA_PATH}/pg_hba.conf
local   replication     postgres                                trust
host    replication     postgres        127.0.0.1/32            trust
host    replication     postgres        ::1/128                 trust
local   replication     $USER                                trust
host    replication     $USER        127.0.0.1/32            trust
host    replication     $USER        ::1/128                 trust
EOF


    # start PostgreSQL
    pg_ctl start -D ${PGDATA_PATH} -w -t 300 > /dev/null 2>&1
	mkdir -p ${TBLSPC_PATH}/pgbench	
	psql --no-psqlrc -p ${TEST_PGPORT} -d postgres > /dev/null 2>&1 << EOF
CREATE TABLESPACE pgbench LOCATION '${TBLSPC_PATH}/pgbench';
CREATE DATABASE pgbench TABLESPACE = pgbench;
EOF

    pgbench -i -s $SCALE -p ${TEST_PGPORT} -d pgbench > ${TEST_BASE}/pgbench.log 2>&1

}

function init_catalog()
{
    rm -fr ${BACKUP_PATH}
    pg_rman init -B ${BACKUP_PATH} -D ${SBYDATA_PATH} -A ${ARCLOG_PATH} --quiet
}

function setup_standby()
{
	psql --no-psqlrc -p ${TEST_PGPORT} -d postgres -c "SELECT pg_start_backup('sby-bkp-test', true)"  > /dev/null 2>&1

	rm -rf ${SBYDATA_PATH}
	cp -r ${PGDATA_PATH} ${SBYDATA_PATH}
	rm ${SBYDATA_PATH}/postmaster.*

	psql --no-psqlrc -p ${TEST_PGPORT} -d postgres > /dev/null 2>&1 << EOF
SELECT pg_stop_backup();
EOF

	cp ${SBYDATA_PATH}/postgresql.conf_org ${SBYDATA_PATH}/postgresql.conf
	cat >> ${SBYDATA_PATH}/postgresql.conf << EOF
port = ${TEST_SBYPGPORT}
hot_standby = on
logging_collector = on
wal_level = hot_standby
EOF

	cat >> ${SBYDATA_PATH}/recovery.conf << EOF
standby_mode = 'on'
restore_command = 'cp "${ARCLOG_PATH}/%f" "%p"'
primary_conninfo = 'port=${TEST_PGPORT} application_name=slave'
EOF

	cat >> ${PGDATA_PATH}/postgresql.conf << EOF
synchronous_standby_names = 'slave'
EOF
	pg_ctl -D ${PGDATA_PATH} reload > /dev/null 2>&1
	pg_ctl -D ${SBYDATA_PATH} start -w -t 600 > ${TEST_BASE}/sby_pg_ctl.log 2>&1
}

init_backup
setup_standby
init_catalog
echo '###### BACKUP COMMAND FROM STANDBY SERVER TEST-0001 ######'
echo '###### full backup mode ######'
pgbench -p ${TEST_PGPORT} -T ${DURATION} -d pgbench > /dev/null 2>&1
psql -p ${TEST_PGPORT} --no-psqlrc -d pgbench -c "SELECT * FROM pgbench_branches;" > ${TEST_BASE}/TEST-0001-before.out
pg_rman backup -B ${BACKUP_PATH} -b full -Z -p ${TEST_PGPORT} -d postgres -D ${SBYDATA_PATH} --standby-host=localhost --standby-port=${TEST_SBYPGPORT} --quiet;echo $?
pg_rman validate -B ${BACKUP_PATH} --quiet; echo $?
TARGET_XID=`psql -p ${TEST_PGPORT} --no-psqlrc -d pgbench -tAq -c "INSERT INTO pgbench_history VALUES (1) RETURNING(xmin);"`
pgbench -p ${TEST_PGPORT} -T ${DURATION} -d pgbench > /dev/null 2>&1
pg_ctl stop -m immediate -D ${PGDATA_PATH} > /dev/null 2>&1
cp ${PGDATA_PATH}/postgresql.conf ${TEST_BASE}/postgresql.conf
sleep 1
pg_rman restore -B ${BACKUP_PATH} -D ${PGDATA_PATH} --recovery-target-xid=${TARGET_XID} --quiet;echo $?
cp ${TEST_BASE}/postgresql.conf ${PGDATA_PATH}/postgresql.conf 
pg_ctl start -w -t 600 -D ${PGDATA_PATH} > /dev/null 2>&1
psql -p ${TEST_PGPORT} --no-psqlrc -d pgbench -c "SELECT * FROM pgbench_branches;" > ${TEST_BASE}/TEST-0001-after.out
diff ${TEST_BASE}/TEST-0001-before.out ${TEST_BASE}/TEST-0001-after.out
echo ''

init_backup
setup_standby
init_catalog
echo '###### BACKUP COMMAND FROM STANDBY SERVER TEST-0002 ######'
echo '###### full + incremental backup mode ######'
pgbench -p ${TEST_PGPORT} -d pgbench > /dev/null 2>&1
pg_rman backup -B ${BACKUP_PATH} -b full -Z -p ${TEST_PGPORT} -d postgres -D ${SBYDATA_PATH} --standby-host=localhost --standby-port=${TEST_SBYPGPORT} --quiet;echo $?
pg_rman validate -B ${BACKUP_PATH} --quiet; echo $?
pgbench -p ${TEST_PGPORT} -T ${DURATION} -d pgbench > /dev/null 2>&1
pg_rman backup -B ${BACKUP_PATH} -b incremental -Z -p ${TEST_PGPORT} -d postgres -D ${SBYDATA_PATH} --standby-host=localhost --standby-port=${TEST_SBYPGPORT} --quiet;echo $?
pg_rman validate -B ${BACKUP_PATH} --quiet; echo $?
psql -p ${TEST_PGPORT} --no-psqlrc -d pgbench -c "SELECT * FROM pgbench_branches;" > ${TEST_BASE}/TEST-0002-before.out
TARGET_XID=`psql -p ${TEST_PGPORT} --no-psqlrc -d pgbench -tAq -c "INSERT INTO pgbench_history VALUES (1) RETURNING(xmin);"`
pgbench -p ${TEST_PGPORT} -T ${DURATION} pgbench > /dev/null 2>&1
pg_ctl stop -m immediate -D ${PGDATA_PATH} > /dev/null 2>&1
cp ${PGDATA_PATH}/postgresql.conf ${TEST_BASE}/postgresql.conf
sleep 1
pg_rman restore -B ${BACKUP_PATH} -D ${PGDATA_PATH} --recovery-target-xid=${TARGET_XID} --quiet;echo $?
cp ${TEST_BASE}/postgresql.conf ${PGDATA_PATH}/postgresql.conf 
pg_ctl start -w -t 600 -D ${PGDATA_PATH} > /dev/null 2>&1
psql -p ${TEST_PGPORT} --no-psqlrc -d pgbench -c "SELECT * FROM pgbench_branches;" > ${TEST_BASE}/TEST-0002-after.out
diff ${TEST_BASE}/TEST-0002-before.out ${TEST_BASE}/TEST-0002-after.out


# clean up the temporal test data
pg_ctl stop -m immediate -D ${PGDATA_PATH} > /dev/null 2>&1
pg_ctl stop -m immediate -D ${SBYDATA_PATH} > /dev/null 2>&1
rm -fr ${PGDATA_PATH}
rm -rf ${SBYDATA_PATH}
rm -fr ${BACKUP_PATH}
rm -fr ${ARCLOG_PATH}
rm -fr ${SRVLOG_PATH}
rm -fr ${TBLSPC_PATH}