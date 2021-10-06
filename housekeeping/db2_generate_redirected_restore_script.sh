#!/bin/bash
#
# Script     : db2_generate_redirected_restore_script.sh
# Description: Generate a redirected restore script for a specific database
#
#<header>
#
# Remarks   : Parameters:
#   * Mandatory
#       -I | --source-instance   : Source instance name
#                                  (e.g. #INSTANCE_PLACEHOLDER#)
#       -D | --source-database   : Source database name
#                                  (e.g. #DATABASE_PLACEHOLDER#)
#
#   * Optional
#       -S | --source-hostname   : Source hostname; when omitted, the current
#                                    hostname (#HOSTNAME_PLACEHOLDER#) is used
#       -B | --source-directory  : Source directory containing a backup image
#                                    When omitted, the default directory is
#                                    taken (#BACKUPDIR_PLACEHOLDER#)
#       -s | --target-hostname   : Target hostname
#       -i | --target-instance   : Target instance name
#       -d | --target-database   : Target database name
#       -T | --timestamp         : Use a backup of a specific timestamp
#                                    (format: YYYYMMDDHHMMSS)
#       -N | --newlogpath        : Enable the generation of newlogpath
#       -A | --automatic-storage : Prepare for automatic storage
#       -q | --quiet             : Quiet - show no messages
#       -h | -H | --help         : Help
#
#</header>

#
# Constants
#
typeset    cCmdSwitchesShort="I:D:S:B:i:d:s:T:NAqhH"
typeset -l cCmdSwitchesLong="source-instance:,source-database:,source-hostname:,source-directory:,target-instance:,target-database:,target-hostname:,timestamp:,newlogpath,automatic-storage,quiet,help"
typeset    cHostName=$( hostname | cut -d '.' -f1 )
typeset    cScriptName="${0}"
typeset    cBaseNameScript=$( basename ${cScriptName} )
typeset    cScriptDir="${cScriptName%/*}"
typeset    cCurrentDir=$( pwd )
typeset    cLogsDirBase="/db2exports/db2scripts/logs/${cBaseNameScript%.*}"
typeset    cDb2LogDirectoryBase="/var/opt/db2/log"
typeset    cDb2CommonSecurityGroup=db2acc
typeset    cMasking="0002"

[[ "${cScriptDir}" == "." ]] && cScriptDir="${cCurrentDir}"

typeset    cBackupDirBase="/db2exports/backup"
typeset    cDatabaseDirBase="/var/opt/db2/data"

  #
  # Enable tablespaces for Automatic Storage
  #
typeset     cGetTablespacesToSet="
SELECT    '-- Tablespace ' || TRIM(tbsp.TBSP_NAME) || ' (' || CAST(tbsp.TBSP_ID AS VARCHAR(10)) || ')'
       || x'0A'
       || 'SET TABLESPACE CONTAINERS FOR '
       || TRIM(tbsp.TBSP_ID)
       || ' USING AUTOMATIC STORAGE ; '
       || x'0A'
  FROM TABLE(MON_GET_TABLESPACE('', -2)) TBSP
 WHERE tbsp.TBSP_USING_AUTO_STORAGE = 0
   AND tbsp.TBSP_TYPE = 'DMS'
   AND tbsp.TBSP_CONTENT_TYPE IN ('ANY','LARGE')
 ORDER BY tbsp.TBSP_ID
  WITH UR
   FOR READ ONLY
"
typeset     cGetTablespacesToAlter="
WITH getDefaultStorageGroup AS (
  SELECT  STORAGE_GROUP_NAME
    FROM TABLE(ADMIN_GET_STORAGE_PATHS('',-1)) AS T
   WHERE STORAGE_GROUP_ID = 0
 )

SELECT    'ALTER TABLESPACE '
       || TRIM(tbsp.TBSP_NAME)
       || ' USING STOGROUP '
       || TRIM(COALESCE(tbsp.STORAGE_GROUP_NAME, dSG.STORAGE_GROUP_NAME))
       || ' MANAGED BY AUTOMATIC STORAGE ; '
  FROM TABLE(MON_GET_TABLESPACE('', -2)) TBSP,
       getDefaultStorageGroup dSG
 WHERE tbsp.TBSP_USING_AUTO_STORAGE = 0
   AND tbsp.TBSP_TYPE = 'DMS'
   AND tbsp.TBSP_CONTENT_TYPE IN ('ANY','LARGE')
 ORDER BY tbsp.TBSP_ID
  WITH UR
   FOR READ ONLY
