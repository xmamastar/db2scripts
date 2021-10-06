#!/bin/bash
#
# Script     : db2_backup_age.sh
# Description: Return the age of the backups
#
#<header>
#
# Remarks   : Parameters:
#   * Mandatory
#       -I | --instance   : Instance name
#
#   * Optional
#       -D | --database   : (List of comma separated) Database name(s); when
#                             omitted all databases within the instance are
#                             handled, e.g. "DB01 DB02"
#       -U | --user       : User name to connect to the database
#       -P | --password   : The password matching the user name to connect
#                             to the database
#       -X | --exclude    : Database name (or grep pattern); database(s) to
#                             exclude from this script. Not applicable
#                             when the script is initiated for a single database
#       -C | --check      : Check only [regular = DEFAULT], [snapshot] or [all]
#       -q | --quiet      : Quiet - show no messages
#       -h | -H | --help  : Help
#
#</header>

#
# Constants
#
typeset    cCmdSwitchesShort="I:D:U:P:X:C:qhH"
typeset -l cCmdSwitchesLong="instance:,database:,user:,password:,exclude:,check:,quiet,help"
typeset    cHostName=$( hostname | cut -d '.' -f 1 )
typeset    cScriptName="${0}"
typeset    cBaseNameScript=$( basename ${cScriptName} )
typeset    cScriptDir="${cScriptName%/*}"
typeset    cBaseNameConfig="${cBaseNameScript%.*}.cfg"
typeset    cConfigName="${cScriptDir}/${cBaseNameConfig}"
typeset    cCurrentDir=$( pwd )
typeset    cLogsDirBase="/db2exports/db2scripts/logs/${cBaseNameScript%.*}/${cHostName}"
typeset    cMasking="0002"

[[ "${cScriptDir}" == "." ]] && cScriptDir="${cCurrentDir}"

typeset -i cBackupThresholdInHoursWarning=48
typeset -i cBackupThresholdInHoursCritical=120

