#!/bin/bash

######################## IMPORTANT #########################
###### PLEASE MAKE SURE FILES ARE OWNED BY www-data ########
############################################################

#-----------------------------------------------------------
# Script that migrates Joomla database and/or files.
#  - From Release to Dev
#  - From Release to Prod
#
# Few things to take into account during the db migration
#   - Articles hits MUST to be kept, to achieve this a tmp file is created prior to db import phase and loaded later on
#   - Recover from backup function MUST NOT import the database from releaseserver, otherwise article hits are going to be lost up, specially when updating production
#   - Files used in this script are kept in $_PWD
#   - Current DB backup are kept under LRU of 5 (sed -e '1,5d')
#   - Logs are kept
#
# Guilherme Viteri  - gviteri@ebi.ac.uk
#
#-----------------------------------------------------------

# Script must be in the static folder because we want this file to be in the GitHub repo. However the files created
# during execution have to be in different directory, I'd say, same level as static folder, that's why we 'go back' two directories

# Go to the directory where the script resides. It ensures we can execute from anywhere and cd .. will work
DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
cd $DIR;

cd ../..

_JOOMLA_STATIC=$(pwd)'/static'
_SYNCDIR=$(pwd)'/sync'
NOW=$(date +"%Y%m%d%H%M%S")
LOG="${_SYNCDIR}/logfile"
LOGFILE="${LOG}_${NOW}.txt"

exec > >(tee -i ${LOGFILE})
exec 2>&1

# Logs LRU
# Delete old backups. Only 5 are kept
LRU=$(ls -t $LOG* 2>/dev/null | sed -e '1,5d')
for LOG_TO_DEL in ${LRU}; do
    rm ${LOG_TO_DEL};
done;

SERVER=""

MYSQL_HOME="/usr/bin"
DEFAULT_DBNAME="website";

# Do not change this values
DEV_SERVER="reactomedev.oicr.on.ca"
RELEASE_SERVER="reactomerelease.oicr.on.ca"
PRD1_SERVER="reactomeprd1.oicr.on.ca"
DBPORT=3306;

# Written in the "source" server
DUMP_SQL_FILE="${_SYNCDIR}/dump_from_release.sql"
DEST_BACKUP_DB="${_SYNCDIR}/current_db_bkp.sql"

# Written in the "destination" server
# Better to keep in tmp, mysql user does not have permission where www-data rules and can't write remotely
TMP_ARTICLE_HITS="/tmp/articles_hits_${NOW}.csv"

BKP_TABLE="rlp_easyjoomlabackup"
TMP_TABLE="x4u_article_hits_tmp"
ARTICLES_TABLE="rlp_content"

usage () {
    if [ "$EXTERNAL" == "php" ]; then
        echo  "Missing mandatory parameters"
    else
        _SCRIPT=$(basename "$0")
        echo "Usage: ./$_SCRIPT"
        echo '           method=<ALL|DB|FILES>'
        echo '           env=<DEV|PROD>'
        echo '           srcosuser=<Source OS User> [Required when method is ALL or FILES]'
        echo '           srcospasswd=<Source OS Password> [Required when method is ALL or FILES]'
        echo '           osuser=<Destination OS User> [Required when method is ALL or FILES]'
        echo '           ospasswd=<Destination OS Password> [Required when method is ALL or FILES]'
        echo '           dbuser=<DB User> [Required when method is ALL or DB]'
        echo '           dbpasswd=<DB Password> [Required when method is ALL or DB]'
        echo '           dbname=[<DB Name: DEFAULT website>]'
        echo '           dbport=[<DB Port: Default 3306>]'
  fi

  exit
}

recover_from_backup () {
    echo "Recovering database using the backup [$DEST_BACKUP_DB]"

    # Exporting MySQL password so we don't print it in the command line.
    export MYSQL_PWD=${DBPASSWD}

    ${MYSQL_HOME}/mysql --host ${SERVER} -P ${DBPORT} -u ${DBUSER}  ${DBNAME} < ${DEST_BACKUP_DB}
    OUT=$?
    if [ "$OUT" -ne 0 ]; then
        echo "[ERROR] Could not IMPORT file [$DEST_BACKUP_DB] to the database [$DBNAME]"
        exit
    fi
}

