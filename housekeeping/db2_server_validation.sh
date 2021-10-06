#!/bin/bash
#
# Author     : Eddy Coppens [The Mindbridge]
# Script     : db2_server_validation.sh
# Description: Check whether all conditions are met to have a correctly
#                installed and running Virtual Machine.
# Dependencies:
#   * common_functions.ksh
#   * db2_server_validation.cfg
#   * technical.txt - list of technical users allowed to be in /etc/passwd
#
#<header>
#
# Remarks   : Parameters:
#   * Optional
#       -i | --instance   : Perform instance related checks
#       -d | --database   : Perform database related checks
#       -m | --mergeReport: Do not display a separate report header
#       -q | --quiet      : Quiet - show no messages
#       -h | -H | --help  : Help
#
#</header>

#
# Constants
#
typeset    cCmdSwitchesShort="i:d:r:mqhH"
typeset -l cCmdSwitchesLong="instance:,database:,_reportname:,mergereport,quiet,help"
typeset    cHostName=$( hostname | cut -d '.' -f 1 )
typeset    cScriptName="${0}"
typeset    cBaseNameScript=$( basename ${cScriptName} )
typeset    cScriptDir="${cScriptName%/*}"
typeset    cCurrentDir=$( pwd )
typeset    cLogsDirBase="/db2exports/db2scripts/logs/${cBaseNameScript%.*}/${cHostName}"
typeset    cMasking="0002"
typeset    cSshOptions="-o BatchMode=yes -o StrictHostKeychecking=no"

#typeset    cTmpFile=$( mktemp /var/tmp/$$_db2_server_validation.XXXXXX )

