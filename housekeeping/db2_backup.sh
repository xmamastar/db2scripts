#!/bin/bash
#
# Script     : db2_backup.sh
# Description: Make a backup of a Db2 database
#
#<header>
#
# Remarks   : Parameters:
#   * Mandatory
#       -I | --instance   : Instance name
#
#   * Optional
#       -D | --database   : Database name; when omitted all databases within
#                             the instance are backuped
#       -x | --exclude    : Database name (or grep pattern); database(s) to
#                             exclude from the backup process. Not applicable
#                             when a backup is initiated for a single database
#       -T | --backuptype : Backup type
#                             * ONLINE  - The default for databases in archive
#                                           logging or the ones not activated
#                             * OFFLINE - The default for databases in circular
#                                           logging
#       -i | --includelogs: Include logs (ONLINE backups only)
#       -f | --force      : Force the backup
#                             When a backup fails, a maximum of 10 retries
#                             are done. The sleeptime between each try will
#                             decrease geometrically from 20 to 1 second
#       -a | --alias      : Alias with which the database (in an instance and
#                             on a server) is uniquely identifiable
#       -j | --job        : Job name executing this script
#                             when something went wrong
#       -m | --mailto     : (List of) Email address(es) whom should get notified
#                             when something went wrong
#       -c | --mailcc     : (List of) Email address(es) whom should get notified
#                             in cc when something went wrong
#       -t | --test       : Run through the script without actually executing
#                             a backup or applying the retention
#       -q | --quiet      : Quiet - show no messages
#       -h | -H | --help  : Help
#
#</header>

#
# Constants
#
typeset    cCmdSwitchesShort="I:D:x:T:a:j:m:c:tqifhH"
typeset -l cCmdSwitchesLong="instance:,database:,exclude:,backuptype:,alias:,job:,mailto:,mailcc:,test,quiet,includelogs,force,help"
typeset    cHostName=$( hostname | cut -d '.' -f1 )
typeset    cScriptName="${0}"
typeset    cBaseNameScript=$( basename ${cScriptName} )
typeset    cScriptDir="${cScriptName%/*}"
typeset    cCurrentDir=$( pwd )
typeset    cLogsDirBase="/db2exports/db2scripts/logs/${cBaseNameScript%.*}"
typeset    cBackupDir="/db2exports/backup"
typeset    cMailFrom="${cHostName}-${USER}@onva-rjv.fgov.be"
typeset    cMasking="0002"

[[ "${cScriptDir}" == "." ]] && cScriptDir="${cCurrentDir}"