validate_accounts () {
    echo $""
    echo "Validating accounts"

    if [ "$METHOD" == "ALL" ] || [ "$METHOD" == "DB" ]; then
        # Exporting MySQL password so we don't print it in the command line.
        export MYSQL_PWD=${DBPASSWD}

        ${MYSQL_HOME}/mysql --host ${SERVER} -P ${DBPORT} -u ${DBUSER} -e exit 2> /dev/null
        OUT=$?
        if [ "$OUT" -ne 0 ]; then
            echo "[ERROR] Can't connect to remote MySQL. Please check DB user and password"
            exit
        fi
    fi

    if [ "$METHOD" == "ALL" ] || [ "$METHOD" == "FILES" ]; then
        hash sshpass 2>/dev/null || { echo >&2 "sshpass is required. Please install it in this server. sudo apt-get install sshpass"; exit 1; }

        sshpass -p ${SRCOSPASSWD} ssh -o StrictHostKeyChecking=no -o LogLevel=quiet -o UserKnownHostsFile=/dev/null -t -q ${SRCOSUSER}@${RELEASE_SERVER} exit
        OUT=$?
        if [ "$OUT" -ne 0 ]; then
            echo "[ERROR] Can't connect to source server [${RELEASE_SERVER}]. Please use a valid OS user [${SRCOSUSER}] and password"
            exit
        fi

        sshpass -p ${OSPASSWD} ssh -o StrictHostKeyChecking=no -o LogLevel=quiet -o UserKnownHostsFile=/dev/null -t -q ${OSUSER}@${SERVER} exit
        OUT=$?
        if [ "$OUT" -ne 0 ]; then
            echo "[ERROR] Can't connect to remote server [${SERVER}]. Please use a valid OS user [${OSUSER}] and password"
            exit
        fi

        sshpass -p ${OSPASSWD} ssh -o StrictHostKeyChecking=no -o LogLevel=quiet -o UserKnownHostsFile=/dev/null -t ${OSUSER}@${SERVER} "echo ${OSPASSWD} | sudo -S id -u &> /dev/null"
        OUT=$?
        if [ "$OUT" -ne 0 ]; then
            echo "[ERROR] Sudo access is required in [${SERVER}]"
            exit
        fi
    fi
}

files_sync () {
    RSYNC_ARGS="-rogtO"
    if [ "$DRYRUN" == "Y" ]; then
        # -n to enable dry-run and -v verbose
        RSYNC_ARGS="${RSYNC_ARGS} --dry-run"
        DRMSG=" - DRY-RUN";
        echo "####### DRY-RUN ENABLED #######"
    fi

    # make sure files have set user and group before moving them (SOURCE)
    echo "Updating file's owner in the source server [${RELEASE_SERVER}] before synchronisation"
    sshpass -p ${SRCOSPASSWD} ssh -o StrictHostKeyChecking=no -o LogLevel=quiet -o UserKnownHostsFile=/dev/null -t ${SRCOSUSER}@${RELEASE_SERVER} "echo ${SRCOSPASSWD} | sudo -S chown -R www-data:gkb ${_JOOMLA_STATIC} &> /dev/null"
    OUT=$?
    if [ "$OUT" -ne 0 ]; then
        echo "[ERROR] Couldn't normalise the owner (www-data:gkb) of the static folder ${_JOOMLA_STATIC} in the Source server"
        exit
    fi

    # make sure files have set user and group in the Destination
    echo "Updating file's owner in the destination server [${SERVER}] before synchronisation"
    sshpass -p ${OSPASSWD} ssh -o StrictHostKeyChecking=no -o LogLevel=quiet -o UserKnownHostsFile=/dev/null -t ${OSUSER}@${SERVER} "echo ${OSPASSWD} | sudo -S chown -R www-data:gkb ${_JOOMLA_STATIC} &> /dev/null"
    OUT=$?
    if [ "$OUT" -ne 0 ]; then
        echo "[ERROR] Couldn't normalise the owner (www-data:gkb) of the static folder ${_JOOMLA_STATIC} in the Destination server"
        exit
    fi

    # save security copy of the files
    # TODO save security copy of the files

    # Check if sshpass is required. Program required to input the passwd into the rsync.
    # Not available for MacOS. To test locally, just run normal rsync and use the sshpasswordless.
    hash sshpass 2>/dev/null || { echo >&2 "sshpass is required. Please install it in this server. sudo apt-get install sshpass"; exit 1; }

    echo "File sync has started. Check rsync report for details"

    echo "======= RSYNC REPORT ${DRMSG} ======="
    sshpass -p ${OSPASSWD} rsync ${RSYNC_ARGS} -e 'ssh -o StrictHostKeyChecking=no -o LogLevel=quiet -o UserKnownHostsFile=/dev/null' -i --links --delete --ignore-errors --exclude-from=${DIR}/.rsync_excludes.txt ${_JOOMLA_STATIC}/ ${OSUSER}@${SERVER}:${_JOOMLA_STATIC} #2> /dev/null
    OUT=$?
    if [ "$OUT" -ne 0 ]; then
        echo "[ERROR] Rsync didn't executed properly. Check system output and address it manually. Re-run once the issue is sorted."
        exit
    fi
    echo "===================================="

    if [ "$DRYRUN" != "Y" ]; then
        # only update permission if we had a real copy, not needed when dry-run is enabled
        echo "Updating file's owner in the destination server [${SERVER}]"
        sshpass -p ${OSPASSWD} ssh -o StrictHostKeyChecking=no -o LogLevel=quiet -o UserKnownHostsFile=/dev/null -t ${OSUSER}@${SERVER} "echo ${OSPASSWD} | sudo -S chown -R www-data:gkb ${_JOOMLA_STATIC} &> /dev/null"

        # folders permissions are not copied even though the flag is present. To prevent problems folders will be flagged as chmod:775 after execution
        echo "Updating folders mode bits (chmod) in the destination server [${SERVER}]"
        sshpass -p ${OSPASSWD} ssh -o StrictHostKeyChecking=no -o LogLevel=quiet -o UserKnownHostsFile=/dev/null -t ${OSUSER}@${SERVER} "echo ${OSPASSWD} | sudo -S find ${_JOOMLA_STATIC} -type d -exec chmod 775 {} \; &> /dev/null"
    fi

    echo $"Files synchronisation has finished!"
}