[[ "${cScriptDir}" == "." ]] && cScriptDir="${cCurrentDir}"

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

  function displayMessage {
    typeset lTestStatus="${1}"
    typeset lMsg="${2}"

    typeset lMsgColor=${gTTY_WHITE}

    printf "${lMsgColor}["
    if [ "${lTestStatus}" == "NOK" -o "${lTestStatus}" == "NO " ] ; then
      printf "${gTTY_RED}"
    else
      printf "${gTTY_GREEN}"
    fi
    lMsg=$( echo "${lMsg}" | sed -e "s/\[${lTestStatus}\]//g" -e 's/^[ ]*//g' )
    printf "${lTestStatus}${lMsgColor}] - ${lMsg}${gTTY_NEUTRAL}\n"

    if [ "${lLogOutput}" != "" ] ; then
      if [ -f ${lLogOutput} ] ; then
        echo "[${lTestStatus}] - ${lMsg}" >> ${lLogOutput}
      fi
    fi
    set +x
    return 0
  }

  function checkLocalUsers {
    typeset suspiciousUsers=$(  sort -b -t: -n -k3 /etc/passwd \
                              | awk -F':' '{if ((($3 > 1000 && $3 < 1200) || $3 >= 5000) && $3 < 65534) { print } }' \
                              | egrep -v 'ambikas:|mindbridge:|db2acc:' \
                              | cut -d':' -f1 \
                             )
    typeset lTestStatus="OK "
    if [ $( echo ${suspiciousUsers} | grep -v '^$' | wc -l ) -gt 0 ] ; then
      if [ -f ./technical.txt ] ; then
        for userToCheck in ${suspiciousUsers}
        do
          if [ $( grep "^${userToCheck}$" ./technical.txt | wc -l ) -gt 0 ] ; then
            suspiciousUsers=$( echo ${suspiciousUsers} | grep -v "^${userToCheck}$" )
          fi
        done
      fi
      if [ $( echo ${suspiciousUsers} | grep -v '^$' | wc -l ) -gt 0 ] ; then
        lTestStatus="NOK"
        suspiciousUsers=$(  echo ${suspiciousUsers} | sed 's/ /, /g' )
        suspiciousUsers=": ${suspiciousUsers}"
      fi
    fi
    displayMessage "${lTestStatus}" "Search for suspicious (local) users${suspiciousUsers}"
    set +x
    return 0

  }

  function checkDb2DirPermissions {
    typeset lDb2CommonGroupId=$( getent group ${DB2COMMONGROUP} | cut -d ':' -f3 )
    typeset lTestStatus="OK "
    typeset lPermission

    #
    # Is defined in the config file
    #  * ${DB2COMMONGROUP}
    #  * ${EXCLUDE_DISK}
    #
    if [ "${lDb2CommonGroupId}" == "" ] ; then
      lTestStatus="NOK"
    fi
    displayMessage "${lTestStatus}" "Group ${DB2COMMONGROUP} does exist (Group ID: '${lDb2CommonGroupId}')"

    if [ "${lDb2CommonGroupId}" != "" ] ; then
      for lDb2Directory in $( ls -1 / | grep db2 )
      do
        if [ $( echo "${EXCLUDE_DISK}" | tr ',' '\n' | grep "^/${lDb2Directory}$" | wc -l ) -eq 0 ] ; then
          lTestStatus="OK "
          if [ $( stat -c "%g" /${lDb2Directory} 2>&1 ) -ne ${lDb2CommonGroupId} ] ; then
            lTestStatus="NOK"
          fi
          displayMessage "${lTestStatus}" "/${lDb2Directory}: has ${DB2COMMONGROUP} defined as group"

          lTestStatus="OK "
          lPermission=$( stat -c "%a" /${lDb2Directory} 2>&1 )
          if  [ ${lPermission} -ne  775 ] ; then
            lTestStatus="NOK"
          fi
          displayMessage "${lTestStatus}" "/${lDb2Directory}: has 0775 as a permission"
        fi
      done
    fi

    set +x
    return 0

  }

  function checkSystemConf {
    typeset lTestStatus="OK "
    typeset lValue=""

    if [ -f /etc/systemd/system.conf ] ; then
      lValue=$( grep '^[ ]*DefaultTasksMax=' /etc/systemd/system.conf | cut -d'=' -f2 )
      if [ "${lValue}" != "infinity" ] ; then
        lTestStatus="NOK"
      fi
      displayMessage "${lTestStatus}" "/etc/systemd/system.conf has correct setting: DefaultTasksMax=infinity"
    else
      lTestStatus="NOK"
      displayMessage "${lTestStatus}" "/etc/systemd/system.conf does exist"
    fi

    set +x
    return 0

  }

  function checkSwappiness {
    typeset lTestStatus="OK "
    typeset lValue=""

    # ${SWAPPINESS} is defined in the configuration file

    if [ -f /proc/sys/vm/swappiness ] ; then
      lValue=$( sed -n 1,1p /proc/sys/vm/swappiness | tr -d ' ' )
      lTestStatus="OK "
      if [ "${lValue}" != ${SWAPPINESS} ] ; then
        lTestStatus="NOK"
      fi
      displayMessage "${lTestStatus}" "/proc/sys/vm/swappiness has correct setting: ${SWAPPINESS}"
    else
      lTestStatus="NOK"
      displayMessage "${lTestStatus}" "/proc/sys/vm/swappiness does exist"
    fi

    set +x
    return 0

  }

  function checkFstabAndMount {
    typeset -u lTypeCheck="${1}"

    typeset    lTestStatus="OK "
    typeset    lValue=""
    typeset -i lCounted=0

    case ${lTypeCheck} in
      LOCAL )
        if [ "${LOCAL_DISK}" != "" ] ; then
          for lCurDir in $( echo "${LOCAL_DISK}" | sed 's/ //g' | tr ',' '\n' )
          do
            lTestStatus="OK "
            if [ $(  cat /etc/fstab \
                   | grep -v '^[ ]*#' \
                   | awk -F' ' '{print $2" "$3}' \
                   | grep "^${lCurDir} " \
                   | grep -v ' nfs[4]*$' \
                   | wc -l ) -ne 1 ] ; then
              lTestStatus="NOK"
            fi
            displayMessage "${lTestStatus}" "${lCurDir}: Dedicated local filesystem(s) in /etc/fstab"

            lTestStatus="OK "
            if [ $(  mount \
                   | awk -F' ' '{print $3" "$5}' \
                   | grep "^${lCurDir} " \
                   | grep -v ' nfs[4]*$' \
                   | wc -l ) -ne 1 ] ; then
              lTestStatus="NOK"
            fi
            displayMessage "${lTestStatus}" "${lCurDir}: Dedicated local filesystem(s) seen by mount"
          done
        fi
        ;;
      NFS )
        if [ "${NFS_DISK}" != "" ] ; then
          for lCurDir in $( echo "${NFS_DISK}" | sed 's/ //g' | tr ',' '\n' )
          do
            lTestStatus="OK "
            lCounted=$(  cat /etc/fstab \
                       | grep -v '^[ ]*#' \
                       | awk -F' ' '{print $2" "$3}' \
                       | grep "^${lCurDir} " \
                       | grep ' nfs[4]*$' \
                       | wc -l )
            if [ ${lCounted} -ne 1 ] ; then
              lTestStatus="NOK"
            fi
            displayMessage "${lTestStatus}" "${lCurDir}: Shared NFS filesystem(s) in /etc/fstab (counted: ${lCounted})"

            lTestStatus="OK "
            lCounted=$(  mount \
                       | awk -F' ' '{print $3" "$5}' \
                       | grep "^${lCurDir} " \
                       | grep ' nfs[4]*$' \
                       | wc -l )
            if [ ${lCounted} -ne 1 ] ; then
              lTestStatus="NOK"
            fi
            displayMessage "${lTestStatus}" "${lCurDir}: Shared NFS filesystem(s) seen by mount (counted: ${lCounted})"
          done
        fi
        ;;
    esac

    set +x
    return 0

  }

  function checkDb2Instances {
    typeset    lTestStatus="OK "
    typeset    lValue=""
    typeset -i lNumberOfInstancesCounted=0
    typeset    lSshResult

    fetchAllDb2Instances
    [[ $? -eq 0 ]] && lNumberOfInstancesCounted=$( echo "${gDb2InstancesList}" | grep -v '^$' | wc -l )

    lTestStatus="OK "
    if [ ${lNumberOfInstancesCounted} -lt ${NUMBER_OF_INSTANCES} ] ; then
      lTestStatus="NOK"
    fi
    displayMessage "${lTestStatus}" "Number of instances in config (${NUMBER_OF_INSTANCES}) versus from what is found (${lNumberOfInstancesCounted})"

    for lInstance in ${gDb2InstancesList}
    do
      if [ "${USER}" != "${lInstance}" ] ; then
        lTestStatus="OK "
        lSshResult=$( ssh -o BatchMode=yes -o StrictHostKeychecking=no ${lInstance}@localhost 'ls -l ~/.ssh/*' 2>&1 )
        if [ $( echo "${lSshResult}" | grep -i permission | wc -l ) -gt 0 ] ; then
          lTestStatus="NOK"
        else
          lInstancesToHandle="${lInstancesToHandle} ${lInstance}"
        fi
        displayMessage "${lTestStatus}" "Public key of ${USER} is known to instance ${lInstance}"
      fi
    done

    set +x
    return 0

  }

  function checkDbInstalledVersions {
    typeset    lTestStatus="OK "
    typeset    lValue=""
    typeset -i lBinaryInstalled
    typeset    lBinaryInstallDirectory
    typeset    lSoftwareWishedFor=$( echo ",${INSTALL_DB2_BINARIES}," \
                                   | tr ',' '\n' \
                                   | grep -v '^$' )

    fetchAllDb2Installations
    if [ "${gDb2InstallationList}" == "" ] ; then
      lTestStatus="NOK"
      displayMessage "${lTestStatus}" "No Db2 installation found"
    elif [ "${lSoftwareWishedFor}" == "" ] ; then
      lTestStatus="NOK"
      displayMessage "${lTestStatus}" "No Db2 installation parameter in configuration file"
    else
      for lWantedSoftware in ${lSoftwareWishedFor}
      do
        lTestStatus="OK "
        lBinaryInstallDirectory=""
        lBinaryInstalled=1
        if [ "${gDb2InstallationList}" != "" ] ; then
          lBinaryInstallDirectory=$(   echo "${gDb2InstallationList}" \
                                     | grep "\/${lWantedSoftware}$" )
          lBinaryInstalled=$(   echo "${lBinaryInstallDirectory}" \
                              | wc -l
                            )
        fi
        if [ ! -d ${lBinaryInstallDirectory} -o ${lBinaryInstalled} -eq 0 ] ; then
          lTestStatus="NOK"
        fi
        displayMessage "${lTestStatus}" "Software installed on /opt/ibm versus db2greg and/or configuration file: ${lWantedSoftware}"
      done
    fi

    set +x
    return 0

  }

  function checkDb2Installed {
    typeset    lTestStatus="OK "
    typeset    lValue=""
    typeset    lDb2Level

    lDb2Level=$( db2level 2>&1 )
    if [ $( echo "${lDb2Level}" | grep 'command not found' | wc -l ) -gt 0 ] ; then
      lTestStatus="NOK"
    fi
    displayMessage "${lTestStatus}" "${lInstance}: DB2 installed"
    if [ "${lTestStatus}" == "OK " ] ; then
      #
      # DB2 in use
      #  ${DB2VERSION} is set in the configuration file
      #
      if [ $( echo "${lDb2Level}" | grep "${DB2VERSION}" | wc -l ) -eq 0 ] ; then
        lTestStatus="NOK"
      fi
      displayMessage "${lTestStatus}" "${lInstance}: DB2 version ${DB2VERSION} in use"
    fi

    set +x
    return 0

  }

  function checkDb2License {
    typeset    lTestStatus="OK "
    typeset    lValue=""

    lValue=$( db2licm -l | egrep '^License type:|^Product name:' )
    if [ $( echo "${lValue}" | grep '^License type:' | grep '"Trial"' | wc -l ) -eq 1 ] ; then
      lTestStatus="NOK"
    fi
    lValue=$( echo "${lValue}" \
            | grep '^Product name:' \
            | cut -d ':' -f 2 \
            | sed 's/^[ ]*//g; s/"//g' )
    displayMessage "${lTestStatus}" "${lInstance}: Permanent DB2 license is installed (${lValue})"

    set +x
    return 0

  }

  function checkLocalDefinitionOfUser {
    typeset -l lUser="${1}"

    typeset    lTestStatus="OK "
    typeset    lValue=""
    typeset -i lPosition

    case ${lUser} in
      instance )
        if [ $( grep "^${lInstance}:" /etc/passwd | wc -l ) -ne 1 ] ; then
          lTestStatus="NOK"
        fi
        displayMessage "${lTestStatus}" "${lInstance}: Instance owner/client is defined local in /etc/passwd"

        lTestStatus="OK "
        if [ $( cat /etc/group | grep "^${lInstance}:" | wc -l ) -ne 1 ] ; then
          lTestStatus="NOK"
        fi
        displayMessage "${lTestStatus}" "${lInstance}: Instance owner/client has its group defined local in /etc/group"
        ;;
      fenced_user )
        lPosition=4
        lFencedUser=$( db2pd -fmp 2>&1 | grep '^Fenced User:' | cut -d ':' -f 2 | tr -d ' ' )
        if [ $( grep "^${lFencedUser}:" /etc/passwd | wc -l ) -ne 1 ] ; then
          lTestStatus="NOK"
        fi
        displayMessage "${lTestStatus}" "${lInstance}: Fenced user '${lFencedUser}' is defined local in /etc/passwd"

        lTestStatus="OK "
        if [ $( cat /etc/group | grep "^$( id -n -g ${lFencedUser} ):" | wc -l ) -ne 1 ] ; then
          lTestStatus="NOK"
        fi
        displayMessage "${lTestStatus}" "${lInstance}: Fenced user '${lFencedUser}' has its group defined local in /etc/group"
        ;;
    esac

    set +x
    return 0

  }

  function checkDb2Instance {
    typeset    lTestStatus="OK "
    typeset    lValue=""
    typeset    lInstanceMemInfo
    typeset -i lDatabasesActive

    lInstanceType=$( db2 get dbm cfg \
                   | grep 'Node type' \
                   | awk -F'=' '{print $2}' \
                   | sed -e 's/^[ ]*//g; s/[ ]*$//g' )
    displayMessage "INF" "${lInstance}: Instance type = '${lInstanceType}'"
    lInstanceType=$( echo "${lInstanceType}" | tr -d ' ' )

    if [ "${lInstanceType}" != "Client" ] ; then
      lDbmCfgInfo=$( db2pd -dbmcfg 2>&1 )

        #
        # DB2 instance running
        #
      lTestStatus="OK "
      lInstanceStarted="TRUE"
      if [ $( echo "${lDbmCfgInfo}" | grep '^Unable to attach' | wc -l ) -gt 0 ] ; then
        lTestStatus="NOK"
        lInstanceStarted="FALSE"
        lDbmCfgInfo=$( db2 get dbm cfg 2>&1 )
      fi
      displayMessage "${lTestStatus}" "${lInstance}: Instance started"

        #
        # DB2 - Should instance memory be capped?
        #  Yes, when instance is up and no databases are active
        #
      if [ "${lInstanceStarted}" == "TRUE" ] ; then
        lDatabasesActive=$( db2pd -alldbs | grep ' Database Name:' | grep -v '^$' | wc -l )
        lTestStatus="NO "
        if [ ${lDatabasesActive} -gt 0 ] ; then
          lTestStatus="YES"
        fi
        displayMessage "${lTestStatus}" "${lInstance}: Database(s) are activated"

          #
          # No databases are active. Is instance capping on?
          #   ${CAPPED_INSTANCE_MEMORY} is defined in the configuration file
          #
        lTestStatus="OK "
        if [ "${CAPPED_INSTANCE_MEMORY}" == "" -o \
             "$( echo ${CAPPED_INSTANCE_MEMORY} | sed 's/[0-9]*//g' )" == "" ] ; then
          CAPPED_INSTANCE_MEMORY=2500000
        fi
        if [ ${lDatabasesActive} -eq 0 ] ; then
          lInstanceMemInfo=$( echo "${lDbmCfgInfo}" \
                            | grep 'INSTANCE_MEMORY' \
                            | sed 's/  [ ]*/\n/g' \
                            |  grep -v '^$' \
                            | sed -n 2,2p )
          if [ $( echo "${lInstanceMemInfo}" | grep 'AUTOMATIC' | wc -l ) -gt 0 ] ; then
            lTestStatus="NOK"
          else
            # The instance memory parameter --> a numeric?
            if [ "$( echo "${lInstanceMemInfo}" | sed 's/[0-9]*//g' )" == "" ] ; then
              # More than 1GB given?
              if [ ${lInstanceMemInfo} -gt ${CAPPED_INSTANCE_MEMORY} ] ; then
                lTestStatus="NOK"
              fi
            fi
          fi
          displayMessage "${lTestStatus}" "${lInstance}: Instance memory is capped: ${lInstanceMemInfo} < ${CAPPED_INSTANCE_MEMORY}"
        else
          displayMessage "${lTestStatus}" "${lInstance}: Instance memory is capped -> not in scope"
        fi

      fi
    fi

    set +x
    return 0

  }

  function checkDb2InstanceRegistry {
    typeset    lTestStatus="OK "
    typeset    lValue=""
    typeset    db2CurrentRegistry
    typeset    missingSetting

    if [ "${lInstanceType}" != "Client" ] ; then
      #
      # DB2 Registry has minimal values
      #   ${DB2REGISTRY} is defined in the config file
      #
      lTestStatus="OK "
      db2CurrentRegistry=$( db2set -all )
      missingSetting=""
      for db2RegSetting in $( echo ${DB2REGISTRY} | sed 's/,/ /g' )
      do
        if [ $( echo "${db2CurrentRegistry}" | grep " ${db2RegSetting}=" | wc -l ) -eq 0 ] ; then
          lTestStatus="NOK"
          missingSetting="${missingSetting}, ${db2RegSetting}"
        fi
      done
      missingSetting=$( echo ${missingSetting} | sed "s/^, /: /g" )
      displayMessage "${lTestStatus}" "${lInstance}: Minimal set of DB2 registry variables${missingSetting}"
    fi

    set +x
    return 0

  }

  function checkDb2InstancePort {
    typeset    lTestStatus="OK "
    typeset    lValue=""
    typeset    lListeningPort
    typeset    lServiceName
    typeset    lListeningProcess

    if [ "${lInstanceType}" != "Client" ] ; then
      #
      # DB2 listening on which port
      #
      if [ "${lInstanceStarted}" == "TRUE" ] ; then
        lListeningPort=$( echo "${lDbmCfgInfo}" \
                        | grep '^SVCENAME' \
                        | sed 's/  [ ]*/\n/g' \
                        | grep -v '^$' \
                        | sed -n 2,2p )
      else
        lListeningPort=$( echo "${lDbmCfgInfo}" | grep '(SVCENAME)' | sed -n 1,1p | awk -F' ' '{print $6}' )
      fi

      lTestStatus="OK "
      if [ $( grep "^${lListeningPort}" /etc/services | grep -v '^$' | wc -l ) -eq 0 ] ; then
        lTestStatus="NOK"
      fi
      displayMessage "${lTestStatus}" "${lInstance}: Listening port (${lListeningPort}) is a service name registered in /etc/services"

      if [ "${lTestStatus}" == "NOK" ] ; then
        lTestStatus="OK "
        lServiceName=$( grep "[ \t]*${lListeningPort}" /etc/services | grep ${lInstance} | awk -F' ' '{print $1}' )
        if [ $( echo "${lServiceName}" | grep -v '^$' | wc -l ) -eq 0 ] ; then
          lTestStatus="NOK"
        else
          lServiceName=": ${lServiceName}"
        fi
        displayMessage "${lTestStatus}" "${lInstance}: Service name registered in /etc/services${lServiceName}"
      fi

      if [ "${lTestStatus}" == "NOK" ] ; then
        lTestStatus="OK "
        lServiceName=$( grep "[ \t]*${lListeningPort}" /etc/services | awk -F' ' '{print $1}' | grep -v '^$' | head -1 )
        if [ "${lServiceName}" != "" ] ; then
          lTestStatus="NOK"
          lServiceName=": ${lServiceName}"
        fi
        displayMessage "${lTestStatus}" "${lInstance}: Another service is registered in /etc/services on port ${lListeningPort}${lServiceName}"
      fi

      lTestStatus="OK "
      lListeningProcess=$( netstat -tulpen 2>&1 | grep ":${lListeningPort} " | awk -F' ' '{print $9}' )
      if [ "${lListeningProcess}" != "" ] ; then
        if [ $( echo "${lListeningProcess}" | grep 'db2sysc' | grep -v '^$' | wc -l ) -eq 0 ] ; then
          lTestStatus="NOK"
        fi
        displayMessage "${lTestStatus}" "${lInstance}: A DB2 process is listening on the port"
      fi
    fi

    set +x
    return 0

  }

  function checkSecurity {
    typeset -l lElementType="${1}"
    typeset    lIdentifier="${2}"
    typeset    lElement="${3}"
    typeset    lSecUser="${4}"
    typeset    lSecGroup="${5}"
    typeset    lSecPermission="${6}"
    typeset    lDbId=""

    typeset lTestStatus="OK "
    typeset lTypeLabel=""

    if [ "${lElementType}" == "directory" ] ; then
      lTypeLabel="Directory"
      if [ ! -d "${lElement}" ] ; then
        lTestStatus="NOK"
      fi
      displayMessage "${lTestStatus}" "${lIdentifier}: Directory does exist: ${lElement}"
    else
      lTypeLabel="File"
      if [ ! -f "${lElement}" ] ; then
        lTestStatus="NOK"
      fi
      displayMessage "${lTestStatus}" "${lIdentifier}: File does exist: ${lElement}"
    fi

    if [ "${lTestStatus}" == "OK " ] ; then
      lTestStatus="OK "
#      stat -c "%U %G %a" ${lElement} > /tmp/$$.check
#      lValues=$( cat /tmp/$$.check; rm -f /tmp/$$.check > /dev/null 2>&1 )
      lValues=$( stat -c "%U %G %a" ${lElement} )
      if [ "${lSecUser}" != "" ] ; then
        lFound=$( echo "${lValues}" | tr ' ' '\n' | sed -n 1,1p )
        if [ $( echo "${lFound}" | grep -v '^$' | grep "^${lSecUser}$" | wc -l ) -ne 1 ] ; then
          lTestStatus="NOK"
        fi
        displayMessage "${lTestStatus}" "${lIdentifier}: ${lTypeLabel} ${lElement} has owner ${lSecUser} versus found ${lFound}"
      fi

      lTestStatus="OK "
      if [ "${lSecGroup}" != "" ] ; then
        lFound=$( echo "${lValues}" | tr ' ' '\n' | sed -n 2,2p )
        if [ $( echo "${lFound}" | grep -v '^$' | grep "^${lSecGroup}$" | wc -l ) -ne 1 ] ; then
          lTestStatus="NOK"
        fi
        displayMessage "${lTestStatus}" "${lIdentifier}: ${lTypeLabel} ${lElement} has group owner ${lSecGroup} versus found ${lFound}"
      fi

      lTestStatus="OK "
      if [ "${lSecPermission}" != "" ] ; then
        lFound=$( echo "${lValues}" | tr ' ' '\n' | sed -n 3,3p )
        if [ ${#lSecPermission} -gt ${#lFound} -a ${#lFound} -eq 3 ] ; then
          lFound="0${lFound}"
        fi
        if [ $( echo "${lFound}" | grep -v '^$' | grep "^${lSecPermission}$" | wc -l ) -ne 1 ] ; then
          lTestStatus="NOK"
        fi
        displayMessage "${lTestStatus}" "${lIdentifier}: ${lTypeLabel} ${lElement} has permission ${lSecPermission} versus found ${lFound}"
      fi
    else
      set +x
      [[ "${lElementType}" == "directory" ]] && return 1
      [[ "${lElementType}" == "file" ]] && return 2
      return 3
    fi

    set +x
    return 0

  }

  function checkOsPermissionInstance {
    typeset    lTestStatus="OK "
    typeset    lValue=""
    typeset    lFencedHome

    #
    # Does the home folder belong to the correct set lUserId:lGroupId?
    #
    if [ "$( uname )" == "Linux" ] ; then

      #
      # Check the UserID and GroupID of the home directory vs the User ID of the instance owner
      # Home directory
      #
      if [ "${lInstanceType}" != "Client" ] ; then
        checkSecurity "directory" "${lInstance}" "${HOME}" "${lInstance}" "${lInstance}" "755"
      else
        checkSecurity "directory" "${lInstance}" "${HOME}" "${lInstance}" "??????" "755"
      fi

      #
      # Check the UserID and GroupID of the home directory vs the User ID of the fenced user
      # Home directory
      #
      if [ "${lInstanceType}" != "Client" -a "${lFencedUser}" != "" ] ; then
        lFencedHome=$( grep "^${lFencedUser}:" /etc/passwd | cut -d ':' -f 6 )
        checkSecurity "directory" "${lFencedUser}" "${lFencedHome}" "${lFencedUser}" "${lFencedUser}" ""
      fi
    fi

    set +x
    return 0

  }

  function checkOsPermissionSshDir {
    typeset    lTestStatus="OK "
    typeset    lValue=""
    typeset -u lDoCheck
    typeset    lFile

    #
    # Are the permission on .ssh folder (and files) OK?
    #   Defined in config file
    #     * ${SSH_DIRECTORY_PERMISSIONS}
    #     * ${SSH_FILE_PERMISSIONS}
    #
    checkSecurity "directory" "${lInstance}" "${HOME}/.ssh" \
                    "${lInstance}" "${lInstance}" "${SSH_DIRECTORY_PERMISSIONS}"
    if [ -d ${HOME}/.ssh ] ; then
      for lFileToCheck in $(   echo "${SSH_FILE_PERMISSIONS}" \
                              | sed -e 's/[ ]*//g' \
                              | tr ',' '\n' )
      do
        lDoCheck="YES"
        lFile=$( echo "${lFileToCheck}" | cut -d':' -f1 )
        if [ $( echo ${lFile} | grep '^id_rsa*' | wc -l ) -gt 0 ] ; then
          lDoCheck="NO"
        fi
        if [ "${lDoCheck}" == "YES" ] ; then
          lCompleteFile="${HOME}/.ssh/${lFile}"
          lRights=$( echo "${lFileToCheck}" | cut -d':' -f2 )

          checkSecurity "file" "${lInstance}" "${lCompleteFile}" "" "" "${lRights}"
        fi
      done
    fi

    set +x
    return 0

  }

  function checkOsPermissionDatabase {
    typeset    lTestStatus="OK "
    typeset    llWantedSecurity=""

      #
      # Checks USER:GRP as owner of a directory and given rights to the directory
      #
    for lDb2Directory in $( ls -1 / | grep db2 | egrep -v 'db2software|db2mig2bs|db2backup|db2ftp|db2dump|db2exports|db2scripts' )
    do
      lWantedSecurity="0775"
      if [ $( echo "${lDb2Directory}" | grep -i 'archive' | wc -l ) -gt 0 ] ; then
        lWantedSecurity="0750"
      fi
      checkSecurity "directory" "${lInstance}:${lDatabase}" "/${lDb2Directory}/${lInstance}/${lDatabase}" \
                       "${lInstance}" "${lInstance}" "${lWantedSecurity}"
    done # for each /db2* directory

    set +x
    return 0

  }

  function checkTouchFile {
    typeset    lTargetFile="${1}"
    typeset -u lShowDebugInfo="${2}"

    typeset lTestStatus="OK "
    typeset lValue=""

    [[ "${lShowDebugInfo}" == "TRUE" ]] && set -x
    if [ -d ${lTargetFile%/*} ] ; then
      [[ "${lTargetFile}" != "" ]] && lValue=$( touch ${lTargetFile} 2>&1 )
      [[ -f "${lTargetFile}" ]] && rm -f ${lTargetFile}

      if [ $( echo "${lValue}" | grep 'cannot touch' | wc -l ) -gt 0 ] ; then
        lTestStatus="NOK"
      fi
      if [ "${lDatabase}" == "" ] ; then
        displayMessage "${lTestStatus}" "${lInstance}: Directory is writeable: ${lTargetFile%/*}"
      else
        displayMessage "${lTestStatus}" "${lInstance}:${lDatabase}: Directory is writeable: ${lTargetFile%/*}"
      fi
    else
      lTestStatus="NOK"
      if [ "${lDatabase}" == "" ] ; then
        displayMessage "${lTestStatus}" "${lInstance}: Directory does exist: ${lTargetFile%/*}"
      else
        displayMessage "${lTestStatus}" "${lInstance}:${lDatabase}: Directory does exist: ${lTargetFile%/*}"
      fi
    fi
    set +x
    return 0
  }

  function checkMigrationParameters {
    typeset lTestStatus="OK "
    typeset lValue=""

    lValue=$(   db2pd -dbcfg -d ${lDatabase} \
              | egrep -i 'BLOCKNONLOGGED|LOGINDEXBUILD|LOG_DDL_STMTS' \
              | awk -F ' ' '{print $1"="$2}' \
              | sed 's/=0$/=OFF/g; s/=[1-9]$/=ON/g' \
              | grep -v '^$' )
    if [ "${lValue}" == "" ] ; then
      if db2 +o connect to ${lDatabase}
      then
        lValue=$(  db2 get db cfg \
                 | egrep 'BLOCKNONLOGGED|LOGINDEXBUILD|LOG_DDL_STMTS' \
                 | sed 's:(:\n(:g' \
                 | grep '^(' | sed 's:[() ]::g' )
        db2 +o connect reset
      fi
    fi
    for lParameter in BLOCKNONLOGGED=YES LOGINDEXBUILD=ON LOG_DDL_STMTS=YES
    do
      lTestStatus="OK "
      if [ $( echo "${lValue}" | grep "^${lParameter}$" | wc -l ) -eq 0 ] ; then
        lTestStatus="NOK"
      fi
      displayMessage "${lTestStatus}" "${lInstance}:${lDatabase}: DB CFG parameter is set: ${lParameter}"
    done

    set +x
    return 0
  }

#
# Primary initialization of commonly used variables
#
typeset    lTimestampToday=$( date "+%Y-%m-%d-%H.%M.%S" )
  ## typeset    lDb2Profile=""
  ## typeset    lDb2ProfileHome=""
typeset -l lInstance=""
typeset -u lDatabase=""
typeset    lUsername=""
typeset    lPassword=""
typeset -u lMergeReport="No"
typeset -u lVerbose="YES"
typeset -i lReturnCode=0

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
# Primary initialization of commonly used variables
#
typeset    lTimestampToday=$( date "+%Y-%m-%d-%H.%M.%S" )
  ## typeset    lDb2Profile=""
  ## typeset    lDb2ProfileHome=""
typeset -l lInstance=""
typeset -u lDatabase=""
typeset    _lReportName=""
typeset    lUsername=""
typeset    lPassword=""
typeset -u lVerbose="YES"
typeset -i lReturnCode=0

typeset    lLogOutputDir=""
typeset    lLogOutput=""

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
    [[ "${_lCmdOption}" == "" && "${_lCmdValue}" == "" ]] && _lCmdOption="--"

    case ${_lCmdOption} in
      -i | --instance )
        lInstance="${_lCmdValue}"
        shift 2
        ;;
      -d | --database )
        lDatabase="${_lCmdValue}"
        shift 2
        ;;
      -r | --_reportname )
        _lReportName="${_lCmdValue}"
        shift 2
        ;;
      -m | --mergereport )
         lMergeReport="Yes"
        shift 1
        ;;
      -lMergeReportq | --quiet )
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

#
# Force variable(s) to values within boundaries and set a default when needed
#
[[ "${lVerbose}" != "NO" ]] && lVerbose="YES"

#
# Make sure logging can be done properly
#
if [ "${lMergeReport}" == "NO" ] ; then
  typeset lLogOutputDir="${cLogsDirBase}"
  typeset lLogOutput="${lLogOutputDir}/${lTimestampToday}"
  if [ "${lInstance}" == "" ] ; then
    lLogOutput="${lLogOutput}_db2_server_validation.log"
  else
    lLogOutput="${lLogOutput}_db2_instance_${lInstance}_validation.log"
  fi
  mkdir -p ${lLogOutputDir} >/dev/null 2>&1
  #chgrp -R db2admx ${lLogOutputDir} >/dev/null 2>&1
  rm -f ${lLogOutput} >/dev/null 2>&1
  touch ${lLogOutput} >/dev/null 2>&1
  lReturnCode=$?
  if [ ${lReturnCode} -ne 0 ] ; then
    gErrorNo=4
    gMessage="Cannot create an outputfile ${lLogOutput}"
    scriptUsage
  elif [ "${lVerbose}" == "YES" ] ; then
    echo "Execution log is written to :  ${lLogOutput}"
  fi
  chmod a+rw ${lLogOutput} >/dev/null 2>&1
elif [ "${_lReportName}" != "" ] ; then
  lLogOutput=${_lReportName}
fi

#
# Validate the input data
#

#
# Load Db2 library
#
if [ "${lInstance}" == "${USER}" -o "${lDatabase}" != "" ] ; then
    # Only load when not yet done
  if [ -z "${IBM_DB_HOME}" -o "${DB2INSTANCE}" != "${lInstance}" ] ; then
    lDb2Profile="/${HOME}/sqllib/db2profile"
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
fi

#
# Set default umask
#
umask ${cMasking}

#
# Main - Get to work
#
typeset    lConfigFile=""
typeset -i lNumberOfInstances=0
typeset    lNewestDb2Version=""
typeset    lNewestDb2=""
typeset    lRegistryExec=""
typeset    lInstancesToHandle=""
typeset    lSshResult=""
typeset    lSudoResult=""
typeset -l lFencedUser=""
typeset    lInstanceType=""
typeset -u lInstanceStarted="FALSE"
typeset    lDbmCfgInfo=""
typeset -u lDbList=""

if [ -f ${cScriptDir}/db2_server_validation.cfg ] ; then
  lConfigFile=${cScriptDir}/db2_server_validation.cfg
fi
if [ ! -f ${lConfigFile} ] ; then
  gErrorNo=5
  gMessage="Couldn't find the configuration file '${lConfigFile}'."
  scriptUsage
fi

#
# Load the default settings
#
getIniSection "${lConfigFile}" "default"

#
# Overwrite the default settings with those specific to the machine
#
getIniSection "${lConfigFile}" "${cHostName}"

if [ "${lMergeReport}" == "NO" ] ; then
  #
  # Start reporting
  #
  echo "--  Status report for the server ${cHostName}  --"
  echo "----- config used : ${lConfigFile} -----"
  [[ "${lInstance}" != "" ]] && echo "------ instance : ${lInstance} ------"
  [[ "${lDatabase}" != "" ]] && echo "------ database : ${lDatabase} ------"
  echo ""

  if [ "${lLogOutput}" != "" ] ; then
    echo "--  Status report for the server ${cHostName}  --" >> ${lLogOutput}
    echo "----- config used : ${lConfigFile} -----" >> ${lLogOutput}
    [[ "${lInstance}" != "" ]] && echo "------ instance : ${lInstance} ------" >> ${lLogOutput}
    [[ "${lDatabase}" != "" ]] && echo "------ database : ${lDatabase} ------" >> ${lLogOutput}
    echo "" >> ${lLogOutput}
  fi
fi

if [ "${lInstance}" == "" ] ; then
  checkLocalUsers
  checkDb2DirPermissions
  checkSystemConf
  checkSwappiness
  checkFstabAndMount "Local"
  checkFstabAndMount "NFS"
  checkDb2Instances # Fills up ${lInstancesToHandle}
  checkDbInstalledVersions

  [[ "${gDb2InstancesList}" == "" ]] && fetchAllDb2Instances
  for lInstance in ${gDb2InstancesList}
  do
    lSshResult=$( ssh ${cSshOptions} ${lInstance}@localhost 'ls -l ~/.ssh/*' 2>&1 \
                | grep -i permission )
    if [ "${lSshResult}" != "" ] ; then
      lSudoResult=$( sudo -n -u ${lInstance} ls -l 2>&1 \
                   | grep -i 'a password is required' )
    fi

    if [ "${lSshResult}" == "" ] ; then
      # Permission is not denied, so we can use SSH
      ssh ${cSshOptions} ${lInstance}@localhost "${cScriptDir}/${cBaseNameScript} --instance '${lInstance}' --mergeReport --_reportname '${lLogOutput}'"
    elif [ "{lSudoResult}" == "" ] ; then
      # No need for a password, so we can use SUDO
      sudo -n -u ${lInstance} ${cScriptDir}/${cBaseNameScript} --instance "${lInstance}" --mergeReport --_reportname "${lLogOutput}"
    elif [ "${USER}" == "root" ] ; then
      su --login -c "${cScriptDir}/${cBaseNameScript} --instance '${lInstance}' --mergeReport --_reportname '${lLogOutput}'" ${lInstance}
    fi
  done
elif [ "${lInstance}" == "${USER}" -a "${lDatabase}" == "" ] ; then
  checkDb2Installed
  checkDb2License
  checkLocalDefinitionOfUser "instance"
  checkLocalDefinitionOfUser "fenced_user"  # Fills ${lFencedUser}
  checkDb2Instance          # Fills ${lInstanceType}, ${lInstanceStarted}, ${lDbmCfgInfo}
  checkDb2InstanceRegistry  # Uses ${lInstanceType}
  checkDb2InstancePort      # Uses ${lInstanceType}, ${lInstanceStarted}, ${lDbmCfgInfo}
  checkOsPermissionInstance # Uses ${lInstanceType}, ${lFencedUser}
  checkOsPermissionSshDir   # Uses ${lInstanceType}, ${lFencedUser}
  checkTouchFile "/db2data/${lInstance}/touch.testServer"
  checkTouchFile "/db2activelogs/${lInstance}/touch.testServer"
  checkTouchFile "/db2archivelogs/${lInstance}/touch.testServer"
  checkTouchFile "/db2backups/backup_${cHostName}/${lInstance}/touch.testServer"
  checkTouchFile "/db2scripts/touch.testServer"
  checkTouchFile "/db2scripts/householding/touch.testServer"
  checkTouchFile "/db2scripts/ddl/touch.testServer"
  checkTouchFile "/db2scripts/logs/touch.testServer"
  checkTouchFile "/db2dump/${lInstance}/touch.testServer"


  lDbList=$(  db2 list db directory 2>&1 \
            | grep -B5 '= Indirect' \
            | grep 'Database alias' \
            | cut -d '=' -f 2 \
            | tr -d ' ' \
            | grep -v '^$' )
  for lCurrentDb in ${lDbList}
  do
    ${cScriptDir}/${cBaseNameScript} --instance ${lInstance} --database ${lCurrentDb} --mergeReport --_reportname "${lLogOutput}"
  done
elif [ "${lInstance}" == "${USER}" -a "${lDatabase}" != "" ] ; then
  #
  # Check the privileges of directories and files within them
  #
  checkTouchFile "/db2data/${lInstance}/${lDatabase}/touch.testServer"

  # Need a test to be able to connect to the database with a application user
  #   to see whether the PAM modules are correctly installed

  # Are databases to be stored on a dedicated LV?

  checkMigrationParameters
  checkOsPermissionDatabase
fi

#
# Finish up
#
set +x
exit 0