typeset -i cNumberOfTries=10
typeset -i cSleepBetweenTries=20
typeset -i cRecHistoryRetention=366
typeset -i cBackupRetention=1
typeset -i cBackupRetentionMax=60

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
                 | sed -e 's/$/,/g' )
    lHeaderPos=$(   echo ${lHeaderPos} \
                  | sed -e 's/,$//g' -e 's/ //g' )
    lHeader=$(   sed -n ${lHeaderPos}p ${cScriptName} \
               | egrep -v '<[/]*header>|ksh|Description' \
               | uniq \
               | sed -e 's/^#//g' -e 's/^[ ]*Remarks[ ]*://g' )

    gMessage=$( printf "${lHeader}\n\nExiting.\n" )
    showMessage

    set +x
    [[ "${lExitScript}" == "YES" ]] && exit ${gErrorNo}
    return ${gErrorNo}

  }

  function sendMail {

    typeset -l lInstance="${1}"
    typeset -u lDatabase="${2}"
    typeset -i lBackupReturnCode=${3}
    typeset    lLogOutput="${4}"
    typeset    lSwitches=""

    typeset    lDatabaseId=""
    typeset    lSubject=""

    lDatabaseId="${cHostName},${lInstance},${lDatabase}"
    [[ "${lAlias}" != "" ]] && lDatabaseId="${lAlias}=${lDatabaseId}"
    [[ "${lJobName}" == "" ]] && lJobName="Backup"
    lSubject="${lJobName} (${lDatabaseId}) - ${cBaseNameScript}: ABEND"

    if [ "${lMailTo}" != "" ] ; then
      if [ "${lVerbose}" == "YES" ] ; then
        echo "--> Sending email report on failure to ${lMailTo}"
      fi
      echo "
--> Sending email report on failure to ${lMailTo}" >> ${lLogOutput}

      if [ "${lMailCc}" != "" ] ; then
        cat ${lLogOutput} \
          | mailx \
              -r "${cMailFrom}" \
              -s "${lSubject}" \
              -c "${lMailCc}" \
                 "${lMailTo}"
      else
        cat ${lLogOutput} \
          | mailx \
              -r "${cMailFrom}" \
              -s "${lSubject}" \
                 "${lMailTo}"
      fi
    fi

    set +x
    return 0
  }

  function determineRetentionPeriod {

    typeset    lHostName="${1}"
    typeset -l lInstance="${2}"
    typeset -u lDatabase="${3}"

    typeset -l lEnvironment=$( echo ${lInstance:6:1} )

    lBackupRetentionPeriod=${cBackupRetention}

    case ${lHostName} in
      vr8db201t )
          # POC environment
          lBackupRetentionPeriod=${cBackupRetention}
          lBackupRetentionPeriodDb2=$(( lBackupRetentionPeriod + 2 ))
        ;;
    esac

    #
    # For this database none of the above applied? Try the comment
    #
    if [ ${lBackupRetentionPeriod} -eq 0 ] ; then
      gDatabase="${lDatabase}"
      getCurrentDbComment   # returns ${gDb2DbComment}

      lBackupRetentionPeriod="$(   echo \"${gDb2DbComment}\" \
                                 | sed 's/BACKUP RET=//g' \
                                 | tr -d ' '
                               )"
      lBackupRetentionPeriodDb2=$(( lBackupRetentionPeriod + 2 ))
    fi

    #
    # Still nothing? Take the defaults
    #
    if [ ${lBackupRetentionPeriod} -eq 0 ] ; then
      lBackupRetentionPeriod=${cBackupRetention}
      lBackupRetentionPeriodDb2=$(( lBackupRetentionPeriod + 2 ))
    fi

    set +x
    return 0
  }

  function preserveRetentionPeriod {

    typeset -l lInstance="${1}"
    typeset -u lDatabase="${2}"
    typeset    lLogOutput="${3}"
    typeset -i lReturnCode=0

    if [ ${lBackupRetentionPeriod} -eq 0 -o \
         ${lBackupRetentionPeriod} -gt ${cBackupRetentionMax} ] ; then
      lBackupRetentionPeriod=${cBackupRetention}
    fi

    gDatabase="${lDatabase}"
    gDb2DbComment="BACKUP RET=${lBackupRetentionPeriod}"
    gMessage="Setting the comment '${gDb2DbComment}' for database ${gDatabase}"
    if [ "${lVerbose}" == "YES" ] ; then
      showInfo
    fi
    lReturnCode=0
    if [ "${lTestRun}" == "NO" ] ; then
      setCurrentDbComment 2>&1 | sed 's/^/\t/g' >> ${lLogOutput}
      lReturnCode=$?
    else
      echo "${gMessage} intended" | sed 's/^/\t/g' >> ${lLogOutput}
    fi
    [[ ${lReturnCode} -ne 0 ]] && set +x && ${lReturnCode}

    if [ "${lVerbose}" == "YES" ] ; then
      gMessage="Adapting the database configuration for database ${gDatabase}"
      showInfo
    fi
    lReturnCode=0
    if [ "${lVerbose}" == "YES" ] ; then
      gMessage="Setting DB CFG REC_HIS_RETENTN  ${cRecHistoryRetention}"
      showInfo
      gMessage="Setting DB CFG NUM_DB_BACKUPS   ${lBackupRetentionPeriodDb2}"
      showInfo
      gMessage="Setting DB CFG AUTO_DEL_REC_OBJ ON"
      showInfo
    fi
    if [ "${lTestRun}" == "NO" ] ; then
      db2 +o "CONNECT TO ${lDatabase}" >/dev/null 2>&1
      db2  "UPDATE DB CFG
              USING REC_HIS_RETENTN  ${cRecHistoryRetention}
                    NUM_DB_BACKUPS   ${lBackupRetentionPeriodDb2}
                    AUTO_DEL_REC_OBJ ON
              IMMEDIATE " 2>&1 | sed 's/^/\t/g' >> ${lLogOutput}
      lReturnCode=$?
      db2 +o "CONNECT RESET"  >/dev/null 2>&1
    else
      echo "
Indication of DB CFG updates:
 - REC_HIS_RETENTN  ${cRecHistoryRetention}
 - NUM_DB_BACKUPS   ${lBackupRetentionPeriodDb2}
 - AUTO_DEL_REC_OBJ ON
" | sed 's/^/\t/g' >> ${lLogOutput}
    fi

    set +x
    return ${lReturnCode}
  }

  function applyRetentionPeriod {

    typeset -l lInstance="${1}"
    typeset -u lDatabase="${2}"
    typeset -i lRetentionPeriod=${3}
    typeset -u lSshUsable="${4}"
    typeset    lBackupDir="${5}"
    typeset    lLogOutput="${6}"
    typeset -i lReturnCode=0

    #
    #   * Keep as many files as 'the retention parameter' indicates
    #   * If the number of files is exceeded, keep the files for
    #       as many days as indicated by the 'retention period parameter'
    #  e.g. for a retention parameter equal to 5
    #    --> Keep at least 5 copies and when more copies are found,
    #        keep whatever is found but 5 days
    #
    typeset -i lNumberOfCopies=0
    typeset    lRemoveList=""
    typeset    lFileList=""
    typeset    lLogDirectory=""
    typeset    lDirectoryList=""
    typeset -i lNumberOfFiles=0
    typeset    lRmResult=""
    typeset    lNumberOfCopies_cmd=""
    typeset    lRemoveList_cmd=""
    typeset    lFileList_cmd=""
    typeset    lDirectoryList_cmd=""
    typeset    lNumberOfFiles_cmd=""
    typeset    lLogDirectory_cmd=""
    typeset -i lLogDirectoryExists=1

    typeset lNumberOfCopies_cmd=" find ${lBackupDir} \
                                    -maxdepth 1 \
                                    -type f \
                                      -name '*${lDatabase}*${lInstance}*.00[0-9]*' \
                                | grep -v '^$' \
                                | wc -l 2>&1"
    if [ "${lSshUsable}" == "YES" ] ; then
      lNumberOfCopies=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no \
                           ${lInstance}@localhost "${lNumberOfCopies_cmd}" )
    else
      lNumberOfCopies=$( eval "${lNumberOfCopies_cmd}" )
    fi

    if [ "${lVerbose}" == "YES" ] ; then
      gMessage="Applying retention period of ${lRetentionPeriod} for database ${lDatabase}"
      showInfo
    fi

    lRemoveList_cmd="  find ${lBackupDir} \
                         -maxdepth 1  \
                         -type f \
                         -mtime ${lRetentionPeriod} \
                         -name '*${lDatabase}*${lInstance}*.[0-9][0-9]*' ;
                       find ${lBackupDir} \
                         -maxdepth 1  \
                         -type f \
                         -mtime +${lRetentionPeriod} \
                         -name '*${lDatabase}*${lInstance}*.[0-9][0-9]*' ;
                    "
    if [ ${lNumberOfCopies} -gt ${lRetentionPeriod} ] ; then
      if [ "${lSshUsable}" == "YES" ] ; then
        lRemoveList=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no \
                         ${lInstance}@localhost "${lRemoveList_cmd}" )
      else
        lRemoveList=$( eval "${lRemoveList_cmd}" )
      fi
      lRemoveList=$(   echo "${lRemoveList}" \
                     | grep -v '^$' )

# Start - Code to remove when migrated to a single set of servers
  #
  # List all the backup images but keep only ${lRetentionPeriod}-copies on disk
  #  --> all others are now part of ${lRemoveList}
  #
      lFileList_cmd=" find ${lBackupDir} \
                        -maxdepth 1 \
                        -type f \
                        -name '*${lDatabase}*${lInstance}*.[0-9][0-9]*'
                    "
      if [ "${lSshUsable}" == "YES" ] ; then
        lFileList=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no \
                       ${lInstance}@localhost "${lFileList_cmd}" )
      else
        lFileList=$( eval "${lFileList_cmd}" )
      fi
      lRemoveList=""

      if [ "${lFileList}" != "" ] ; then
        lRemoveList_cmd="   ls -t1 \$( echo '${lFileList}' ) \
                          | sed -n \$(( ${lRetentionPeriod} + 1 )),\\\$p"
        if [ "${lSshUsable}" == "YES" ] ; then
          lRemoveList=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no \
                           ${lInstance}@localhost "${lRemoveList_cmd}" )
        else
          lRemoveList=$( eval "${lRemoveList_cmd}" )
        fi
      fi