db_sync () {
    if [ -f ${DUMP_SQL_FILE} ]; then
        rm ${DUMP_SQL_FILE}
    fi

    # Check current database backup file.
    if [ -f ${DEST_BACKUP_DB} ]; then
        BKP="$DEST_BACKUP_DB"
        if [ -f "$BKP" ]
        then
            COUNT=1
            while [ -e "$BKP.$COUNT" ]; do
               let "COUNT += 1";
            done
            BKP="$BKP.$COUNT"
        fi

        mv "$DEST_BACKUP_DB" "$BKP"

        # Delete old backups. Only 5 are kept
        LRU=$(ls -t $DEST_BACKUP_DB* | sed -e '1,5d')
        for BKP_TO_DEL in ${LRU}; do
            rm ${BKP_TO_DEL};
        done;
    fi

    # Exporting MySQL password so we don't print it in the command line.
    export MYSQL_PWD=${DBPASSWD}

    # DUMP FROM RELEASE - Our main hub
    echo "Dumping Joomla MySQL database from Reactome Release [$RELEASE_SERVER]"
    ${MYSQL_HOME}/mysqldump --host ${RELEASE_SERVER} -P ${DBPORT} -u ${DBUSER} --add-drop-database --databases ${DBNAME} > ${DUMP_SQL_FILE}
    OUT=$?
    if [ "$OUT" -ne 0 ] || [ ! -s ${DUMP_SQL_FILE} ]; then
        echo "[ERROR] Could not DUMP Joomla Database from Reactome Release [$RELEASE_SERVER]"
        exit
    fi

    echo "Backing up the Database [$DEFAULT_DBNAME] in the Destination [$SERVER]"
    ${MYSQL_HOME}/mysqldump --host ${SERVER} -P ${DBPORT} -u ${DBUSER} ${DEFAULT_DBNAME} > ${DEST_BACKUP_DB}
    OUT=$?
    if [ "$OUT" -ne 0 ] || [ ! -s ${DEST_BACKUP_DB} ]; then
        echo "[ERROR] Could not BACKUP the current database [$DEST_BACKUP_DB]"
        exit
    fi

    echo "Saving the Article Hits of the current database into CSV file"
    SAVE_ARTICLE_HITS="SELECT id, hits FROM $ARTICLES_TABLE INTO OUTFILE '$TMP_ARTICLE_HITS' FIELDS TERMINATED BY ',' ENCLOSED BY '\"' LINES TERMINATED BY '\n';"
    ${MYSQL_HOME}/mysql --host ${SERVER} -u ${DBUSER} ${DBNAME} -e "$SAVE_ARTICLE_HITS";
    OUT=$?
    if [ "$OUT" -ne 0 ]; then
        echo "[ERROR] Could not EXPORT Article Hits [$TMP_ARTICLE_HITS] from current database [$DBNAME] in server [$SERVER]"
        exit
    fi

    echo "Importing database [$DBNAME] into [$SERVER]"
    ${MYSQL_HOME}/mysql --host ${SERVER} -P ${DBPORT} -u ${DBUSER} ${DBNAME} < ${DUMP_SQL_FILE}
    OUT=$?
    if [ "$OUT" -ne 0 ]; then
        echo "[ERROR] Could not IMPORT file [$DUMP_SQL_FILE] to the database [$DBNAME] in server [$SERVER]"
        exit
    fi

    echo "Preparing the Article Hits in the new Database"
    echo "Dropping temporary table if it exists"
    # Can't use temporary table command because we are not running them under the same db connection
    DROP_TEMP_TABLE="DROP TABLE IF EXISTS $TMP_TABLE;"
    ${MYSQL_HOME}/mysql --host ${SERVER} -u ${DBUSER} ${DBNAME} -e "$DROP_TEMP_TABLE"
    OUT=$?
    if [ "$OUT" -ne 0 ]; then
        echo "[ERROR] Could not DROP temporary table [$TMP_TABLE] from current database [$DBNAME]"
        exit
    fi

    echo "Creating temporary table"
    CREATE_TEMP_TABLE="CREATE TABLE $TMP_TABLE (article_id int(10), article_hits int (10));"
    ${MYSQL_HOME}/mysql --host ${SERVER} -u ${DBUSER} ${DBNAME} -e "$CREATE_TEMP_TABLE"
    OUT=$?
    if [ "$OUT" -ne 0 ]; then
        echo "[ERROR] Could not CREATE temporary table [$TMP_TABLE] from current database [$DBNAME]"
        exit
    fi

    echo "Loading the articles into temporary table"
    IMPORT_ARTICLES="LOAD DATA INFILE '$TMP_ARTICLE_HITS' INTO TABLE $TMP_TABLE FIELDS OPTIONALLY ENCLOSED BY '\"' TERMINATED BY ',' (article_id, article_hits);"
    ${MYSQL_HOME}/mysql --host ${SERVER} -u ${DBUSER} ${DBNAME} -e "$IMPORT_ARTICLES"
    OUT=$?
    if [ "$OUT" -ne 0 ]; then
        echo "[ERROR] Could not LOAD [$TMP_ARTICLE_HITS] file int temporary table [$TMP_TABLE] from current database [$DBNAME]"
        exit
    fi

    echo "Updating Articles Hits based on the values in the temporary table"
    UPDATE_ARTICLES="UPDATE $ARTICLES_TABLE INNER JOIN $TMP_TABLE on $TMP_TABLE.article_id = $ARTICLES_TABLE.id SET $ARTICLES_TABLE.hits = $TMP_TABLE.article_hits;"
    ${MYSQL_HOME}/mysql --host ${SERVER} -u ${DBUSER} ${DBNAME} -e "$UPDATE_ARTICLES"
    OUT=$?
    if [ "$OUT" -ne 0 ]; then
        echo "[ERROR] Could not UPDATE article hits in [$ARTICLES_TABLE]"
        exit
    fi

    echo "Dropping temporary table"
    DROP_TEMP_TABLE="DROP TABLE $TMP_TABLE;"
    ${MYSQL_HOME}/mysql --host ${SERVER} -u ${DBUSER} ${DBNAME} -e "$DROP_TEMP_TABLE"
    OUT=$?
    if [ "$OUT" -ne 0 ]; then
        echo "[WARN] Could not DROP temporary table [$TMP_TABLE]"
    fi

    echo "Cleaning up Easy Joomla Backup table"
    DEL_EJB_TABLE="DELETE FROM $BKP_TABLE;"
    ${MYSQL_HOME}/mysql --host ${SERVER} -u ${DBUSER} ${DBNAME} -e "$DEL_EJB_TABLE"
    OUT=$?
    if [ "$OUT" -ne 0 ]; then
        echo "[WARN] Could not DELETE rows from table [$BKP_TABLE]"
    fi

    if [ "$ENV" == "PROD" ]; then
        echo "Removing Staff Login form from Production"
        UPDT_MENU_STAFF="UPDATE rlp_menu set published = 0 where id = 284;" # staff entry
        ${MYSQL_HOME}/mysql --host ${SERVER} -u ${DBUSER} ${DBNAME} -e "$UPDT_MENU_STAFF"
        OUT=$?
        if [ "$OUT" -ne 0 ]; then
            echo "[WARN] Could not REMOVE Reactome Staff Login form"
        fi
    fi

    echo "Database synchronisation has finished!";
}

