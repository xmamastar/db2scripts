#!/bin/bash
#
# Script     : db2_runstats.sh
# Description: Runstats of tables
#
#<header>
#
# Remarks   : Parameters:
#   * Mandatory
#       -I | --instance   : Instance name
#       -D | --database   : Database name
#
#   * Optional
#       -s | --schema     : (List of comma separated) schema(s) to handle
#       -t | --table      : (List of comma separated) table(s) to handle
#       -q | --quiet      : Quiet - show no messages
#       -h | -H | --help  : Help
#
#</header>

#
# Constants
#
typeset    cCmdSwitchesShort="I:D:s:t:qhH"
typeset -l cCmdSwitchesLong="instance:,database:,schema:,table:,quiet,help"
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

  function getValidSchemas {

    typeset    lSchemaList="${1}"
    typeset    lTableList="${2}"
    typeset    lReturnedText=""
    typeset -i lReturnCode=0

    typeset    lSql="SELECT SCHEMANAME
                       FROM SYSCAT.SCHEMATA SCHEMA
                      WHERE EXISTS (
                              SELECT 1
                                FROM SYSCAT.TABLES TABLE
                               WHERE TABLE.TABSCHEMA = SCHEMA.SCHEMANAME
                                 AND TABLE.TYPE      = 'T'
                                 AND TABLE.OWNERTYPE = 'U'
                                 -- ## TABLE PLACE HOLDER ##
                            ) "

    if [ "${lSchemaList}" != "" ] ; then
      lSchemaList=$( echo ${lSchemaList} | sed "s/[ ]*,[ ]*/','/g" )
      lSql="${lSql} AND SCHEMANAME IN ('${lSchemaList}')"
    fi
    if [ "${lTableList}" != "" ] ; then
      lTableList=$( echo ${lTableList} | sed "s/[ ]*,[ ]*/','/g" )
      lSql=$( echo "${lSql}" | sed "s/-- ## TABLE PLACE HOLDER ##/ AND TABNAME IN ('${lTableList}')/g" )
    fi
    lReturnedText=$( db2 -x "${lSql}" )
    lReturnCode=$?

    if [ ${lReturnCode} -eq 0 ] ; then
      lReturnedText=$( echo "${lReturnedText}" | tr -d ' ' )
    else
      lReturnedText=""
    fi

    set +x
    lSchema="${lReturnedText}"
    return ${lReturnCode}

  }

  function getValidTables {

    typeset    lSchemaList="${1}"
    typeset    lTableList="${2}"
    typeset    lReturnedText=""
    typeset -i lReturnCode=0

    typeset    lSql="SELECT TRIM(TABSCHEMA) || '.' || TRIM(TABNAME) || '=' ||
                            CASE WHEN NOT STATISTICS_PROFILE IS NULL
                              THEN '1'
                              ELSE '0'
                            END
                       FROM SYSCAT.TABLES TABLE
                      WHERE TABLE.TYPE      = 'T'
                        AND TABLE.OWNERTYPE = 'U'
                        AND EXISTS (
                              SELECT 1
                                FROM SYSCAT.SCHEMATA SCHEMA
                               WHERE SCHEMA.SCHEMANAME = TABLE.TABSCHEMA
                            ) "
    if [ "${lSchemaList}" != "" ] ; then
      lSchemaList=$( echo ${lSchemaList} | sed "s/[ ,][ ]*/','/g" )
      lSql="${lSql} AND TABLE.TABSCHEMA IN ('${lSchemaList}')"
    fi
    if [ "${lTableList}" != "" ] ; then
      lTableList=$( echo ${lTableList} | sed "s/[ ,][ ]*/','/g" )
      lSql="${lSql} AND TABLE.TABNAME IN ('${lTableList}')"
    fi
    lReturnedText=$( db2 -x "${lSql} ORDER BY TABLE.TABSCHEMA, TABLE.TABNAME WITH UR FOR READ ONLY" )
    lReturnCode=$?

    if [ ${lReturnCode} -eq 0 ] ; then
      lReturnedText=$( echo "${lReturnedText}" | tr -d ' ' )
      typeset    lTable
      typeset -i lProfile
      for lCurrentFqTable in ${lReturnedText}
      do
        lTable=$( echo "${lCurrentFqTable}" | cut -d '=' -f 1 )
        lProfile=$( echo "${lCurrentFqTable}" | cut -d '=' -f 2 )
        lTableArray[${lTable}]=${lProfile}
      done
    fi

    set +x
    return ${lReturnCode}

  }


  function performRunstats {

    typeset    lReturnedText=""
    typeset -i lReturnCode=0

    typeset    lSchema=$( echo "${1}" | cut -d '.' -f 1 )
    typeset    lTable=$( echo "${1}" | cut -d '.' -f 2 )
    typeset -i lHasProfile=${2}


    if [ ${lHasProfile} -eq 0 ] ; then
      lReturnedText=$( db2 -v "RUNSTATS ON TABLE "${lSchema}"."${lTable}" ON ALL COLUMNS AND INDEXES ALL SET PROFILE ONLY" )
      lReturnCode=$?
    fi
    if [ ${lReturnCode} -eq 0 ] ; then
      lReturnedText=$( db2 -v "RUNSTATS ON TABLE "${lSchema}"."${lTable}" USE PROFILE" )
      lReturnCode=$?
    fi
    [[ "${lVerbose}" == "YES" ]] && echo "${lReturnedText}"

    set +x
    return ${lReturnCode}

  }