# Stop - Code to remove when migrated to a single set of servers

      echo "---
Applying retention period of ${lRetentionPeriod} for database ${lDatabase}" \
        | sed 's/^/\t/g' >> ${lLogOutput}
      if [ "${lRemoveList}" != "" ] ; then
        if [ "${lTestRun}" == "NO" ] ; then
          echo " Files to remove:" | sed 's/^/\n\t/g' >> ${lLogOutput}
        else
          echo " Files indicated to remove:" | sed 's/^/\n\t/g' >> ${lLogOutput}
        fi
        echo "${lRemoveList}" | sed 's/^/\t  - /g' >> ${lLogOutput}
        #
        # Only remove files when not running in TEST mode
        #
        if [ "${lTestRun}" == "NO" ] ; then
          if [ "${lSshUsable}" == "YES" ] ; then
            lRemoveList=$( echo "${lRemoveList}" | sed 's/^/rm -f /g' )
            lRmResult=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no ${lInstance}@localhost "${lRemoveList}" 2>&1 )
          else
            lRmResult=$( rm -f ${lRemoveList} 2>&1 )
          fi
          if [ $( echo "${lRmResult}" | grep -i permission | wc -l ) -gt 0 ] ; then
            echo "${lRmResult}" | sed 's/^/\t  - /g' >> ${lLogOutput}
            gMessage="Files (some?) could not get removed"
            [[ "${lVerbose}" == "YES" ]] && showError
          fi
        fi
      else
        echo "  No files found to remove" | sed 's/^/\t/g' >> ${lLogOutput}
      fi
      echo "" >> ${lLogOutput}
    fi

    if [ "${lLogMethod}" != "CIRCULAR" ] ; then
      if [ "${lVerbose}" == "YES" ] ; then
        gMessage="Database ${lDatabase} is using archival logging, checking retention of LOGs"
        showInfo
      fi
      if [ "${lLogMethodDbCfg}" != "LOGRETAIN" ] ; then
        lLogDirectory="${lLogMethodDbCfg}/${lInstance}/${lDatabase}"
      fi

      if [ "${lLogDirectory}" != "" ] ; then
        lLogDirectory_cmd="[[ -d ${lLogDirectory} ]] && echo 0 || echo 1"
        if [ "${lSshUsable}" == "YES" ] ; then
          lLogDirectoryExists=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no \
                             ${lInstance}@localhost "${lLogDirectory_cmd}" )
        else
          lLogDirectoryExists=$( eval "${lLogDirectory_cmd}" )
        fi
        if [ ${lLogDirectoryExists} -eq 0 ] ; then
          lFileList_cmd=" find ${lLogDirectory} \
                            -type f \
                            -name 'S[0-9][0-9]*.LOG' \
                            -mtime +${lRetentionPeriod}"
          if [ "${lSshUsable}" == "YES" ] ; then
            lFileList=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no \
                           ${lInstance}@localhost "${lFileList_cmd}" )
          else
            lFileList=$( eval "${lFileList_cmd}" )
          fi

          lRemoveList=""
          if [ "${lFileList}" != "" ] ; then
            lRemoveList_cmd="   ls -t1 \$( echo '${lFileList}' ) \
                              | sort"
            if [ "${lSshUsable}" == "YES" ] ; then
              lRemoveList=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no \
                               ${lInstance}@localhost "${lRemoveList_cmd}" )
            else
              lRemoveList=$( eval "${lRemoveList_cmd}" )
            fi
          fi

          echo "---
Applying retention period on LOGs of ${lRetentionPeriod} for database ${lDatabase}" \
            | sed 's/^/\t/g' >> ${lLogOutput}
          if [ "${lRemoveList}" != "" ] ; then
            if [ "${lTestRun}" == "NO" ] ; then
              echo " Files to remove:" | sed 's/^/\n\t/g' >> ${lLogOutput}
            else
              echo " Files indicated to remove:" | sed 's/^/\n\t/g' >> ${lLogOutput}
            fi
            echo "${lRemoveList}" | sed 's/^/\t  - /g' >> ${lLogOutput}
            #
            # Only remove files when not running in TEST mode
            #
            if [ "${lTestRun}" == "NO" ] ; then
              if [ "${lSshUsable}" == "YES" ] ; then
                lRemoveList=$( echo "${lRemoveList}" | sed 's/^/rm -f /g' )
                lRmResult=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no ${lInstance}@localhost "${lRemoveList}" 2>&1 )
              else
                lRmResult=$( rm -f ${lRemoveList} 2>&1 )
              fi
              if [ $( echo "${lRmResult}" | grep -i permission | wc -l ) -gt 0 ] ; then
                echo "${lRmResult}" | sed 's/^/\t  - /g' >> ${lLogOutput}
                gMessage="Files (some?) could not get removed"
                [[ "${lVerbose}" == "YES" ]] && showError
              fi
            fi

          else
            echo "  No files found to remove" | sed 's/^/\t/g' >> ${lLogOutput}
          fi
          echo "" >> ${lLogOutput}

          echo "---