# Check arguments
for ARGUMENT in "$@"
do
    KEY=$(echo $ARGUMENT | cut -f1 -d=)
    VALUE=$(echo $ARGUMENT | cut -f2 -d=)

    case "$KEY" in
            env)            ENV=${VALUE} ;;
            method)         METHOD=${VALUE} ;;
            srcosuser)      SRCOSUSER=${VALUE} ;;
            srcospasswd)    SRCOSPASSWD=${VALUE} ;;
            osuser)         OSUSER=${VALUE} ;;
            ospasswd)       OSPASSWD=${VALUE} ;;
            dbuser)         DBUSER=${VALUE} ;;
            dbpasswd)       DBPASSWD=${VALUE} ;;
            dbname)         DBNAME=${VALUE} ;;
            dbport)         DBPORT=${VALUE} ;;
            external)       EXTERNAL=${VALUE} ;;
            joomlauser)     JOOMLAUSER=${VALUE} ;;
            dryrun)         DRYRUN=${VALUE} ;;
            *)
    esac
done

if [ "$METHOD" = "" ]; then
    echo "Missing execution method [ALL|DB|FILES]"
    usage
fi

if  [ "$ENV" = "" ]; then
    echo "Missing environment method [DEV|PROD]"
    usage
fi

if [ "$METHOD" == "ALL" ]; then
    if  [ "$DBUSER" = "" ] || [ "$DBPASSWD" = "" ] ||
        [ "$SRCOSUSER" = "" ] || [ "$SRCOSPASSWD" = "" ] ||
        [ "$OSUSER" = "" ] || [ "$OSPASSWD" = "" ]; then
        echo "Missing OS Credentials and/or DB Credentials"
        usage
    fi