#
# Functions
#
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
                  | sed 's/,$//g;  s/ //g' )
    lHeader=$(   sed -n ${lHeaderPos}p ${cScriptName} \
               | egrep -v '<[/]*header>|ksh|Description' \
               | uniq \
               | sed 's/^#//g; s/^[ ]*Remarks[ ]*://g' )

    gMessage="${lHeader}"
    [[ "${lExitScript}" == "YES" ]] && gMessage=$( printf "${lHeader}\n\nExiting.\n" )
    showMessage

    set +x
    [[ "${lExitScript}" == "YES" ]] && exit ${gErrorNo}
    return ${gErrorNo}

  }

  function  getThresholdInHours {
    typeset    lConfigLine
    typeset    lThreshold
    typeset -i lDOW=$( date +%u )
    typeset    lDOWrun=""

    [[ "${lFoundValidConfigLine}" != "YES" ]] && lFoundValidConfigLine="NO"
      #
      # Dig up the configuration line, but when many keep the last line
      #
    lConfigLine=$(   cat ${cConfigName} \
                   | sed 's/^[ ]*//g' \
                   | grep -vi ':excluded_table:' \
                   | awk -F: -v IGNORECASE=1 "/^[^#]/&&\$1~/${1}/&&\$2~/${2}/&&\$3~/${3}/&&\$5~/${4}/{print \$4\":\"\$6}" \
                   | tail -1 )
    if [ $( echo ${lConfigLine} | grep ':' | wc -l ) -gt 0 ] ; then
        #
        # What are the threshold definitions?
        #
      lThreshold=$( echo "${lConfigLine}" | cut -d ':' -f 2 )
        #
        # Does the check has to run today? Fetch criteria first.
        #
      lDOWrun=$(   echo  ${lConfigLine} \
                 | cut -d ':' -f 1 \
                 | tr -d ' ' \
                 | grep '[1-7][1-7,\-]*' \
                 | sed 's/,/\n/g' \
                 | sort -n )

        #
        # Default values
        #
      lThresholdInHoursWarning=${cBackupThresholdInHoursWarning}
      lThresholdInHoursCritical=${cBackupThresholdInHoursCritical}
      lCheckToday="YES"
    fi

    if [ ! -z "${lThreshold}" ] ; then
      lFoundValidConfigLine="YES"
      if [ $( echo ${lThreshold} | grep ';' | wc -l ) -gt 0 ] ; then
        lThresholdInHoursWarning=$( echo ${lThreshold} | cut -d ';' -f 1 )
        lThresholdInHoursCritical=$( echo ${lThreshold} | cut -d ';' -f 2 )
      else
        lThresholdInHoursWarning=0
        lThresholdInHoursCritical=${lThreshold}
      fi
        #
        # The check needs to run daily
        #
      [[ "${lDOWrun}" == "*" ]] && set +x && return 0
        #
        # The check needs to run today specifically
        #
      if [ $( echo "${lDOWrun}" | sed 's/^/,/g; s/$/,/g' | grep ",${lDOW}," | wc -l ) -gt 0 ] ; then
        set +x
        return 0
      fi
        #
        # Is today hidden within a range?
        #
      lDOWrun=$( echo "${lDOWrun}" | grep '-' )
        #
        # Today doesn't fit in any of the definitions -> bail out
        #
      if [ "${lDOWrun}" == "" ] ; then
        [[ "${lFoundValidConfigLine}" != "YES" ]] && lThresholdInHoursCritical=0
        set +x
        return 0
      fi
        #
        # Run through all defined ranges
        #
      for lDOWrunSet in ${lDOWrun}
      do
        typeset lDOWrunLow=$( echo ${lDOWrunSet} | cut -d '-' -f 1 )
        typeset lDOWrunHigh=$( echo ${lDOWrunSet} | cut -d '-' -f 2 )
          #
          # Is today within this particular range?
          #
        if [ ${lDOW} -ge ${lDOWrunLow} -a ${lDOW} -le ${lDOWrunHigh} ] ; then
          set +x
          return 0
        fi
      done
        #
        # Still no match?
        #   Today doesn't fit in any of the definitions, but a config line
        #   does exist -> bail out
        #
      [[ "${lFoundValidConfigLine}" == "YES" ]] && lCheckToday="No" && lThresholdInHoursCritical=0
    fi

    set +x
    return 0
  }

  function  getExcludedTables {
    typeset    lConfigLine
    typeset    lThreshold
    typeset -i lDOW=$( date +%u )
    typeset    lDOWrun=""

      #
      # Dig up the configuration line, but when many keep the last line
      #
    lConfigLine=$(   cat ${cConfigName} \
                   | sed 's/^[ ]*//g' \
                   | grep -i ':excluded_table:' \
                   | awk -F: -v IGNORECASE=1 "/^[^#]/&&\$1~/${1}/&&\$2~/${2}/&&\$3~/${3}/&&\$5~/${4}/{print \$6}" \
                   | tail -1 )
    if [ $( echo ${lConfigLine} | grep -v '^$' | wc -l ) -gt 0 ] ; then
        #
        # What are the threshold definitions?
        #
      lThreshold=$(   echo "${lConfigLine}" \
                    | grep -v '^$' \
                    | sed "s/[ ]*,[ ]*/','/g; s/^/'/g; s/$/'/g; s/''/'/g" )
    fi

    if [ ! -z "${lThreshold}" ] ; then
      lExcludedTables=$(   echo "${lExcludedTables},${lThreshold}" \
                         | sed 's/^,//g; s/,$//g; s/[ ]*,[ ]*/, /g' )
    fi

    set +x
    return 0
  }

  function getBackupStatus {

    typeset lHostName="${1}"
    typeset lInstance="${2}"
    typeset lDatabase="${3}"
    typeset lBackupType="${4}"

    typeset    lReturnedText=""
    typeset -i lReturnedStatus=0
    typeset    lReturnLine=""
    typeset -u lMultipleBackupTypes="No"
    typeset -u lPerformCalculation="No"

    typeset    lBackupInfo=""
    typeset    lBackupAgeHours
    typeset    lBackupTimestamp
    typeset    lBackupMetrics=""

    typeset    lUtilityReturnText=""

    typeset -A aThresholdInHoursWarning
    typeset -A aThresholdInHoursCritical
    typeset -A aExcludedTables
    typeset -A aCheckToday

    typeset lCheckmkServiceName="Age_last_backup_${lHostName}_${lInstance}_${lDatabase}"
    typeset lStatusText="UNKNOWN"
    lReturnedStatus=3
    if [ $( echo ${lBackupType} | grep ' ' | wc -l ) -gt 0 ] ; then
      lMultipleBackupTypes="Yes"
    fi

    for lBackupTypeToCheck in ${lBackupType}
    do
       lExcludedTables=""
         # Get applicable threshold from config file
       getThresholdInHours "*"            "*"            "*"            "${lBackupTypeToCheck}"
       getThresholdInHours "${cHostName}" "*"            "*"            "${lBackupTypeToCheck}"
       getThresholdInHours "${cHostName}" "${lInstance}" "*"            "${lBackupTypeToCheck}"
       getThresholdInHours "${cHostName}" "${lInstance}" "${lDatabase}" "${lBackupTypeToCheck}"

         # Get excluded tables from config file
       getExcludedTables "*"            "*"            "*"            "${lBackupTypeToCheck}"
       getExcludedTables "${cHostName}" "*"            "*"            "${lBackupTypeToCheck}"
       getExcludedTables "${cHostName}" "${lInstance}" "*"            "${lBackupTypeToCheck}"
       getExcludedTables "${cHostName}" "${lInstance}" "${lDatabase}" "${lBackupTypeToCheck}"

       aThresholdInHoursWarning[${lBackupTypeToCheck}]=${lThresholdInHoursWarning}
       aThresholdInHoursCritical[${lBackupTypeToCheck}]=${lThresholdInHoursCritical}
       aExcludedTables[${lBackupTypeToCheck}]=${lExcludedTables}

       aCheckToday[${lBackupTypeToCheck}]=${lCheckToday}

       [[ ${lThresholdInHoursCritical} -ne 0 ]] && lPerformCalculation="Yes"
    done
      # Threshold for all BackupType = 0 -> Don't check
    if [ "${lPerformCalculation}" != "YES" ]; then
      lReturnedStatus=10
      for lBackupTypeToCheck in ${lBackupType}
      do
        if [ "${aCheckToday[${lBackupTypeToCheck}]}" == "NO" ] ; then
          if [ "${lMultipleBackupTypes}" == "Yes" ] ; then
            lCheckmkServiceName=$(   echo "${lCheckmkServiceName}" \
                                   | sed "s/\(Age_last_backup_\)/\1${lBackupTypeToCheck}_/g" )
          fi
            # Get applicable threshold from config file
          lThresholdInHoursWarning=${aThresholdInHoursWarning[${lBackupTypeToCheck}]}
          lThresholdInHoursCritical=${aThresholdInHoursCritical[${lBackupTypeToCheck}]}

          lBackupMetrics="${lThresholdInHoursWarning};${lThresholdInHoursCritical};0"

          lReturnedStatus=0
          lStatusText="OK"

          lReturnLine="${lReturnedStatus} ${lCheckmkServiceName} age_hours=${lBackupMetrics}; ${lStatusText} - No check configured for today for a ${lBackupTypeToCheck} backup"
        fi
      done

      set +x
      return ${lReturnedStatus}
    fi

    if db2 +o connect to ${lDatabase} ; then
      typeset lSql="with latestBackupInfo AS (
                      SELECT MAX(start_time) backupTime
                        FROM sysibmadm.db_history
                       WHERE operation = 'B'
                         AND OPERATIONTYPE IN ( 'F', 'N' )
                    )

                    SELECT 'backup image of ' || TRIM(TIMESTAMP_FORMAT(latestBackupInfo.backupTime, 'YYYY-MM-DD HH24:MI:SS'))
                        || ' has no value since a non-recoverable load into '
                        || TRIM(TABSCHEMA) || '.' || TRIM(TABNAME)
                        || ' on ' || TRIM(TIMESTAMP_FORMAT(start_time, 'YYYY-MM-DD HH24:MI:SS'))
                      FROM sysibmadm.db_history
                         , latestBackupInfo
                     WHERE operation = 'L'
                       AND UPPER(CMD_TEXT) LIKE '%NON-RECOVERABLE%'
                       AND START_TIME > latestBackupInfo.backupTime
                       -- #ExcludedTablesPlaceHolder#
                  ORDER BY 1 DESC
                      WITH UR
                  FOR READ ONLY"
      for lBackupTypeToCheck in ${lBackupType}
      do
        typeset lSqlSpecific="${lSql}"
        if [ "${aExcludedTables[${lBackupTypeToCheck}]}" != "" ] ; then
          typeset lSqlExtra="AND NOT EXISTS ( SELECT 1 FROM (VALUES(${aExcludedTables[${lBackupTypeToCheck}]})) as ExclTable(Name) WHERE ExclTable.Name = TRIM(TABSCHEMA) || '.' || TRIM(TABNAME) )"
          lSqlSpecific=$(   echo "${lSqlSpecific}" \
                          | sed "s:\-\- #ExcludedTablesPlaceHolder#:${lSqlExtra}:g" )
        fi
        typeset lNonRecoverable=""
	lNonRecoverable=$( db2 -x ${lSqlSpecific} )

         # The backup image is worth nothing, but proving why it is already
         #   sufficient by showing the first error, hence 'head -1'
        lNonRecoverable=$( echo "${lNonRecoverable}" | grep -v '^$' | head -1 | sed 's/[ ]*$//g' )

        if [ "${lNonRecoverable}" == "" ] ; then
          if [ "${lMultipleBackupTypes}" == "Yes" ] ; then
            lCheckmkServiceName=$(   echo "${lCheckmkServiceName}" \
                                   | sed "s/\(Age_last_backup_\)/\1${lBackupTypeToCheck}_/g" )
          fi

          lFoundValidConfigLine="NO"
            # Get applicable threshold from config file
          lThresholdInHoursWarning=${aThresholdInHoursWarning[${lBackupTypeToCheck}]}
          lThresholdInHoursCritical=${aThresholdInHoursCritical[${lBackupTypeToCheck}]}

          lBackupMetrics="${lThresholdInHoursWarning};${lThresholdInHoursCritical};0"

            # Values for DB_HISTORY.DEVICETYPE for regular and snapshot backup
          [[ ${lBackupTypeToCheck} == "regular" ]] && lBackupDeviceType='D' || lBackupDeviceType='f'

          lBackupInfo=$( db2 -x "SELECT TIMESTAMPDIFF(8, CURRENT TIMESTAMP - TIMESTAMP(COALESCE(MAX(start_time), '19700101000000')))
                                      , TIMESTAMP_FORMAT(MAX(start_time), 'YYYY-MM-DD HH24:MI:SS', 0)
                                   FROM sysibmadm.db_history
                                  WHERE operation  = 'B'
                                    AND devicetype = '${lBackupDeviceType}'
                                    AND SQLCODE IS NULL
                               GROUP BY start_time
                               ORDER BY start_time DESC
                            FETCH FIRST 1 ROW ONLY" )

          lReturnedStatus=2
          lStatusText="CRITICAL"
          if [ $( echo "${lBackupInfo}" | grep '^SQL[0-9][0-9]*[NWC]' | wc -l ) -eq 0 ] ; then
            lBackupAgeHours=$( echo ${lBackupInfo} | cut -f1 -d" " )
            lBackupTimestamp=$( echo ${lBackupInfo} | cut -f2 -d" " )
            lBackupMetrics="${lBackupAgeHours};${lBackupMetrics}"

              # Compare age to threshold and notify Check_mk
            [[ $lBackupAgeHours -le ${lThresholdInHoursCritical} ]] && lReturnedStatus=1 && lStatusText="WARNING"
            [[ $lBackupAgeHours -le ${lThresholdInHoursWarning} ]] && lReturnedStatus=0 && lStatusText="OK"

            lReturnLine="${lReturnedStatus} ${lCheckmkServiceName} age_hours=${lBackupMetrics}; ${lStatusText} - ${lBackupAgeHours} hours since last full backup at ${lBackupTimestamp}"
          else
            lBackupMetrics="0;${lBackupMetrics}"
            lReturnLine="${lReturnedStatus} ${lCheckmkServiceName} age_hours=${lBackupMetrics}; ${lStatusText} - ${lBackupTypeToCheck} failure fetching the backup timestamp"
          fi

        else
          lReturnedStatus=2
          lStatusText="CRITICAL"
          lBackupMetrics="0;${cBackupThresholdInHoursWarning};${cBackupThresholdInHoursCritical};0"
          lReturnLine="${lReturnedStatus} ${lCheckmkServiceName} age_hours=${lBackupMetrics}; ${lStatusText} - ${lBackupTypeToCheck} ${lNonRecoverable}"
        fi
      done
        # Disconnect from database
      db2 connect reset > /dev/null
    else
      lReturnedStatus=2
      lStatusText="CRITICAL"
      lBackupMetrics="0;${cBackupThresholdInHoursWarning};${cBackupThresholdInHoursCritical};0"

      lUtilityReturnText=$(   db2pd -utilities \
                            | grep " ${lDatabase} " \
                            | awk -F' ' '{print $3" since "$7" "$8" "$9" "$10 }' \
                            | grep -v '^$'
                          )
      if [ "${lUtilityReturnText:0:5}" == "BACKUP" "${lUtilityReturnText:0:6}" == "RESTORE" ] ; then
        lReturnedStatus=1
        lStatusText="WARNING"
        lUtilityReturnText=" (${lUtilityReturnText})"
      else
        lUtilityReturnText=""
      fi
      lReturnLine="${lReturnedStatus} ${lCheckmkServiceName} age_hours=${lBackupMetrics}; ${lStatusText} - ${lBackupTypeToCheck} cannot connect to this database${lUtilityReturnText}"
    fi

    [[ ${lReturnedStatus} -lt 10 && "${lReturnLine}" != "" ]] && echo "${lReturnLine}"
    set +x
    return 0
  }