Removing empty LOG directories for database ${lDatabase}" \
            | sed 's/^/\t/g' >> ${lLogOutput}
          lDirectoryList_cmd="   find ${lLogDirectory} \
                                   -type d \
                                   -name 'C[0-9][0-9]*' \
                                   -print \
                               | grep -v '^$' \
                               | sort"
          if [ "${lSshUsable}" == "YES" ] ; then
            lDirectoryList=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no \
                                ${lInstance}@localhost "${lDirectoryList_cmd}" )
          else
            lDirectoryList=$( eval "${lDirectoryList_cmd}" )
          fi

          lRemoveList=""
          for lDirectoryToCheck in ${lDirectoryList}
          do
            lNumberOfFiles_cmd=" cd ${lLogDirectory} ; \
                                 find ${lDirectoryToCheck} -type f -name '*.LOG' \
                               | grep -v '^$' \
                               | wc -l"
            if [ "${lSshUsable}" == "YES" ] ; then
              lNumberOfFiles=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no \
                                  ${lInstance}@localhost "${lNumberOfFiles_cmd}" )
            else
              lNumberOfFiles=$( eval "${lNumberOfFiles_cmd}" )
            fi

            if [ ${lNumberOfFiles} -eq 0 ] ; then
              lRemoveList=$( printf "%s\n%s" "${lRemoveList}" "${lDirectoryToCheck}" )
            fi
          done
          lRemoveList_cmd="   echo '${lRemoveList}' \
                            | sed 's/^[ ]*//g; s/[ ]*$//g' \
                            | grep -v '^$'"
          if [ "${lSshUsable}" == "YES" ] ; then
            lRemoveList=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no \
                                ${lInstance}@localhost "${lRemoveList_cmd}" )
          else
            lRemoveList=$( eval "${lRemoveList_cmd}" )
          fi
          if [ "${lRemoveList}" != "" ] ; then
            if [ "${lTestRun}" == "NO" ] ; then
              echo " Directories to remove:" | sed 's/^/\n\t/g' >> ${lLogOutput}
            else
              echo " Directories indicated to remove:" | sed 's/^/\n\t/g' >> ${lLogOutput}
            fi
            echo "${lRemoveList}" | sed 's/^/\t  - /g' >> ${lLogOutput}
            #
            # Only remove directories when not running in TEST mode
            #
            if [ "${lTestRun}" == "NO" ] ; then
              if [ "${lSshUsable}" == "YES" ] ; then
                lRemoveList=$( echo "${lRemoveList}" | sed 's/^/rmdir --ignore-fail-on-non-empty /g' )
                lRmResult=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no ${lInstance}@localhost "${lRemoveList}" 2>&1 )
              else
                lRmResult=$( rmdir --ignore-fail-on-non-empty ${lRemoveList} 2>&1 )
              fi
              if [ $( echo "${lRmResult}" | grep -i permission | wc -l ) -gt 0 ] ; then
                echo "${lRmResult}" | sed 's/^/\t  - /g' >> ${lLogOutput}
                gMessage="Directories (some?) could not get removed"
                [[ "${lVerbose}" == "YES" ]] && showError
              fi
            fi
          else
            echo "  No directories found to remove" | sed 's/^/\t/g' >> ${lLogOutput}
          fi
          echo "" >> ${lLogOutput}
        fi
      fi
    fi

    set +x
    return ${lReturnCode}
  }

  function determineLoggingMethod {

    typeset -l lInstance="${1}"
    typeset -u lDatabase="${2}"

    lLogMethod="ARCHIVE"
    lLogMethodDbCfg=$(   db2 GET DB CFG FOR ${lDatabase} \
                       | grep 'LOGARCHMETH' \
                       | grep -v ' OFF$' \
                       | sed 's/^.*\(= \)\(.*$\)/\2/g; s/DISK://g; s/[\/]*$//'
                     )
    [[ "${lLogMethodDbCfg}" == "" ]] && lLogMethod="CIRCULAR"
    [[ "${lLogMethodDbCfg}" == "LOGRETAIN" ]] && lLogMethod="LOGRETAIN"

    set +x
    return 0
  }


  function assembleBackupCommand {

    typeset -l lInstance="${1}"
    typeset -u lDatabase="${2}"
    typeset -u lIncludeLogs="${3}"
    typeset -u lForce="${4}"
    typeset    lLogOutput="${5}"
    typeset -u lBackupType="${6}"
    typeset -u lLogMethod="${7}"
    typeset -i lCurrentRun=${8}

    typeset -u lUsedBackupType="${lBackupType}"
    typeset    lBackupCmdPrefix=""

    gDatabase="${lDatabase}"
    lBackupCmd=""

    fetchAllDb2ActiveDatabases
    getCurrentDbActivationState
    fetchAllDb2Applications
    handleDb2DbDisconnect

    case ${lLogMethod} in
      ARCHIVE|LOGRETAIN)
        # Default behaviour: ONLINE
        lUsedBackupType="ONLINE"
        # If the database is not active (and thus no applications are connected),
        #   then an OFFLINE backup is easier for restore purposes
        [[ "${gDb2ActivationStatus}" == "INACTIVE" ]] && lUsedBackupType="OFFLINE"

        # Is the chosen method in line with what was asked?
        if [ "${lBackupType}" != "${lUsedBackupType}" ] ; then
          # An OFFLINE backup is asked, an attempt to make an OFFLINE backup is made
          [[ "${lBackupType}" == "OFFLINE" ]] && lUsedBackupType="${lBackupType}"
        fi
        ;;

      # CIRCULAR
      *)
        lUsedBackupType="OFFLINE"
    esac

    # An OFFLINE backup is wished for. Are we ready for that?
    if [ "${lBackupType}" == "OFFLINE" -a "${lForce}" == "NO" ] ; then
      if [ "${gDb2ActivationStatus}" != "INACTIVE" ] ; then
        gMessage="Database is active, but an OFFLINE backup is demanded. The option 'FORCE' should be used!"
        showInfo
        echo "${gMessage}" | sed 's/^/\t/g' >> ${lLogOutput}
      fi
    fi

      # Let the world know what will be done
    if [ "${lVerbose}"    == "YES" -a \
         "${lBackupType}" != "${lUsedBackupType}" ] ; then
      if [ "${lBackupType}" != "" ] ; then
        gMessage="Choosing backup methodology '${lUsedBackupType}'"
      else
        gMessage="Altered backup methodology from '${lBackupType}' to '${lUsedBackupType}'"
      fi
      showInfo
      echo "${gMessage}" | sed 's/^/\t/g' >> ${lLogOutput}
    fi

      # Compose the backup command
    lBackupCmd="db2 -v BACKUP DB ${lDatabase}"
    [[ "${lUsedBackupType}" == "ONLINE" ]] && lBackupCmd="${lBackupCmd} ONLINE"
    lBackupCmd="${lBackupCmd}
      TO ${lBackupDir}
      COMPRESS"
    if [ "${lIncludeLogs}" == "YES" -a "${lUsedBackupType}" == "ONLINE" ] ; then
      lBackupCmd="${lBackupCmd}
      INCLUDE LOGS"
    fi
    lBackupCmd="${lBackupCmd}
      WITHOUT PROMPTING ;
lBackupReturnCode=\$? ;
return \${lBackupReturnCode} ;"

    if [ "${lUsedBackupType}" == "OFFLINE" ] ; then
      if [ $( echo "${gDb2ActiveDatabaseList}" | grep "^${lDatabase}$" | wc -l ) -ne 0 -a \
           "${gDb2ActivationStatus}" == "EXPLICIT" ] ; then
        lBackupCmd="db2 -v DEACTIVATE DATABASE ${lDatabase} >>#LOG# 2>&1 ;
${lBackupCmd}"
      fi
      if [ "${gDb2ListApplications}" != "" -a "${lForce}" == "YES" ] ; then
        lUnquiesceNeeded="YES"
        lForceConnections="YES"

        lBackupCmdPrefix="db2 -v TERMINATE >>#LOG# 2>&1 ;