elif [ "$METHOD" == "DB" ]; then
    if [ "$DBUSER" = "" ] || [ "$DBPASSWD" = "" ]; then
        echo "Missing DB Credentials"
        usage
    fi
elif [ "$METHOD" == "FILES" ]; then # it is files, but just to list all the options
    if [ "$SRCOSUSER" = "" ] || [ "$SRCOSPASSWD" = "" ] ||
       [ "$OSUSER" = "" ] || [ "$OSPASSWD" = "" ]; then
        echo "Missing OS Credentials"
        usage
    fi
else
    echo "Invalid synchronisation method [ALL|DB|FILES]"
    usage
fi

if [ "$DBNAME" = "" ]
then
    DBNAME=${DEFAULT_DBNAME}
fi

if [ "${ENV}" == "PROD" ]
then
    SERVER=${PRD1_SERVER}
elif [ "${ENV}" == "DEV" ]
then
    SERVER=${DEV_SERVER}
else
    echo $"Invalid environment. Please provide DEV or PROD"
    exit;
fi

shopt -s nocasematch
if [ "$EXTERNAL" != "php" ]
then
    echo "Looks like script is being executed via command line"
    if [ "$DBNAME" != "website" ]
    then
        echo "Oh! And you are updating another database ..."
        read -p "CAREFUL: Updating a different database might be dangerous. Are you sure you want to update [$DBNAME] in [$SERVER]? " -n 1 -r
        if [[ ! "$REPLY" =~ ^[Yy]$ ]]
        then
            echo $"Bye!";
            exit;
        fi
    fi
else
    echo "Script is being executed via Synchronization Tool."

    # Running the script using the Web Interface, there's no way to change the database. It is always the default.
    DBNAME=${DEFAULT_DBNAME};

    echo "Synchronization started by [$JOOMLAUSER]"
fi

echo "Server: [$SERVER]"
echo "Database: [$DBNAME]"

# Define which sync method to call.
if [ "$METHOD" == "ALL" ]; then
    echo $""
    echo "Method: [DB and Files sync]"
    validate_accounts
    db_sync
    files_sync
elif [ "$METHOD" == "DB" ]; then
    echo $""
    echo "Method: [DB Sync Only]"
    validate_accounts
    db_sync
elif [ "$METHOD" == "FILES" ]; then
    echo $""
    echo "Method: [Files Sync Only]"
    validate_accounts
    files_sync
else
    echo "[ERROR] Execution method is invalid"
fi

# TODO GitHub commit/push