#
# Primary initialization of commonly used variables
#
typeset    lTimestampToday=$( date "+%Y-%m-%d-%H.%M.%S" )
typeset    lDb2Profile=""
typeset    lDb2ProfileHome=""
typeset -l lInstance=""
typeset -u lDatabase=""
typeset -u lExcludedDatabase="^$"
typeset    lUsername=""
typeset    lPassword=""
typeset -u lCheck="REGULAR"
typeset -u lVerbose="YES"
typeset -l lBackupType=""
typeset    lBackupDeviceType=""
typeset -i lThresholdInHoursWarning=${cBackupThresholdInHoursWarning}
typeset -i lThresholdInHoursCritical=${cBackupThresholdInHoursCritical}
typeset    lExcludedTables=""
typeset -u lCheckToday=""
typeset -i lStatus=0
typeset -i lReturnCode=0
typeset -u lFoundValidConfigLine=""

#
# Loading libraries
#
[[ ! -f ${cScriptDir}/common_functions.include ]] && gErrorNo=2 && gMessage="Cannot load ${cScriptDir}/common_functions.include" && scriptUsage
. ${cScriptDir}/common_functions.include
[[ ! -f ${cScriptDir}/db2_common_functions.include ]] && gErrorNo=2 && gMessage="Cannot load ${cScriptDir}/db2_common_functions.include" && scriptUsage
. ${cScriptDir}/db2_common_functions.include