db2 -v CONNECT TO ${lDatabase} >>#LOG# 2>&1 ;"
        if [ ${lCurrentRun} -gt 1 ] ; then
         lBackupCmdPrefix="${lBackupCmdPrefix}
db2 -v UNQUIESCE DATABASE >>#LOG# 2>&1 ;"
        fi
         lBackupCmd="${lBackupCmdPrefix}
db2 -v QUIESCE DATABASE IMMEDIATE FORCE CONNECTIONS >>#LOG# 2>&1 ;
db2 -v CONNECT RESET >>#LOG# 2>&1 ;
db2 -v TERMINATE >>#LOG# 2>&1 ;
${lBackupCmd}"
      else
        lBackupCmd="db2 -v TERMINATE >>#LOG# 2>&1 ;
${lBackupCmd}"
      fi
    else
      lBackupCmd="db2 -v TERMINATE >>#LOG# 2>&1 ;
${lBackupCmd}"
    fi

    if [ "${lUsedBackupType}"      == "OFFLINE" -a \
         "${gDb2ActivationStatus}" == "EXPLICIT" ] ; then
      lBackupCmd="${lBackupCmd}
# -- After care
db2 -v ACTIVATE DATABASE ${lDatabase} >>#LOG# 2>&1 ;"
    fi
    if [ "${lUnquiesceNeeded}" == "YES" ] ; then
      if [ "${lUsedBackupType}"      != "OFFLINE" -o \
           "${gDb2ActivationStatus}" != "EXPLICIT" ] ; then
        lBackupCmd="${lBackupCmd}
# -- After care"
      fi
      lBackupCmd="${lBackupCmd}