"

#
# Functions
#
  function setDistinctOnlineOfflineSettings {
    #
    # Distinctions of RESTORE options using an ON-/OFFLINE backup image
    #
    if [ "${lBackupType}" == "OFFLINE" ] ; then
      # An offline backup image needs no roll forward --> thus set 'WITHOUT ROLLING FORWARD'
      lRestoreScriptInMem=$(   echo "${lRestoreScriptInMem}" \
                             | sed 's/\-\- [ ]*\(WITHOUT ROLLING FORWARD\)/\1/g' \
                             | sed "s/^[\-]*[ ]*\(LOGTARGET\).*'/\-\- \1 $( echo ${lLogDirectory} | sed 's/\//\\\//g' ) \-\- Useless, because of the offline backup image/g" )
    else
      # An online backup has to be put in roll forward pending status, thus 'WITHOUT ROLLING FORWARD' as comment
      lRestoreScriptInMem=$(   echo "${lRestoreScriptInMem}" \
                             | sed 's/\-\- [ ]*\(WITHOUT ROLLING FORWARD\)/-- \1/g' )
      # Creation of the LOGTARGET directory + usage of the LOGTARGET directory
      lRestoreScriptInMem=$(   echo "${lRestoreScriptInMem}" \
                             | sed "s/^\(RESTORE DATABASE ${lSourceDatabase}$\)/-- \/\* Start clean up of LOGTARGET \*\/\n! mkdir -p $( echo ${lLogDirectory} | sed 's/\//\\\//g' ) > \/dev\/null 2>\&1 ;\n! rm -fR $( echo ${lLogDirectory} | sed 's/\//\\\//g' )\/* > \/dev\/null 2>\&1 ;\n-- \/\* End clean up of LOGTARGET \*\/\n\1/g" \
                             | sed "s/^\(INTO ${lTargetDatabase}\)$/\1\nLOGTARGET $( echo ${lLogDirectory} | sed 's/\//\\\//g' )/g" \
                             | grep -v '^-- LOGTARGET' )
      # Add ROLLFORWARD suggestions
      lRestoreScriptInMem="${lRestoreScriptInMem}

--
-- Suggestions for rollforward:
--
--  ROLLFORWARD DB ${lTargetDatabase} TO [END OF BACKUP|YYYY-MM-DD-HH.MM.SS USING LOCAL TIME|END OF LOGS]
--    [AND COMPLETE|STOP]
--    OVERFLOW LOG PATH ('${lLogDirectory}') NORETRIEVE ;
--
-- Not required when restoring to the same version of Db2, being v${gDb2Release} - build ${gDb2BuildInfo}:
--
--  UPGRADE DB ${lTargetDatabase} ;
--

"
    fi

    set +x
    return 0
  }

  function setDbPath {
    #
    # Set 'DBPATH ON' to good values
    # Possible combo's:
    #   * TO ... DBPATH ON ...
    #   * ON ... DBPATH ON ... --> generated by the 'restore generate script' command
    #   * DBPATH ON ...
    #
    lRestoreScriptInMem=$(   echo "${lRestoreScriptInMem}" \
                           | sed "s/^[\-]*[ ]*\(DBPATH ON\).*/\1 '$( echo ${cDatabaseDirBase} | sed 's/\//\\\//g' )'/g" \
                           | grep -v '^\-\- TO ' )

    set +x
    return 0
  }

  function setNewLogPath {
    #
    # Capture the NEWLOGPATH and clean up what ever residu is found there
    #
    typeset lNewLogPath=$(   echo "${lRestoreScriptInMem}" \
                           | grep '^[\-]*[ ]*NEWLOGPATH ' \
                           | sed "s/^[\-]*[ ]*\(NEWLOGPATH\) /\1 /g; s/${lSourceInstance}/${lTargetInstance}/g; s/${lSourceDatabase}/${lTargetDatabase}/g" \
                           | cut -d "'" -f 2 )

    if [ "${lNewLogPath}" != "" ] ; then
      if [ "$( echo "${lNewLogPath}" | grep "${cDb2LogDirectoryBase}" )" == "" ] ; then
        lNewLogPath=$(   db2 get db cfg for ${lSourceDatabase} \
                       | grep 'Changed path to log files' \
                       | awk -F '=' '{print $2}' \
                       | sed 's/^[ ]*//g; s/[ ]*$//g' )
      fi
      if [ "$( echo "${lNewLogPath}" | grep "${cDb2LogDirectoryBase}" )" == "" ] ; then
        lNewLogPath=$(   db2 get db cfg for ${lSourceDatabase} \
                       | grep 'Path to log files' \
                       | awk -F '=' '{print $2}' \
                       | sed 's/^[ ]*//g; s/[ ]*$//g' )
      fi
      if [ "${lGenerateNewLogPath}" == "YES" ] ; then
        if [ "$( echo "${lNewLogPath}" | grep "${cDb2LogDirectoryBase}" )" == "" ] ; then
          gErrorNo=15
          gMessage="
Error - The logging path is not following the conventions!
  * Log path found: ${lNewLogPath}
  * Expected base : ${cDb2LogDirectoryBase}

Return code: ${gErrorNo}

Exiting"
          echo "${gMessage}"
          set +x
          exit ${gErrorNo}
        fi
      fi

      lNewLogPath=$(   echo "${lNewLogPath}/" \
                     | sed 's/NODE[0-9][0-9]*\///g; s/SQL[0-9][0-9]*\///g; s/LOGSTREAM[0-9][0-9]*\///g; s/\/\//\//g' \
                     | sed "s/^[\-]*[ ]*\(NEWLOGPATH\) /\1 /g; s/${lSourceInstance}/${lTargetInstance}/gi; s/${lSourceDatabase}/${lTargetDatabase}/gi"
                   )
      lNewLogPath="${lNewLogPath%/*}"

      if [ "${lGenerateNewLogPath}" == "YES" ] ; then
        lRestoreScriptInMem=$(   echo "${lRestoreScriptInMem}" \
                               | sed "s/^\(RESTORE DATABASE ${lSourceDatabase}$\)/-- \/\* Start clean up of NEWLOGPATH \*\/\n! mkdir -p $( echo ${lNewLogPath} | sed 's/\//\\\//g' ) > \/dev\/null 2>\&1 ;\n! rm -fR $( echo ${lNewLogPath} | sed 's/\//\\\//g' )\/* > \/dev\/null 2>\&1 ;\n-- \/\* End clean up of NEWLOGPATH \*\/\n\\1/g" \
                               | sed "s/^[\-]*[ ]*\(NEWLOGPATH\) .*/\1 $( echo ${lNewLogPath} | sed 's/\//\\\//g' )/g" )
      else
        lRestoreScriptInMem=$(   echo "${lRestoreScriptInMem}" \
                               | sed "s/^\([\-]*[ ]*NEWLOGPATH\) .*/\1 $( echo ${lNewLogPath} | sed 's/\//\\\//g' )/g" )
      fi
    fi

    set +x
    return 0
  }

  function handleAutomaticStorage {
    #
    # Does the restore script need to handle Automatic storage?
    #
    typeset -i lLineNumberStart=0
    typeset -i lLineNumberStop=0
    typeset -i lReturnCode=0
    typeset    lLocalTemp=""
    typeset    lOnPath="ON '${cDatabaseDirBase}'"
    typeset    lLineNumberSet=""

    hasDb2DbAutomaticStorage
    lReturnCode=$?
    [[ ${lReturnCode} -eq 0 ]] && lAutomaticStorageSupported="YES" || lAutomaticStorageSupported="NO"

    if [ "${lAutomaticStorage}" == "YES" ] ; then
      if [ "${lSourceInstance}" != "${USER}" -o  \
           $( echo "${gDb2DatabaseList}" | grep "^${lSourceDatabase}$" | wc -l ) -eq 0 ] ; then
        if [ "${lVerbose}" == "YES" ] ; then
          gMessage="Cannot do the additional work for Automatic Storage when not on the source server/instance/database (${lSourceHostName}/${lSourceInstance}/${lSourceDatabase})"
          showInfo
        fi
      elif [ "${lAutomaticStorageSupported}" == "NO" -a "${lVerbose}" == "YES" ] ; then
        gMessage="The database ${lSourceDatabase} is not enabled for Automatic Storage"
        showInfo
      fi
    fi

    #
    # Fill in "ON <path>"
    #
    lLineNumberStart=$(   echo "${lRestoreScriptInMem}" \
                   | awk '/TAKEN/,/DBPATH/{print NR":"$0}' \
                   | grep '^[0-9][0-9]*:[\-]* [ ]*ON ' \
                   | cut -d':' -f1 )
    if [ ${lLineNumberStart} -ne 0 ] ; then
      lLocalTemp=$(   echo "${lRestoreScriptInMem}" \
                    | sed -n $(( lLineNumberStart + 1 )),\$p
                  )
      if [ "${lAutomaticStorageSupported}" == "NO" ] ; then
        lOnPath="-- ${lOnPath}  -- Not usable, because database does not support Automatic Storage (SQL2321N)"
      fi
      lRestoreScriptInMem=$(   echo "${lRestoreScriptInMem}" \
                             | sed -n 1,$(( lLineNumberStart -1 ))p \
                             ; echo "${lOnPath}" \
                             ; echo "${lLocalTemp}"
                           )
    fi

    if [ "${lAutomaticStorageSupported}" == "YES" ] ; then
      #
      # Enable already defined storage groups
      #
      lLineNumberSet=$(   echo "${lRestoreScriptInMem}" \
                        | awk '/SET STOGROUP/,/;/{print NR":"$0}' \
                        | cut -d ':' -f1 )
      lLineNumberStart=$( echo "${lLineNumberSet}" | head -1 ) 
      if [ ${lLineNumberStart} -ne 0 ] ; then
        lLineNumberStop=$( echo "${lLineNumberSet}" | tail -1 )
        lLocalTemp=$(   echo "${lRestoreScriptInMem}" \
                      | sed -n ${lLineNumberStart},${lLineNumberStop}p \
                      | sed 's/^[\-]*[ ]*//g'
                    )
        lRestoreScriptInMem=$(   echo "${lRestoreScriptInMem}" | sed -n 1,$(( lLineNumberStart -1 ))p \
                               ; echo "${lLocalTemp}" \
                               ; echo "${lRestoreScriptInMem}" | sed -n $(( lLineNumberStop + 1 )),\$p
                             )
      fi

      if [ "${lAutomaticStorage}" == "YES" ] ; then
        #
        # Enable tablespaces for Automatic Storage
        #
        lSetTablespace=$( db2 connect to ${lSourceDatabase} > /dev/null 2>&1 ; \
                          [[ $? -eq 0 ]] && db2 -x "${cGetTablespacesToSet}" | sed 's/[ ]*$//g' ; \
                          db2 connect reset > /dev/null 2>&1 ; )
        lAlterTablespace=$( db2 connect to ${lSourceDatabase} > /dev/null 2>&1 ; \
                          [[ $? -eq 0 ]] && db2 -x "${cGetTablespacesToAlter}" | sed 's/[ ]*$//g' ; \
                          db2 connect reset > /dev/null 2>&1 ; )
        lSetTablespace=$( echo "${lSetTablespace}" | grep -v '^$' )
        if [ "${lSetTablespace}" != "" ] ; then
          lOriTablespacesToSet=$(   echo "${lRestoreScriptInMem}" \
                                  | awk '/SET TABLESPACE CONTAINERS FOR/,/;/{print NR":"$0}' \
                                  | sed 's/;/;#/g' \
                                  | tr '#' '\n' )
          lLineNumberStart=$( echo "${lOriTablespacesToSet}" | head -1 | cut -d ':' -f1 )
          lLineNumberStop=$( echo "${lOriTablespacesToSet}" | tail -1 | cut -d ':' -f1 )

          #
          # Preserve those not able to be converted to Automatic Storage
          #
          lTablespacesToCheck=$( echo "${lOriTablespacesToSet}" | grep 'SET TABLESPACE CONTAINERS FOR' | cut -d':' -f2 )
          for lTablespaceID in $( echo "${lTablespacesToCheck}" | sed 's/SET TABLESPACE CONTAINERS FOR[ ]*//g' )
          do
            if [ $( echo "${lSetTablespace}" | grep "SET TABLESPACE CONTAINERS FOR ${lTablespaceID} " | wc -l ) -gt 0 ] ; then
              # Identify in the original set and remove it!
              lLocalTemp=$(   echo "${lOriTablespacesToSet}" \
                            | awk "/SET TABLESPACE CONTAINERS FOR ${lTablespaceID}[ ]*$/,/^$/" )
              lTamperedOriginal=$(   diff -wb <(echo "${lOriTablespacesToSet}") <(echo "${lLocalTemp}") \
                                      | grep '^<' \
                                      | grep -v '^<[ ]*$' \
                                      | sed 's/^< //g; s/;/;#/g' \
                                      | grep -v '^$' \
                                      | tr '#' '\n' )
              lOriTablespacesToSet="${lTamperedOriginal}"
            fi
          done
          lTamperedOriginal=$( echo "${lOriTablespacesToSet}" | cut -d ':' -f2 )
          lRestoreScriptInMem=$(   echo "${lRestoreScriptInMem}" | sed -n 1,$(( lLineNumberStart -1 ))p \
                                 ; echo "${lTamperedOriginal}" \
                                 ; echo "-- /* Start - Tablespaces about to be set to Automatic Storage */" \
                                 ; echo "CONNECT TO ${lTargetDatabase} ;" \
                                 ; echo "${lSetTablespace}" \
                                 ; echo "-- /* End - Tablespaces about to be set to Automatic Storage */" \
                                 ; echo "CONNECT RESET ;" \
                                 ; echo "${lRestoreScriptInMem}" | sed -n $(( lLineNumberStop + 1 )),\$p
                               )

        fi  # "${lSetTablespace}" != ""
        if [ "${lAlterTablespace}" != "" ] ; then
          lRestoreScriptInMem=$(   echo "${lRestoreScriptInMem}" \
                                 ; echo "" \
                                 ; echo "${lAlterTablespace}" )
        fi  # "${lAlterTablespace}" != ""
      fi  # "${lAutomaticStorage}" == "YES"
    fi  # "${lAutomaticStorageSupported}" == "YES"

    set +x
    return 0
  }

  function scriptUsage {

    typeset    lHeader=""
    typeset    lHeaderPos=""
    typeset -u lExitScript="${1}"

    [[ "${lExitScript}" != "NO" ]] && lExitScript="YES"

    # Show the options as described above
    printf "\nUsage of the script ${cScriptName}: \n"

    [[ "${gMessage}" != "" ]] && showError
    [[ ${gErrorNo} -eq 0 ]] && gErrorNo=1

    lHeaderPos=$(   grep -n '<[/]*header>' ${cScriptName} \
                 | awk -F: '{print $1}' \
                 | sed 's/$/,/g' )
    lHeaderPos=$(   echo ${lHeaderPos} \
                  | sed 's/,$//g; s/ //g' )
    lHeader=$(   sed -n ${lHeaderPos}p ${cScriptName} \
               | egrep -v '<[/]*header>|ksh|Description' \
               | uniq \
               | sed 's/^#//g; s/^[ ]*Remarks[ ]*://g' )

    if [ "${gDb2InstancesList}" != "" ] ; then
      lFormattedInstanceList=$( echo ${gDb2InstancesList} | sed 's/^[ ]*//g; s/[ ]*$//g; s/ [ ]*/, /g' )
      lHeader=$( echo "${lHeader}" | sed "s/#INSTANCE_PLACEHOLDER#/${lFormattedInstanceList}/g" )
    else
      lHeader=$( echo "${lHeader}" | grep -v '#INSTANCE_PLACEHOLDER#' )
    fi

    if [ "${gDb2DatabasesList}" != "" ] ; then
      lFormattedDatabaseList=$( echo ${gDb2DatabasesList} | sed 's/^[ ]*//g; s/[ ]*$//g; s/ [ ]*/, /g' )
      lHeader=$( echo "${lHeader}" | sed "s/#DATABASE_PLACEHOLDER#/${lFormattedDatabaseList}/g" )
    else
      lHeader=$( echo "${lHeader}" | grep -v '#DATABASE_PLACEHOLDER#' )
    fi
    [[ "${cHostName}" == "" ]] && cHostName=$( hostname )
    lHeader=$( echo "${lHeader}" \
             | sed "s:#HOSTNAME_PLACEHOLDER#:${cHostName}:g" \
             | sed "s:#BACKUPDIR_PLACEHOLDER#:${cBackupDirBase}:g" )
    if [ "${lExitScript}" == "YES" ] ; then
      gMessage=$( printf "${lHeader}\n\nExiting.\n" )
    else
      gMessage=$( printf "${lHeader}\n" )
    fi
    showMessage

    set +x
    [[ "${lExitScript}" == "YES" ]] && exit ${gErrorNo}
    return ${gErrorNo}
  }