#
# If the script is launched without any parameter, then cycle through all
#   server instances and run the script for each instance
#
if [ $# -eq 0 ]; then
  fetchAllDb2Instances
  #
  # Are we dealing with an instance owner? If not, sniff out all server
  #   instances and get information of each and every one of them.
  #   In the other case, just continue the normal flow of the script.
  #
  if [ $( echo "${gDb2InstancesList}" | grep "^${USER}$" | wc -l ) -eq 0 ] ; then
    for lInstanceToHandle in ${gDb2InstancesList}
    do
      # Run in the background
      (
        lReturnedText=$( ${cScriptName} --instance ${lInstanceToHandle} 2>&1 )
        lReturnCode=$?
        if [ ${lReturnCode} -eq 0 -a "${lReturnedText}" != "" ] ; then
          echo "${lReturnedText}"
        fi
      ) 2>&1 &
    done
    # Wait for all executions-per-instance to return
    wait
    set +x
    exit 0
  else
    eval set -- $( echo "--instance ${USER}" )
  fi
fi

#
# Check on the existence of the configuration file
#
[[ ! -f ${cConfigName} ]] && gErrorNo=2 && gMessage="Cannot load the configuration file ${cConfigName}" && scriptUsage

#
# Check for the input parameters
#
    # Read and perform a lowercase on all '--long' switch options, store in $@
  eval set -- $(   echo "$@" \
                 | tr ' ' '\n' \
                 | sed 's/^\(\-\-.*\)/\L\1/' \
                 | tr '\n' ' ' \
                 | sed 's/^[ ]*//g; s/[ ]*$/\n/g; s/|/\\|/g' \
                 | sed 's:\(\-[\-]*[a-z_]*\)\( \):\1[_]:g' \
                 | sed 's:\( \)\(\-[\-]\)\([a-zA-Z0-9]\):[_]\2\3:g' \
                 | sed 's:\( \)\(\-\)\([a-zA-Z0-9]\):[_]\2\3:g' \
                 | sed 's: :[blank]:g; s:\[_\]: :g' \
               )

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
    _lCmdValue=$( echo "${2}" | sed 's:\[blank\]: :g' )
    [[ "${_lCmdOption}" == "" && "${_lCmdValue}" == "" ]] && _lCmdOption="--"

    case ${_lCmdOption} in
      -I | --instance )
        lInstance="${_lCmdValue}"
        shift 2
        ;;
      -D | --database )
        lDatabase="${_lCmdValue}"
        shift 2
        ;;
      -U | --user )
        lUsername="${_lCmdValue}"
        shift 2
        ;;
      -P | --password )
        lPassword="${_lCmdValue}"
        shift 2
        ;;
      -X | --exclude )
        lExcludedDatabase="${_lCmdValue}"
        shift 2
        ;;
      -C | --check )
        lCheck="${_lCmdValue}"
        shift 2
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
[[ "${lInstance}" == "" ]] && gErrorNo=1 && gMessage="Please provide an instance to do the work for" && scriptUsage
if [ "${lCheck}" != "REGULAR" ] ; then
  if [ "${lCheck}" != "ALL" -a "${lCheck}" != "SNAPSHOT" ] ; then
    gErrorNo=1
    gMessage="Do not specify the switch '--check' if you want to see REGULAR, or choose between SNAPSHOT and ALL"
    scriptUsage
  fi