db2 -v CONNECT TO ${lDatabase} >>#LOG# 2>&1 ;
db2 -v UNQUIESCE DATABASE >>#LOG# 2>&1 ;
db2 -v CONNECT RESET >>#LOG# 2>&1 ;"
    fi

    lBackupCmd=$(   echo "${lBackupCmd}" \
                  | grep -v '^[ ;]*$'
		)
    set +x
    return 0

  }

  function forceRemainingConnections {

    typeset -l lInstance="${1}"
    typeset -u lDatabase="${2}"
    typeset    lLogOutput="${3}"
    typeset -i lCurrentRun=${4}

    typeset    lGetApplicationList="  db2 list applications for database ${lDatabase} show detail \
                                    | sed 's/ [a-zA-Z0-9\/\[*]/;&/g; s/ //g' \
                                    | grep -i ';${lDatabase};' \
                                    | cut -d ';' -f 3"

    if [ "${lVerbose}" == "YES" ] ; then
      gMessage="Checking whether applications need to get forced off from ${lDatabase}"
      showInfo
      echo "${gMessage}" | sed 's/^/\t/g' >> ${lLogOutput}
    fi
    if [ "${lTestRun}" == "NO" ] ; then
      for lApplHandle in $( eval ${lGetApplicationList} )
      do
        if [ "${lApplHandle}" != "" ] ; then
          db2 -v "FORCE APPLICATION (${lApplHandle})" 2>&1 | sed 's/^/\t/g' >> ${lLogOutput}
        else
          break 1
        fi
      done
      [[ "${lVerbose}" == "YES" ]] && echo "" >> ${lLogOutput}
    else
      echo "Intended forcing off applications from ${lDatabase}." | sed 's/^/\t/g; s/$/\n/g' >> ${lLogOutput}
    fi

    set +x
    return 0

  }

  function performBackup {

    typeset    lHostName="${1}"
    typeset -l lInstance="${2}"
    typeset -u lDatabase="${3}"
    typeset -u lBackupType="${4}"
    typeset -u lForce="${5}"
    typeset -u lSshUsable="${6}"

    typeset    lLogOutput="${lLogOutputDir}/${lTimestampToday}_${lDatabase}.log"

    typeset    lBackupReturnText=""
    typeset -i lBackupReturnCode=0
    typeset -i lCurrentRun=1
    typeset -i lSleepTime=20

    typeset    lActivateStmt=""
    typeset    lActivateReturnText=""
    typeset    lUnquiesceStmt=""
    typeset    lUnquiesceReturnText=""

    typeset    lUtilityReturnText=""

    gErrorNo=0

    #
    # Make it very obvious when handling a TEST run
    #
    if [ "${lTestRun}" == "YES" ] ; then
      lLogOutput="${lLogOutputDir}/${lTimestampToday}_TEST_${lDatabase}.log"
    fi

    #
    # Gather information before proceeding taking a backup
    #
    determineRetentionPeriod "${lHostName}" "${lInstance}" "${lDatabase}"
    determineLoggingMethod   "${lInstance}" "${lDatabase}"
    getCurrentDbActivationState

    #
    # Write the observations to the log file
    #
    printfRepeatChar "-" 80 >> ${lLogOutput}
    echo "${lTimestampToday} ${cBaseNameScript} ${lCmdPars}" >> ${lLogOutput}
    printfRepeatChar "-" 80 >> ${lLogOutput}
    lUtilityReturnText=$(   db2pd -utilities \
                          | grep " ${lDatabase} " \
                          | awk -F' ' '{print $3" since "$7" "$8" "$9" "$10 }' \
                          | grep -v '^$'
                        )
    [[ "${lUtilityReturnText}" == "" ]] && lUtilityReturnText="none running"

    echo "
Database     : ${lDatabase}
Date/Time    : $( date "+%Y-%m-%d-%H.%M.%S" )
BackupType   : ${lBackupType}
LogMethod    : ${lLogMethod}
Activation   : ${gDb2ActivationStatus}
Retention    : ${lBackupRetentionPeriod}
Retention Db2: ${lBackupRetentionPeriodDb2}
Forcing      : ${lForce} (When NO, no retry is done!)
Ssh usable   : ${lSshUsable}
#LOG#        : ${lLogOutput}
Utilities    : ${lUtilityReturnText}
---" | sed 's/^/\t/g' >> ${lLogOutput}

    #
    # When other utilities are currently running, do consider whether to continue
    #
    if [ "${lUtilityReturnText}" != "none running" ] ; then
      lUtilityReturnText=$(   echo "${lUtilityReturnText}" \
                            | cut -d ' ' -f 1 \
                            | tr '[a-z]' '[A-Z]' )
      if [ "${lUtilityReturnText}" == "BACKUP" -o \
           "${lUtilityReturnText}" == "RESTORE" ] ; then
        gErrorNo=11
        gMessage="A ${lUtilityReturnText} is still running against the database"
      elif [ "${lBackupType}" == "OFFLINE" ] ; then
        gErrorNo=12
        gMessage="A ${lUtilityReturnText} is running during an OFFLINE backup"
      fi
      if [ gErrorNo -ne 0 ] ; then
        showError | sed 's/^/\t/g' >> ${lLogOutput}
        scriptUsage "Yes"
      fi
    fi

    #
    # Did an obvious error occur? Then stop here!
    #
    [[ ${gErrorNo} -ne 0 ]] && set +x && return ${gErrorNo}

    #
    # Check if the backup as requested is even possible
    #
    if [ "${lBackupType}" == "ONLINE" -a "${lForce}" == "NO" ] ; then
      if [ "${gDb2ActivationStatus}" != "EXPLICIT" ] ; then
        fetchAllDb2Applications
        if [ "${gDb2ActiveDatabaseList}" == "" ] ; then
          gMessage="The database ${lDatabase} isn't activated"
          showWarning
        fi
      fi
    elif [ "${lBackupType}" == "OFFLINE" -a "${lForce}" == "NO" ] ; then
      fetchAllDb2ActiveDatabases
      fetchAllDb2Applications
      if [ $( echo "${gDb2ActiveDatabaseList}" | grep "^${lDatabase}$" | wc -l ) -ne 0 -o \
           "${gDb2ListApplications}" != "" ] ; then
        gErrorNo=10
        gMessage="An OFFLINE backup on the active database ${lDatabase} is not possible when not FORCED"
        showError | sed 's/^/\t/g' >> ${lLogOutput}
        scriptUsage "No"
      fi
    fi

    #
    # Did an obvious error occur? Then stop here!
    #
    [[ ${gErrorNo} -ne 0 ]] && set +x && return ${gErrorNo}

    #
    # Ready to rumble!
    #
    if [ "${lVerbose}" == "YES" ] ; then
      echo "---
Database     : ${lDatabase}
Timestamp    : ${lTimestampToday}
Date/Time    : $( date "+%Y-%m-%d-%H.%M.%S" )
BackupType   : ${lBackupType}
LogMethod    : ${lLogMethod}
Activation   : ${gDb2ActivationStatus}
Retention    : ${lBackupRetentionPeriod}
Retention Db2: ${lBackupRetentionPeriodDb2}
Forcing      : ${lForce} (When NO, no retry is done!)
Ssh usable   : ${lSshUsable}
Output       : ${lLogOutput}
Utilities    : ${lUtilityReturnText}
---"
    fi
    preserveRetentionPeriod  "${lInstance}" "${lDatabase}" "${lLogOutput}"

    while [ ${lCurrentRun} -le ${cNumberOfTries} ] ; do
      if [ ${cNumberOfTries} -gt 1 ] ; then
        gMessage="Run #${lCurrentRun}/${cNumberOfTries}: ${lBackupType} (FORCED: ${lForce}) backup of ${lDatabase}"
        showInfo
      fi
      if [ ${lCurrentRun} -ne 1 ] ; then
        echo " ***" >> ${lLogOutput}
      fi
      assembleBackupCommand "${lInstance}"    "${lDatabase}"  \
                            "${lIncludeLogs}"                 \
                            "${lForce}"       "${lLogOutput}" \
                            "${lBackupType}"  "${lLogMethod}" \
                            "${lCurrentRun}"
      if [ "${lBackupCmd}" != "" ] ; then
        if [ "${lVerbose}" == "YES" ] ; then
          echo "
Command sequence - run ${lCurrentRun}/${cNumberOfTries} at $( date "+%Y-%m-%d-%H.%M.%S" ):

${lBackupCmd}
---" | grep -v 'ReturnCode' | sed 's/^/\t/g' >> ${lLogOutput}
        fi

        #
        # * The shell gets closed right after the BACKUP command, so
        #     when an ACTIVATE is needed, force it
        # * If the database is QUIESCED, it always needs to be
        #     UNQUIESCED afterwards, no matter the outcome
        # * Replace the placeholder #LOG# by the value of the variable
        #     ${lLogOutput}
        if [ "${lActivateStmt}" == "" ] ; then
          lActivateStmt=$(   echo "${lBackupCmd}" \
                           | awk '/# \-\- After care/,/^$/' \
                           | awk '/ ACTIVATE /,/^$/' \
                           | grep -v '^$' \
                           | sed "s:#LOG#:${lLogOutput}:g" )
        fi
        if [ "${lUnquiesceStmt}" == "" -a "${lUnquiesceNeeded}" == "YES" ] ; then
            # Isolate the UNQUIESCE command (+ CONNECT + CONNECT RESET)
          lUnquiesceStmt=$(   echo "${lBackupCmd}" \
                            | awk '/# \-\- After care/,/^$/' \
                            | grep -B1 -A1 ' UNQUIESCE ' \
                            | grep -v '^$' \
                            | sed "s:#LOG#:${lLogOutput}:g" )
        fi
        if [ "${lUnquiesceNeeded}" == "YES" ] ; then
          if [ $( echo "${lActivateStmt}" | grep ' UNQUIESCE ' | wc -l ) -gt 0 ] ; then
              # Remove the UNQUIESCE command (+ CONNECT + CONNECT RESET)
            lActivateStmt=$(   echo "${lActivateStmt}" \
                             | sed "$( echo "${lActivateStmt}" \
                                       | grep -n -B1 -A1 ' UNQUIESCE ' \
                                       | sed -n 's/^\([0-9]\{1,\}\).*/\1d/p' )" )
          fi
          if [ $( echo "${lBackupCmd}" | grep ' UNQUIESCE ' | wc -l ) -gt 0 ] ; then
              # Remove the UNQUIESCE command (+ CONNECT + CONNECT RESET)
            lBackupCmd=$(   echo "${lBackupCmd}" \
                          | sed "$( echo "${lBackupCmd}" \
                                    | grep -n '^' \
                                    | awk '/# \-\- After care/,/^$/' \
                                    | grep -B1 -A1 ' UNQUIESCE ' \
                                    | sed -n 's/^\([0-9]\{1,\}\).*/\1d/p' )" )
          fi
        fi
        lBackupCmd=$(   echo "${lBackupCmd}" \
                      | awk '1;/# \-\- After care/{exit}' \
                      | egrep -v '^$|# \-\- After care' \
                      | sed "s:#LOG#:${lLogOutput}:g" )
        lBackupReturnCode=0
        #
        # Only make a backup when not running in "TEST" mode
        #
        if [ "${lTestRun}" == "NO" ] ; then
          if [ "${lForceConnections}" == "YES" ] ; then
            forceRemainingConnections "${lInstance}" "${lDatabase}" "${lLogOutput}" "${lCurrentRun}"
          fi
          lBackupReturnText=$( eval ${lBackupCmd} 2>&1 )
          lBackupReturnCode=$?
        else
          lBackupReturnText="Running in TEST mode. No actual backup is taken!"
        fi
        echo "${lBackupReturnText}" | sed 's/^/\t/g; s/$/\n/g' >> ${lLogOutput}
        if [ "${lTestRun}" == "YES" ] ; then
          echo "${lBackupCmd}" | sed 's/^/\t\t/g' >> ${lLogOutput}
        fi

        lSleepTime=0
        if [ ${lCurrentRun} -lt 8 ] ; then
          lSleepTime=$(( cSleepBetweenTries / lCurrentRun ))
        elif [ ${lCurrentRun} -eq 8 ] ; then
          lSleepTime=1
        fi

        if [ "${lVerbose}" == "YES" ] ; then
          gMessage="Run #${lCurrentRun}/${cNumberOfTries}: * Result=${lBackupReturnCode}"
          showInfo
          gErrorNo=0
          gMessage=$(   echo "${lBackupReturnText}" \
                      | grep -v '^$' \
                      | sed '/SQL[0-9][0-9]/! s/^/\t/g; s/^/\t/g'
                    )
          [[ ${lBackupReturnCode} -ne 0 ]] && showError || showMessage
          echo ""

          if [ ${lBackupReturnCode} -ne 0 -a "${lForce}" == "YES" ] ; then
            if [ ${lSleepTime} -gt 0 ] ; then
              gMessage="\t\tWaiting ${lSleepTime} second(s) before trying again\n"
            else
              gMessage="\t\tDone waiting. Trying again\n"
            fi
            [[ ${lCurrentRun} -lt ${cNumberOfTries} ]] && showInfo || lSleepTime=0
          fi
        fi
        [[ ${lBackupReturnCode} -eq 0 ]] && break 1

        if [ "${lVerbose}" == "YES" -a ${lCurrentRun} -eq ${cNumberOfTries} ] ; then
          db2 -v "LIST APPLICATIONS FOR DATABASE ${lDatabase} SHOW DETAIL" 2>&1 | sed 's/^/\t/g' >> ${lLogOutput}.snapshot
          printfRepeatChar "=" 80 >> ${lLogOutput}.snapshot
          echo "" >> ${lLogOutput}.snapshot
          db2 -v "GET SNAPSHOT FOR APPLICATIONS ON ${lDatabase}" >> ${lLogOutput}.snapshot
        fi

        [[ "${lForce}" == "YES" && ${lSleepTime} -gt 0 ]] && sleep ${lSleepTime}
      fi
      lCurrentRun=$(( lCurrentRun + 1 ))
    done

    #
    # Backup part is over, check whether we need to activate and/or unquiesce
    #   the database again
    #
    if [ "${lActivateStmt}" != "" -a "${lTestRun}" == "NO" ] ; then
      lActivateReturnText=$( eval ${lActivateStmt} 2>&1 )
      echo "${lActivateStmt}" | sed 's/^/\t/g' >> ${lLogOutput}
      echo "${lActivateReturnText}" | sed 's/^/\t/g' >> ${lLogOutput}
    elif [ "${lActivateStmt}" != "" -a "${lTestRun}" == "YES" ] ; then
      echo "* Intended to re-activate the database" | sed 's/^/\t/g' >> ${lLogOutput}
      echo "${lActivateStmt}" | sed 's/^/\t\t/g' >> ${lLogOutput}
    fi
    if [ "${lUnquiesceStmt}" != "" -a "${lTestRun}" == "NO" ] ; then
      lUnquiesceReturnText=$( eval ${lUnquiesceStmt} 2>&1 )
      echo "${lUnquiesceStmt}" | sed 's/^/\t/g' >> ${lLogOutput}
      echo "${lUnquiesceReturnText}" | sed 's/^/\t/g' >> ${lLogOutput}
    elif [ "${lUnquiesceStmt}" != "" -a "${lTestRun}" == "YES" ] ; then
      echo "Intended to unquiesce the database" | sed 's/^/\t/g' >> ${lLogOutput}
      echo "${lUnquiesceStmt}" | sed 's/^/\t\t/g' >> ${lLogOutput}
    fi

    #
    # Apply the retention period
    #
    applyRetentionPeriod "${lInstance}"  "${lDatabase}"  "${lBackupRetentionPeriod}" \
                         "${lSshUsable}" "${lBackupDir}" "${lLogOutput}"
    #
    # Do communicate with the outside world if needed
    #
    if [ ${lBackupReturnCode} -ne 0 -a "${lMailTo}" != "" ] ; then
      sendMail "${lInstance}" "${lDbToHandle}" "${lBackupReturnCode}" "${lLogOutput}"
    fi

    set +x
    return ${lBackupReturnCode}
  }