#
# Primary initialization of commonly used variables
#
typeset    lTimestampToday=$( date "+%Y-%m-%d-%H.%M.%S" )
typeset    lSourceHostName="${cHostName}"
typeset    lTargetHostName=""
typeset -l lSourceInstance=""
typeset -l lTargetInstance=""
typeset -u lSourceDatabase=""
typeset -u lTargetDatabase=""
typeset    lBackupDirBase="${cBackupDirBase}_${lSourceHostName}"
typeset -u lGenerateNewLogPath="NO"
typeset -u lAutomaticStorage="NO"
typeset -f lSpecificBackupTimestamp
typeset -u lVerbose="YES"
typeset    gMessage=""
typeset -i gErrorNo=0

gDb2VersionList=""
gDb2InstancesList=""
lSpecificBackupTimestamp=0

#
# Loading libraries
#
[[ ! -f ${cScriptDir}/common_functions.include ]] && gErrorNo=2 && gMessage="Cannot load ${cScriptDir}/common_functions.include" && scriptUsage
. ${cScriptDir}/common_functions.include

[[ ! -f ${cScriptDir}/db2_common_functions.include ]] && gErrorNo=2 && gMessage="Cannot load ${cScriptDir}/db2_common_functions.include" && scriptUsage
. ${cScriptDir}/db2_common_functions.include

