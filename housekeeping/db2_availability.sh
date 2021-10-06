#!/bin/bash
#
# Script     : db2_availability.sh
# Description: Return the overall state of the database(s)
#
#<header>
#
# Remarks   : Parameters:
#   * Mandatory
#       -I | --instance   : Instance name
#
#   * Optional
#       -D | --database   : (List of space separated) Database name(s); when
#                             omitted all databases within the instance are
#                             handled, e.g. "DB01 DB02"
#       -U | --user       : User name to connect to the database
#       -P | --password   : The password matching the user name to connect
#                             to the database
#       -X | --exclude    : Database name (or grep pattern); database(s) to
#                             exclude from this script. Not applicable
#                             when the script is initiated for a single database
#       -q | --quiet      : Quiet - show no messages
#       -h | -H | --help  : Help
#
#</header>

#
# Constants
#
typeset    cCmdSwitchesShort="I:D:U:P:X:qhH"
typeset -l cCmdSwitchesLong="instance:,database:,user:,password:,exclude:,quiet,help"
typeset    cHostName=$( hostname )
typeset    cScriptName="${0}"
typeset    cBaseNameScript=$( basename ${cScriptName} )
typeset    cScriptDir="${cScriptName%/*}"
typeset    cBaseNameConfig="${cBaseNameScript%.*}.cfg"
typeset    cConfigName="${cScriptDir}/${cBaseNameConfig}"
typeset    cCurrentDir=$( pwd )
typeset    cLogsDirBase="/db2export/db2scripts/logs/${cBaseNameScript%.*}/${cHostName}"
typeset    cMasking="0002"