#
# Primary initialization of commonly used variables
#
typeset    lCmdPars=$@
typeset    lTimestampToday=$( date "+%Y-%m-%d-%H.%M.%S" )
typeset    lDb2Profile=""
typeset    lDb2ProfileHome=""
typeset -l lInstance=""
typeset -u lDatabase=""
typeset    lExcludedDatabase="^$"
typeset    lAlias=""
typeset    lJobName=""
typeset    lMailTo=""
typeset    lMailCc=""
typeset -u lVerbose="YES"
typeset -u lTestRun="NO"
typeset -u lIncludeLogs="NO"
typeset -u lForce="NO"
typeset -u lForceConnections="NO"
typeset -u lSshUsable="NO"
typeset    lSshResult=""
typeset -i lReturnCode=0
typeset -i lOverallBackupReturnCode=0

typeset    lBackupCmd=""
typeset -u lLogMethod=""
typeset    lLogMethodDbCfg=""

typeset -u lBackupType=""
typeset -i lBackupRetentionPeriod=0        # Retention period enforced by the script
typeset -i lBackupRetentionPeriodDb2=0     # Safety net: retention period enforced by Db2
typeset -u lUnquiesceNeeded

#
# Loading libraries
#
[[ ! -f ${cScriptDir}/common_functions.include ]] && gErrorNo=2 && gMessage="Cannot load ${cScriptDir}/common_functions.include" && scriptUsage
. ${cScriptDir}/common_functions.include