fi

#
# Force variable(s) to values within boundaries and set a default when needed
#
[[ "${lVerbose}" != "NO" ]] && lVerbose="YES"

#
# Make sure logging can be done properly
#
  # Nothing to log

#
# Load Db2 library
#
  # Only load when not yet done
if [ -z "${IBM_DB_HOME}" -o "${DB2INSTANCE}" != "${lInstance}" ] ; then
  lDb2Profile="/home/${lInstance}/sqllib/db2profile"
  if [ ! -f ${lDb2Profile} ] ; then
    lDb2ProfileHome=$( cd ~${lInstance} 2>&1 | grep -v '^$' )
    if [ $( echo ${lDb2ProfileHome} | grep 'No such' | grep -v '^$' | wc -l ) -gt 0 ] ; then
      lDb2ProfileHome=$( grep "^${lInstance}:"  /etc/passwd | cut -d ':' -f 6 )
      if [ "${lDb2ProfileHome}" != "" ] ; then
        lDb2Profile="${lDb2ProfileHome}/sqllib/db2profile"
      fi
    else
      lDb2Profile=~${lInstance}/sqllib/db2profile
    fi
  fi
  [[ ! -f ${lDb2Profile} ]] && gErrorNo=2 && gMessage="Cannot load ${lDb2Profile}" && scriptUsage
  . ${lDb2Profile}
fi

#
# Validate the input data
#
if [ "${lDatabase}" != "" ] ; then
  lDatabase=$( echo ${lDatabase} | tr ',' '\n' | grep -v '^$' )
  if [ $( echo ${lDatabase} | grep -v '^$' | wc -l ) -gt 1 ] ; then
    lDatabaseList=$(   echo "${lDatabase}" \
                     | egrep -v "${lExcludedDatabase}" )
  else
    lDatabaseList=${lDatabase}
    lExcludedDatabase="^$"
  fi
else
  fetchAllDb2Databases
  lDatabaseList=$(   echo "${gDb2DatabaseList}" \
                   | egrep -v "${lExcludedDatabase}" )
 set +x
fi

#
# Set default umask
#
umask ${cMasking}

#
# Main - Get to work
#
case ${lCheck} in
  ALL )
    lBackupType="regular snapshot"
  ;;
  REGULAR )
    lBackupType="regular"
  ;;
  SNAPSHOT )
    lBackupType="snapshot"
  ;;
esac

for lDbToHandle in ${lDatabaseList}
do
  getBackupStatus "${cHostName}" "${lInstance}" "${lDbToHandle}" "${lBackupType}"
done

#
# Finish up
#
set +x
exit 0
