#!/bin/bash
#
# Script     : send_mail.sh
# Description: Mail-wrapper-script
#
#<header>
#
# Remarks   : Parameters:
#   * Mandatory
#	-s | --subject	  : The subject of the mail
#	-d | --recipients : List of recipients
#	-f | --file	  : The file containing the body of the mail
#
#   * Optional
#       -U | --user       : The name to show up as the sender
#       -q | --quiet      : Quiet - show no messages
#       -h | -H | --help  : Help
#</header>

#
# Constants
#
typeset    cCmdSwitchesShort="s:d:f:U:qhH"
typeset -l cCmdSwitchesLong="subject:,recipients:,file:,user:,quiet,help"
typeset    cHostName=$( hostname )
typeset    cScriptName="${0}"
typeset    cBaseNameScript=$( basename ${cScriptName} )
typeset    cScriptDir="${cScriptName%/*}"
typeset    cCurrentDir=$( pwd )
typeset    cLogsDirBase="/shared/db2/logs/${cBaseNameScript%.*}/${cHostName}"
typeset    cMasking="0002"

typeset    cSupportMailPrograms="mailx"


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

  function sendMail {

    typeset    lMailProgram="${1}"
    typeset    lSubject="${2}"
    typeset    lRecipients="${3}"
    typeset    lFile="${4}"

    typeset    lSupportMailPrograms="mailx"
    typeset -i lReturnCode=0

    if [ -e ${lFile} -a "${lMailProgram}" != "" ] ; then

      case ${lMailProgram} in
        mailx )
          echo  "$( cat ${lFile} )" | mailx -r "${cMailSender}" -s "${lSubject}" "${lRecipients}"
	  ;;
	* )
	  echo "The mail program '${lMailProgram}' isn't supported. No mail is send."
	  lReturnCode=9
	  ;;
      esac
      lReturnCode=$?
    else
      lReturnCode=10
    fi

    set +x
    return ${lReturnCode}
  }


#
# Primary initialization of commonly used variables
#
typeset    lTimestampToday=$( date "+%Y-%m-%d-%H.%M.%S" )
typeset    lSubject=""
typeset    lRecipients=""
typeset    lUser=${USER}
typeset    lFile=""
typeset    lMailPg=""
typeset -u lVerbose="YES"
typeset    lReturnedText=""
typeset -i lReturnCode=0

#
# Loading libraries
#
[[ ! -f ${cScriptDir}/common_functions.include ]] && gErrorNo=2 && gMessage="Cannot load ${cScriptDir}/common_functions.include" && scriptUsage
. ${cScriptDir}/common_functions.include

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
      -s | --subject )
        lSubject="${_lCmdValue}"
        shift 2
        ;;
      -d | --recipients )
        lRecipients="${_lCmdValue}"
        shift 2
        ;;
      -f | --file )
        lFile="${_lCmdValue}"
        shift 2
        ;;
      -U | --user )
        lUser="${_lCmdValue}"
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
[[ "${lSubject}" == "" ]] && gErrorNo=1 && gMessage="Please provide a subject to do the work for" && scriptUsage
[[ "${lRecipients}" == "" ]] && gErrorNo=1 && gMessage="Please provide recipients to do the work for" && scriptUsage
[[ "${lFile}" == "" ]] && gErrorNo=1 && gMessage="Please provide a file to do the work for" && scriptUsage

# Force variable(s) to values within boundaries and set a default when needed
#
[[ "${lVerbose}" != "NO" ]] && lVerbose="YES"
typeset cMailSender="$( echo "${cHostName%}" | cut -d '.' -f1 )-${lUser}@onva-rjv.fgov.be"

#
# Can we find one of the supported mail programs?
#
lMailPg=""
for lCurrentMailPg in $( echo ${cSupportMailPrograms} | tr -d ' ' | tr ',' ' ' )
do
  lReturnedText=$( which ${lCurrentMailPg} | grep " no ${lCurrentMailPg} " )
  if [ "${lReturnedText}" == "" ] ; then
    lMailPg=${lCurrentMailPg}
    break 1
  fi
done
[[ "${lMailPg}" == "" ]] && gErrorNo=2 && gMessage="Couldn't find any of the supported mail programs (${cSupportMailPrograms})" && scriptUsage

#
# Main - Get to work
#
sendMail "${lMailPg}" "${lSubject}" "${lRecipients}" "${lFile}"
lReturnCode=$?

#
# Finish up
#
set +x
exit ${lReturnCode}