[[ ! -f ${cScriptDir}/db2_common_functions.include ]] && gErrorNo=2 && gMessage="Cannot load ${cScriptDir}/db2_common_functions.include" && scriptUsage
. ${cScriptDir}/db2_common_functions.include

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
    [[ "${_lCmdOption}" == "" && "${lCmdValue}" == "" ]] && _lCmdOption="--"

    case ${_lCmdOption} in
      -I | --instance )
        lInstance="${_lCmdValue}"
        shift 2
        ;;
      -D | --database )
        lDatabase="${_lCmdValue}"
        shift 2
        ;;
      -x | --exclude )
        lExcludedDatabase="${_lCmdValue}"
        shift 2
        ;;
      -T | --backuptype )
        lBackupType="${_lCmdValue}"
        shift 2
        ;;
      -i | --includelogs )
        lIncludeLogs="YES"
        shift 1
        ;;
      -f | --force )
        lForce="YES"
        shift 1
        ;;
      -a | --alias )
        lAlias="${_lCmdValue}"
        shift 2
        ;;
      -j | --job )
        lJobName="${_lCmdValue}"
        shift 2
        ;;
      -m | --mailto )
        lMailTo="${_lCmdValue}"
        shift 2
        ;;
      -c | --mailcc )
        lMailCc="${_lCmdValue}"
        shift 2
        ;;
      -t | --test )
        lTestRun="YES"
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
[[ "${lInstance}" == "" ]] && gErrorNo=1 && gMessage="Please provide an instance to do the work for" && scriptUsage
  # Valid backup types: ONLINE|OFFLINE|none chosen
[[ $( echo "${lBackupType}" | egrep '^ONLINE$|^OFFLINE$|^$' | wc -l ) -eq 0 ]] && gErrorNo=1 && gMessage="Please provide a valid backup type" && scriptUsage

[[ "${lTestRun}"     != "YES" ]] && lTestRun="NO"
[[ "${lVerbose}"     != "NO"  ]] && lVerbose="YES"
[[ "${lIncludeLogs}" != "YES" ]] && lIncludeLogs="NO"
[[ "${lForce}"       != "YES" ]] && lForce="NO" && cNumberOfTries=1

#
# Load Db2 library
#
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
# Set umask
#
umask ${cMasking}

#
# Make sure logging can be done properly as well dumping the backup image
#
typeset lBackupDir="${cBackupDir}_${cHostName}/${lInstance}"
typeset lLogOutputDir="${cLogsDirBase}/${cHostName}/${lInstance}"
typeset lDatabaseList=""
typeset lDbActivationState=""

mkdir -p ${lBackupDir} >/dev/null 2>&1
chgrp -R db2admx ${lBackupDir} >/dev/null 2>&1
touch ${lBackupDir}/.test >/dev/null 2>&1
lReturnCode=$?
rm -f ${lBackupDir}/.test >/dev/null 2>&1
[[ ${lReturnCode} -ne 0 ]] && gErrorNo=4 && gMessage="Cannot create the directory to hold the backup(s)" && scriptUsage

mkdir -p ${lLogOutputDir} >/dev/null 2>&1
chgrp -R db2admx ${lLogOutputDir} >/dev/null 2>&1
touch ${lLogOutputDir}/. >/dev/null 2>&1
lReturnCode=$?
[[ ${lReturnCode} -ne 0 ]] && gErrorNo=4 && gMessage="Cannot create the directory to hold the log file(s)" && scriptUsage

#
# Validate the input data
#
if [ "${lDatabase}" != "" ] ; then
  gDatabase="${lDatabase}"
  isDb2DbLocal
  lReturnCode=$?
  if [ ${lReturnCode} -ne 0 ] ; then
    gErrorNo=5
    gMessage="The database ${lDatabase} isn't defined local within instance ${lInstance}"
    scriptUsage
  fi
  lDatabaseList=${lDatabase}
  lExcludedDatabase="^$"
else
  fetchAllDb2Databases
  lDatabaseList=$(   echo "${gDb2DatabaseList}" \
                   | egrep -v "${lExcludedDatabase}" )
fi
if [ "${lMailTo}" == "" -a "${lMailCc}" != "" ] ; then
  lMailTo="${lMailCc}"
  lMailCc=""
fi
[[ "${lMailTo}" == "${lMailCc}" ]] && lMailCc=""

if [ "${USER}" != "${lInstance}" ] ; then
  lSshResult=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no ${lInstance}@localhost 'ls -l ~/.ssh/* 2>&1 | grep -i permission' | grep -v '^$' )
  [[ "${lSshResult}" == "" ]] && lSshUsable="YES"
  [[ "${lSshUsable}" != "YES" ]] && lSshUsable="NO"
else
  lSshUsable="NO"
fi

#
# Main - Get to work
#
for lDbToHandle in ${lDatabaseList}
do
    # Preserve activation state
  gDatabase="${lDbToHandle}"
  getCurrentDbActivationState
  lDbActivationState="${gDb2ActivationStatus}"

  typeset    lLogOutput="${lLogOutputDir}/${lTimestampToday}_${lDatabase}.log"

    # Set unquiesce parameter to its default value
  lUnquiesceNeeded="NO"
    # Perform the backup
  performBackup "${cHostName}" "${lInstance}" "${lDbToHandle}" "${lBackupType}" "${lForce}" "${lSshUsable}"
  lReturnCode=$?
  lOverallBackupReturnCode=$(( lOverallBackupReturnCode + lReturnCode ))

    # If the activation state was 'EXPLICIT', but the database isn't 'EXPLICIT'
    #   activated anymore, then activate it once again
  gDatabase="${lDbToHandle}"
  getCurrentDbActivationState
  if [ "${lDbActivationState}"   == "EXPLICIT" -a  \
       "${gDb2ActivationStatus}" != "EXPLICIT" ] ; then
    db2 -v ACTIVATE DB ${gDatabase} 2>&1 | sed 's/^/\t/g' >>${lLogOutput} 2>&1
  fi
done

#
# Finish up
#
if [ "${lVerbose}" == "YES" ] ; then
  printfRepeatChar "=" 80
  echo "Overall backup return code: ${lOverallBackupReturnCode}"
  printfRepeatChar "=" 80
fi

set +x
[[ ${lOverallBackupReturnCode} -gt 0 ]] && exit 8
exit 0