#
# Primary initialization of commonly used variables
#
typeset    lTimestampToday=$( date "+%Y-%m-%d-%H.%M.%S" )
typeset    lDb2Profile=""
typeset    lDb2ProfileHome=""
typeset -l lInstance=""
typeset -u lDatabase=""
typeset    lSchema=""
typeset    lTable=""
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
      -I | --instance )
        lInstance="${_lCmdValue}"
        shift 2
        ;;
      -D | --database )
        lDatabase="${_lCmdValue}"
        shift 2
        ;;
      -s | --schema )
        lSchema="${_lCmdValue}"
        shift 2
        ;;
      -t | --table )
        lTable="${_lCmdValue}"
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
[[ "${lDatabase}" == "" ]] && gErrorNo=1 && gMessage="Please provide a database to do the work for" && scriptUsage

#
# Force variable(s) to values within boundaries and set a default when needed
#
[[ "${lVerbose}"  != "NO" ]] && lVerbose="YES"

if [ "${lVerbose}" == "YES" ] ; then
  echo "-- Run statistics -----------------------
Schema                : ${lSchema:-ALL}
Table                 : ${lTable:-ALL}
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

getValidSchemas "${lSchema}" "${lTable}"
lReturnCode=$?
[[ ${lReturnCode} -ne 0 ]] && gErrorNo=6 && gMessage="Cannot find valid schemas" && scriptUsage

typeset -A lTableArray
getValidTables "${lSchema}" "${lTable}"
lReturnCode=$?
[[ ${lReturnCode} -ne 0 ]] && gErrorNo=7 && gMessage="Cannot find valid tables" && scriptUsage

typeset    lCurrentSchema=""
typeset    lCurrentTable=""
typeset    lTableList=""
typeset -i lCumulativeReturnCode=0

for lCurrentFqTable in ${!lTableArray[*]}
do
  lCurrentTable=$( echo "${lCurrentFqTable}" | cut -d '.' -f 2 )
  if [ $( echo "${lCurrentFqTable}" | grep "^${lCurrentSchema}\." | wc -l ) -eq 0 ] ; then
    lCurrentSchema=$( echo "${lCurrentFqTable}" | cut -d '.' -f 1 )
    lTableList="${lCurrentTable}"
  else
    lTableList="${lTableList},${lCurrentTable}"
  fi

  echo "Handling ${lCurrentFqTable}"
  performRunstats "${lCurrentFqTable}" "${lTableArray[${lCurrentFqTable}]}"
  lCumulativeReturnCode=$(( lCumulativeReturnCode + $? ))

done

[[ ${lCumulativeReturnCode} -gt 0 ]] && lCumulativeReturnCode=99

#
# Finish up
#
handleDb2DbDisconnect
set +x
exit ${lCumulativeReturnCode}
