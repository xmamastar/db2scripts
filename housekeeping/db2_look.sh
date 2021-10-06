#!/bin/bash
#
# Script     : db2_look.sh
# Description:  db2look command
#               
#
#<header>
#
# Remarks   : Parameters:
#   * Mandatory
#       -D | --database   : Database name
#
#   * Optional
#       -U | --user       : User name to connect to the database
#       -P | --password   : The password matching the user name to connect
#       -q | --quiet      : Quiet - show no messages
#       -h | -H | --help  : Help
#
#</header>

#
# Constants
#
typeset    cCmdSwitchesShort="D:U:P:qhH"
typeset -l cCmdSwitchesLong="database,:user:,password:,quiet,help"
typeset    cHostName=$( hostname )
typeset    cScriptName="${0}"
typeset    cBaseNameScript=$( basename ${cScriptName} )
typeset    cScriptDir="${cScriptName%/*}"
typeset    cCurrentDir=$( pwd )
typeset    cLogsDirBase="/shared/db2/logs/${cBaseNameScript%.*}/${cHostName}"
typeset    cMasking="0002"

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

  function performdb2look {

    typeset    lReturnedText=""
    typeset -i lReturnCode=0

    lReturnedText=$( db2look -d ${lDatabase} -e > ${lDatabase}.ddl )
    lReturnCode=$?
	echo "${lReturnedText}"
  }

#
# Primary initialization of commonly used variables
#
typeset    lTimestampToday=$( date "+%Y-%m-%d-%H.%M.%S" )
typeset    lDb2Profile=""
typeset    lDb2ProfileHome=""
typeset -u lDatabase=""
typeset    lUsername=""
typeset    lPassword=""
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
[[ "${lDatabase}" == "" ]] && gErrorNo=1 && gMessage="Please provide a database to do the work for" && scriptUsage

#
# Force variable(s) to values within boundaries and set a default when needed
#
[[ "${lVerbose}"  != "NO" ]] && lVerbose="YES"

if [ "${lVerbose}" == "YES" ] ; then
  echo "-- Run db2look -----------------------
Database                : ${lDatabase}
User			: ${lUsername}
-----------------------------------------"
fi

#
# Load Db2 library
#
  # Only load when not yet done
if [ -z "${IBM_DB_HOME}" ] ; then
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
# Set default umask
#
umask ${cMasking}

#
# Main - Get to work
#
gDatabase="${lDatabase}"
handleDb2DbConnect
lReturnCode=$?
[[ ${lReturnCode} -ne 0 ]] && gErrorNo=5 && gMessage="Cannot connect to ${gDatabase}" && scriptUsage
performdb2look

#
# Finish up
#
handleDb2DbDisconnect
set +x
exit 0