getCurrentDb2Version

#
# Is this a Db2 instance?
#
isDb2Instance
[[ $? -ne 0 ]] && gErrorNo=3 && gMessage="The current user (${USER}) is not a Db2 instance" && scriptUsage

#
# Check for the input parameters
#
    # Read and perform a lowercase on all '--long' switch options, store in $@
  eval set -- $(   echo "$@" \
                 | tr ' ' '\n' \
                 | sed -e 's/^\(\-\-.*\)/\L\1/' \
                 | tr '\n' ' ' \
                 | sed 's/^[ ]*//g; s/[ ]*$/\n/g; s/|/\\|/g' )
    # Check the command line options for their correctness,
    #   throw out what is not OK and store the rest in $@
  eval set -- $( getopt --options "${cCmdSwitchesShort}" \
                        --long "${cCmdSwitchesLong}" \
                        --name "${0}" \
                        --quiet \
                        -- "$@" )
    # Initialize the option-processing variables
  typeset _lCmdOption=""
  typeset _lCmdValue=""

    # Process the options
  while [ "$#" ] ; do

    _lCmdOption="${1}"
    _lCmdValue="${2}"
    [[ "${_lCmdOption}" == "" && "${_lCmdValue}" == "" ]] && _lCmdOption="--"

    case ${_lCmdOption} in
      -S | --source-hostname )
        lSourceHostName="${_lCmdValue}"
        shift 2
        ;;
      -I | --source-instance )
        lSourceInstance="${_lCmdValue}"
        shift 2
        ;;
      -D | --source-database )
        lSourceDatabase="${_lCmdValue}"
        gDatabase="${_lCmdValue}"
        shift 2
        ;;
      -B | --source-directory )
        lBackupDirBase="${_lCmdValue}"
        gDatabase="${_lCmdValue}"
        shift 2
        ;;
      -s | --target-hostname )
        lTargetHostName="${_lCmdValue}"
        shift 2
        ;;
      -i | --target-instance )
        lTargetInstance="${_lCmdValue}"
        shift 2
        ;;
      -d | --target-database )
        lTargetDatabase="${_lCmdValue}"
        shift 2
        ;;
      -T | --timestamp )
        lSpecificBackupTimestamp=${_lCmdValue}
        shift 2
        ;;
      -N | --newlogpath )
        lGenerateNewLogPath="YES"
        shift 1
        ;;
      -A | --automatic-storage )
        lAutomaticStorage="YES"
        shift 1
        ;;
      -q | --quiet )
        lVerbose="NO"
        shift 1
        ;;
      -- )
          # Make $@ completely empty and break the while loop
        [[ $# -gt 0 ]] && shift $#
        break
        ;;
      *)
        gMessage=""
        scriptUsage
        ;;
    esac
  done
  unset _lCmdValue
  unset _lCmdOption

#
# Check input which is mandatory
#
[[ "${lSourceInstance}" == "" ]] && gErrorNo=7 && gMessage="Please provide an instance to do the work for" && scriptUsage
[[ "${lSourceDatabase}" == "" ]] && gErrorNo=8 && gMessage="Please provide a database to do the work for" && scriptUsage

#
# Force variable(s) to values within boundaries and set a default when needed
#
[[ "${lVerbose}" != "NO" ]] && lVerbose="YES"
[[ "${lGenerateNewLogPath}" != "YES" ]] && lGenerateNewLogPath="NO"
[[ "${lAutomaticStorage}"   != "YES" ]] && lAutomaticStorage="NO"

#
# Fetch data & validate the input data
#
fetchAllDb2Versions
[[ "${gDb2VersionList}" == "" ]] && gErrorNo=4 && gMessage="No installation of Db2 found in this server" && scriptUsage
fetchAllDb2Instances
[[ "${gDb2InstancesList}" == "" ]] && gErrorNo=5 && gMessage="No Db2 instances found in this server" && scriptUsage
fetchAllDb2Databases
[[ "${gDb2DatabaseList}" == "" ]] && gErrorNo=6 && gMessage="No Db2 databases found within the instance ${lSourceInstance}" && scriptUsage

#
# Main - Get to work
#

# ======================================
# Generate the redirected restore script
# ======================================
[[ "${lTargetHostName}" == "" ]] && lTargetHostName=${lSourceHostName}
[[ "${lTargetInstance}" == "" ]] && lTargetInstance=${lSourceInstance}
[[ "${lTargetDatabase}" == "" ]] && lTargetDatabase=${lSourceDatabase}
typeset -l lLowerSourceDB=${lSourceDatabase}; typeset -l lLowerTargetDB=${lTargetDatabase}

typeset lRestoreScriptDir="${cLogsDirBase}/${lTargetHostName}/${lTargetInstance}"
typeset lRestoreScript="${lRestoreScriptDir}/${lTimestampToday}_${lSourceHostName}_${lSourceInstance}_${lSourceDatabase}_to_${lTargetDatabase}.sql"

#
# Load Db2 library
#
if [ -z "${IBM_DB_HOME}" -o "${DB2_HOME}" == "" ] ; then
  if [ "${DB2INSTANCE}" != "${lTargetInstance}" ] ; then
    lDb2Profile="/home/${lTargetInstance}/sqllib/db2profile"
    if [ ! -f ${lDb2Profile} ] ; then
      lDb2ProfileHome=$( cd ~${lTargetInstance} 2>&1 | grep -v '^$' )
      if [ $( echo ${lDb2ProfileHome} | grep 'No such' | grep -v '^$' | wc -l ) -gt 0 ] ; then
        lDb2ProfileHome=$( grep "^${lTargetInstance}:"  /etc/passwd | cut -d ':' -f 6 )
        if [ "${lDb2ProfileHome}" != "" ] ; then
          lDb2Profile="${lDb2ProfileHome}/sqllib/db2profile"
        fi
      else
        lDb2Profile=~${lTargetInstance}/sqllib/db2profile
      fi
    fi
    if [ ! -f ${lDb2Profile} ] ; then
      gMessage="Unable to locate ${lDb2Profile}"
      showInfo
      lDb2Profile=~${lSourceInstance}/sqllib/db2profile
      gMessage="Trying ${lDb2Profile} instead"
      showInfo
    fi
    [[ ! -f ${lDb2Profile} ]] && gErrorNo=2 && gMessage="Cannot load ${lDb2Profile}" && scriptUsage
    . ${lDb2Profile}
  fi
else
  lDb2Profile=${DB2_HOME}/db2profile
fi

#
# Find the backup image
#
typeset lSearchPattern="${lSourceDatabase}.*.${lSourceInstance}"
if [ ${lSpecificBackupTimestamp} -gt 0 ] ; then
  lSearchPattern="${lSearchPattern}.*.$( printf "%.0f" ${lSpecificBackupTimestamp} )"
fi

if [ -d ${lBackupDirBase} ] ; then
  lBackupImage=$(
      ls -tl $( find ${lBackupDirBase} \
                  -type f \
                  -name "${lSearchPattern}.*[0-9][0-9][0-9]" \
                  -print ) \
    | head -1 \
    | awk -F' ' '{print $9}' )
else
  gErrorNo=10
  gMessage="Couldn't find the directory ${lBackupDirBase} which should hold backups"
  scriptUsage
fi

#
# Set umask
#
umask ${cMasking}

#
# Prepare structure on disk to be able to dump the restore script
#
typeset lOsCmdResult=$( mkdir -p ${lRestoreScriptDir} 2>&1 )
[[ $( echo "${lOsCmdResult}" | grep ' Permission denied' | wc -l ) -gt 0 ]] && gErrorNo=11 && gMessage="Unable to create the directory ${lRestoreScriptDir}" && scriptUsage

chgrp -R ${cDb2CommonSecurityGroup} ${lRestoreScriptDir} > /dev/null 2>&1
chmod 0775 ${lRestoreScriptDir} > /dev/null 2>&1


[[ ! -f ${lBackupImage} ]] && gErrorNo=12 && gMessage="Unable to locate a backup image of ${lSourceDatabase} in ${lBackupDirBase}" && scriptUsage

lBackupTime=$( echo "$( basename ${lBackupImage} )" | cut -d'.' -f 5 )
lBackupDirectory=$( dirname ${lBackupImage} )
typeset -u lBackupType=$( db2ckbkp -H ${lBackupImage} | grep 'Backup Mode' | awk -F' ' '{print $5}' | sed 's/[\(\)]*//g' )
lBackupImgInfo=$( stat -c "%u:%g=%a" ${lBackupImage} )
lBackupOwner=$( echo ${lBackupImgInfo} | cut -d '=' -f1 )
lBackupRights=$( echo ${lBackupImgInfo} | cut -d '=' -f2 )

#
# Two strikes on the privileges of the image and we're out!
#
lStrike=0
lUserInfo=$( id $( whoami ) | sed 's/[=\(\)]/ /g' | tr ' ' '\n' | grep -v '^$' )
[[ $( echo ${lBackupOwner} | cut -d ':' -f1 ) -ne $( echo "${lUserInfo}" | awk '/uid/,/^[0-9][0-9]*$/' | grep -v 'uid' ) && ${lBackupRights:2:1} -lt 4 ]] && lStrike=$(( lStrike + 1 ))

[[ $(   echo ${lBackupOwner} \
      | cut -d ':' -f2 \
      | egrep "^$(   echo "${lUserInfo}" \
                  | awk '/groups/,/^$/' \
                  | grep '^[,]*[0-9][0-9]*$' \
                  | sed 's/^,//g' \
                  | sort -u \
                  | tr ' ' '|' \
                )$" | wc -l ) -eq 0 || ${lBackupRights:1:1} -lt 4 ]] && lStrike=$(( lStrike + 1 ))
[[ ${lStrike} -gt 1 ]] && gErrorNo=13 && gMessage="Not the correct rights to use the backup image ${lBackupImage}. Take corrective actions!" && scriptUsage

echo "Prepare redirected restore script ..."
db2 "RESTORE DB ${lSourceDatabase} FROM ${lBackupDirectory} TAKEN AT ${lBackupTime} INTO ${lTargetDatabase} REDIRECT GENERATE SCRIPT ${lRestoreScript}" >/dev/null 2>&1
[[ ! -f ${lRestoreScript} ]] && lError=12 && gMessage="The script ${lRestoreScript} could not get generated" && scriptUsage
chgrp -R ${cDb2CommonSecurityGroup} ${lRestoreScript}
chmod 0664 ${lRestoreScript} >/dev/null 2>&1
  # Make the backup image readable by at least those in the same group
chmod g+r ${lBackupImage} >/dev/null 2>&1

# =============================
# Start manipulating the script
# =============================
typeset lLogDirectory="${lRestoreScriptDir}/${lTimestampToday}_${lSourceDatabase}_to_${lTargetDatabase}_LOGS"
lRestoreScriptInMem=$(   cat ${lRestoreScript} \
                       | sed "s/\/${lSourceInstance}\//\/${lTargetInstance}\//g; s/\/${lLowerSourceDB}\//\/${lLowerTargetDB}\//g; s/\/LOGSTREAM0000\//\//g; s/\/NODE0000\//\//g; s/^\-\- REPLACE EXISTING/REPLACE EXISTING/g ; s/ ${lSourceDatabase}_NODE0000.out/ $( echo ${lRestoreScriptDir} | sed 's/\//\\\//g' )\/${lTimestampToday}_${lSourceDatabase}_to_${lTargetDatabase}.out/g " \
                       | grep -v '^\-\- \*\*'
                     )

setDistinctOnlineOfflineSettings
setDbPath
setNewLogPath
handleAutomaticStorage

printf -- "-- BackupType: ${lBackupType}\n-- AS support: ${lAutomaticStorageSupported}\n" > ${lRestoreScript}
echo "${lRestoreScriptInMem}" >> ${lRestoreScript}

ls -l ${lRestoreScript}

#
# Finish up
#
set +x
exit 0