typeset -u cAvailabilityThresholdWarning="IMPLICIT"
typeset -u cAvailabilityThresholdCritical="INACTIVE"

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

  function  getThreshold {
    typeset -l lSensorName="${4}"
    typeset    lThreshold

    lThreshold=$( awk -F: -v IGNORECASE=1 "/^[^#]/&&\$1~/${1}/&&\$2~/${2}/&&\$3~/${3}/&&\$4~/${4}/{print \$5}" ${cConfigName} )
      # Default values

    if [ "${lSensorName}" == "availability" ] ; then
      [[ -z "${lThresholdWarning}" ]]  && lThresholdWarning=${cAvailabilityThresholdWarning}
      [[ -z "${lThresholdCritical}" ]] && lThresholdCritical=${cAvailabilityThresholdCritical}
    fi

    if [ ! -z "${lThreshold}" ] ; then
      if [ $( echo ${lThreshold} | grep ';' | wc -l ) -gt 0 ] ; then
        lThresholdWarning=$( echo ${lThreshold} | cut -d ';' -f 1 )
        lThresholdCritical=$( echo ${lThreshold} | cut -d ';' -f 2 )
      else
        lThresholdWarning="0"
        lThresholdCritical=${lThreshold}
      fi
    fi

    if [ "${lSensorName}" == "availability" -a "${lThresholdWarning}" == "EXPLICIT" ] ; then
      # When a database is activated, its status is "EXPLICIT" therefore this
      #   cannot be a "Warning". Change to the next (lower) value -->
      lThresholdWarning="IMPLICIT"
    fi

    set +x
    return 0
  }

  function getActivationStatus {

    typeset lHostName="${1}"
    typeset lInstance="${2}"
    typeset lDatabase="${3}"

    typeset lReturnedText=""
    typeset lReturnedStatus=0

      # Get applicable threshold from config file
    getThreshold "*"            "*"            "*"            "availability"
    getThreshold "${lHostName}" "*"            "*"            "availability"
    getThreshold "${lHostName}" "${lInstance}" "*"            "availability"
    getThreshold "${lHostName}" "${lInstance}" "${lDatabase}" "availability"
    if [ "${lThresholdWarning}" == "0" -a "${lThresholdCritical}" == "0" ] ; then
        # Restrain from returning any feedback, because no checking wanted!
      set +x
      return 10
    fi

    typeset lCheckmkServiceName="Activation_status_${lHostName}_${lInstance}_${lDatabase}"
    typeset lDbCmd="db2pd -d ${lDatabase} -bufferpools | awk '1,/^$/' | grep -v '^$' | head -1"
    typeset lStatusInfo=""
    typeset lStatusText=""

    lStatusInfo=$( db2pd -d ${lDatabase} -bufferpools | awk '1,/^$/' | grep -v '^$' | head -1 )

    if [ $( echo ${lStatusInfo} | grep -i ' not activated ' | wc -l ) -gt 0 ] ; then
      lReturnedStatus=2
        # Database is NOT activated, which in general is not appreciated ...
        #   unless the configuration file defines it as a warning
      if [ "${lThresholdWarning}" == "INACTIVE" ] ; then
        lReturnedStatus=100  # Special case (out of the normal checkMK range)
      fi
    elif [ $( echo ${lStatusInfo} | grep -i ' active ' | wc -l ) -gt 0 ] ; then
      gDatabase="${lDatabase}"
      getCurrentDbActivationState
      lReturnedStatus=0
      if [ "${gDb2ActivationStatus}" == "${lThresholdWarning}" ] ; then
        lReturnedStatus=100
        if [ "${lThresholdWarning}" == "IMPLICIT" ] ; then
          lReturnedStatus=101
        fi
      elif [ "${gDb2ActivationStatus}" == "${lThresholdCritical}" ] ; then
        lReturnedStatus=200
        if [ "${lThresholdCritical}" == "IMPLICIT" ] ; then
          lReturnedStatus=201
        fi
      elif [ "${gDb2ActivationStatus}" == "UNKNOWN"  ] ; then
        lReturnedStatus=102
      fi
    fi

    case ${lReturnedStatus:0:1} in
      0 )
        lStatusText="OK"
        lReturnedText="is active"
        ;;
      1 )
        lStatusText="WARNING"
        case ${lReturnedStatus} in
          1 )
            # All what is needed to be set is already set
            ;;
          100 )
            lReturnedText="is INACTIVE."
            ;;
          101 )
            lReturnedText="should be activated EXPLICITLY."
            ;;
          102 )
            lReturnedText="is active, but cannot be determined if this is IMPLICIT or EXPLICIT."
            ;;
          * )
            lReturnedText=" ... currently not yet implemented"
            ;;
        esac
        lReturnedStatus=1
        ;;
      2 )
        lStatusText="CRITICAL"
        lReturnedText="is INACTIVE."
        case ${lReturnedStatus} in
          2 )
            # All what is needed to be set is already set
            ;;
          201 )
            lReturnedText="is not activated EXPLICITLY."
            ;;
          * )
            lReturnedText=" ... currently not yet implemented"
            ;;
        esac
        lReturnedStatus=2
        ;;
      * )
        lReturnedStatus=3
        lStatusText="UNKNOWN"
        lReturnedText="is in an UNKNOWN state."
    esac
    echo "${lReturnedStatus} ${lCheckmkServiceName} activation_status=${lReturnedStatus};;2 ${lStatusText} - ${lDatabase} ${lReturnedText}"

    set +x
    return ${lReturnedStatus}
  }

  function getQuiesceStatus {

    typeset lHostName="${1}"
    typeset lInstance="${2}"
    typeset lDatabase="${3}"
    typeset lSuNeeded="${4}"

    typeset lReturnedText=""
    typeset lReturnedStatus=0

    typeset lCheckmkServiceName="Quiesce_status_${lHostName}_${lInstance}_${lDatabase}"
    typeset lStatusInfo=""
    typeset lStatusText="UNKNOWN"

    lStatusInfo=$( db2pd -d ${lDatabase} -bufferpools | awk '1,/^$/' | grep -v '^$' | head -1 )

    lReturnedStatus=3
    lReturnedText="is in an UNKNOWN state."
    if [ $( echo ${lStatusInfo} | grep -i ' not activated ' | wc -l ) -eq 0 ] ; then
      lReturnedStatus=2
      lStatusText="CRITICAL"
      lReturnedText="is QUIESCEd."
      if [ $( echo ${lStatusInfo} | grep -i ' Quiesce[d]* ' | grep -v '^$' | wc -l ) -eq 0 ] ; then
        lReturnedStatus=0
        lStatusText="OK"
        lReturnedText="is not quiesced."
        if [ $( db2pd -d ${lDbToHandle} -utilities | grep -i ' BACKUP ' | grep -v '^$' | wc -l ) -gt 0 ] ; then
          lReturnedStatus=1
          lStatusText="WARNING"
          lReturnedText="is QUIESCEd as part of a backup".
        fi
      fi
    fi
    echo "${lReturnedStatus} ${lCheckmkServiceName} quiesce_status=${lReturnedStatus};1;2 ${lStatusText} - ${lDatabase} ${lReturnedText}"

    set +x
    return ${lReturnedStatus}
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
typeset -u lVerbose="YES"
typeset -i lStatus=0
typeset -i lReturnCode=0
typeset -u lThresholdWarning
typeset -u lThresholdCritical

#
# Loading libraries
#
[[ $# -gt 0 && ! -f ${cScriptDir}/common_functions.include ]] && gErrorNo=2 && gMessage="Cannot load ${cScriptDir}/common_functions.include" && scriptUsage
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
        if [ ${lReturnCode} -eq 0 ] ; then
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
# Check for the input parameters
#
    # Read and perform a lowercase on all '--long' switch options, store in $@
  eval set -- $(   echo "$@" \
                 | tr ' ' '\n' \
                 | sed 's/^\(\-\-.*\)/\L\1/' \
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
  for lDbToHandle in ${lDatabase}
  do
    gDatabase="${lDatabase}"
    isDb2DbLocal
    lReturnCode=$?
    if [ ${lReturnCode} -ne 0 ] ; then
      gErrorNo=5
      gMessage="The database ${lDatabase} isn't defined local"
      scriptUsage
    fi
  done
  if [ $( echo ${lDatabaseList} | grep ' ' | wc -l ) -gt 0 ] ; then
    lDatabaseList=$(   echo "${lDatabase}" \
                     | tr ' ' '\n' \
                     | egrep -v "${lExcludedDatabase}" )
  else
    lDatabaseList=${lDatabase}
    lExcludedDatabase="^$"
  fi
else
  fetchAllDb2Databases
  lDatabaseList=$(   echo "${gDb2DatabaseList}" \
                   | egrep -v "${lExcludedDatabase}" \
                   | sort -u )
fi

#
# Set default umask
#
umask ${cMasking}

#
# Main - Get to work
#
typeset    lReturnedText
typeset -i lReturnedStatus
for lDbToHandle in ${lDatabaseList}
do
  lReturnedText=$( getActivationStatus "${cHostName}" "${lInstance}" "${lDbToHandle}" )
  lReturnedStatus=$?
  if [ ${lReturnedStatus} -le 4 ] ; then
    echo "${lReturnedText}"

    lReturnedText=$( getQuiesceStatus "${cHostName}" "${lInstance}" "${lDbToHandle}" )
    lReturnedStatus=$?
    [[ ${lReturnedStatus} -le 4 ]] && echo "${lReturnedText}"
  fi

done

#
# Finish up
#
set +x
exit 0
