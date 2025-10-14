#!/bin/sh

# MobiControl Agent for Linux Installer Version 2.7
#
#==============================================================================
# Usage: install.sh [OPTIONS]
#	  -c
#	    Clean install. Will remove existing agent and configuration before 
#		installing. Will require confirmation if not used with -y. 
#	  -h
#	    Help. Prints this message and exits.
#	  -y
#	    Automatically accepts all prompts. Use at your own risk.
#	  -v
#		Verbose Mode.
#	  -p
#		Select agent platfome: (list is in PLATFORM_LIST array)
#	  -n
#		No Install. Will not start installation, only download required files.
#==============================================================================
# This script must be run with root permission to function properly. systemd,
# upstart, sysvinit, and busybox init are supported.
# 
SCRIPT_VERSION=2.7
DEBUG_OUTPUT=true #False by default
CLEAN_INSTALL= #False by default
AUTOACCEPT_PROMPTS= #False by default
NO_INSTALL= #False by default
USE_CURL=true #True by default
XTHUB_AGENT= #Set by CMake
XTHUB_ENROLLMENT_OVERRIDE=""
SYSTEM_DOTNET= #False by default

AGENT_FILE="mobicontrol"
CONFIG_FILE="MCSetup.ini"
INSTALL_DIR="/usr/opt/MobiControl"
INITSYSTEM=
INITD_FILE="sysv/mobicontrol"
SYSTEMD_FILE="systemd/mobicontrol.service"
UPSTART_FILE="upstart/mobicontrol.conf"
COMM_STATUS_DIR="/tmp/mobicontrol_status"
PLATFORM_DISPLAY=
USER_DEFINED_PLATFORM=${AGENT_PLATFORM}
TAR_FILE_NAME="installer.tar.gz"
TAR_FILE_LINK="https://a0030132.mobicontrol.cloud/enrollment/linux/agents"
INI_FILE_LINK="https://a0030132.mobicontrol.cloud/enrollment/linux/policies/7cc6ba18-7c4c-4c35-ba6a-a8cfb828633b/actions/downloadConfig"
TARFILEEXISTENCE=
PLATFORM_LIST="ARM ARM_Headless \
ARM64 ARM64_Headless \
ARM_SF ARM_SF_Headless \
x86 x86_Headless \
x64 x64_Headless"
XTHUB_PLATFORMS="ARM ARM_Headless
ARM64 ARM64_Headless
x64 x64_Headless"

# Read secret string
read_secret()
{
    # Disable echo.
    stty -echo

    # Set up trap to ensure echo is enabled before exiting if the script
    # is terminated while echo is disabled.
    trap 'stty echo' EXIT

    # Read secret.
    read "$@"

    # Enable echo.
    stty echo
    trap - EXIT

    # Print a newline because the newline entered by the user after
    # entering the passcode is not echoed. This ensures that the
    # next line of output begins at a new line.
    echo
}

#Test connection to server
pass() {
	echo "MobiControl agent was successfully installed"
	pipe=/tmp/pipo
	stdinput=/dev/stdin
	rm $pipe 2>/dev/null
	if [ ! -p $pipe ]; then
	    mkfifo $pipe
	fi

	while true
	do
	   if read -r line <$pipe; then
	       if [ "$line" = "quitAgent" ]; then
		    killRunningAgent
		    rm -rf /tmp/mobicontrol_status
		    break
	       fi
	       if [ "$line" = "IP_NOT_FOUND" ]; then
	       	break
	       fi
	       if [ "$line" = "quit" ]; then
	       	break
	       fi

	       strippedLine=$(echo $line | sed 's/[t ]*$//g')
	       if [ "$strippedLine" = "Please enter agent enrollment password:" ] || [ "$strippedLine" = "Please enter LDAP password:" ]; then
	       	printf "$strippedLine "
	       	if read_secret line2 <$stdinput; then
	       		oldIFS="$IFS"; IFS="";
	       		echo $line2 >$pipe
	       		echo $pipe >/dev/null
	       		IFS="$oldIFS"
	       	fi
	       	continue
	       elif [ "$strippedLine" = "Please enter LDAP username:" ]; then
	       	printf "$strippedLine "
	       	if read line2 <$stdinput; then
	       		oldIFS="$IFS"; IFS="";
	       		echo $line2 >$pipe
	       		echo $pipe >/dev/null
	       		IFS="$oldIFS"
	       	fi
	       	continue
	       elif [ "$line" = "Please enter agent enrollment password" ]; then
	       	echo $line
	       	if read line2 <$stdinput; then
	       		oldIFS="$IFS"; IFS="";
	       		echo $line2 >$pipe
	       		echo $pipe >/dev/null
	       		IFS="$oldIFS"
	       	fi
	       	continue
	       fi
		   
		   echo $line
	   fi
	  
	done
	rm /tmp/pipo 2> /dev/null
	if [ "$line" != "quitAgent" ]; then
    	echo "Connecting to MobiControl Server..."
	fi
	connected=
	for i in 1 2 3 4 5; do		
		if getNetworkCommand; then
			connected=true
			break
		fi
		sleep 5
	done

	if [ $connected ]; then
		echo "Agent is connected to MobiControl server"
    else
		echo "Agent is not connected to MobiControl server
                       ***Please check your internet connection as well as deployment server address. Use ./mobicontrol -s command to check the Mobicontrol agent connection status***"
    fi

	cleanInstaller
	exit 0
}

fail() {
	cleanInstaller
	>&2 echo "MobiControl agent installation failed. Exiting."
	exit 1
}

getPlatform() {
	#if platform is already set by environment variable or cli option then 
	#skip detection.
	if [ ${USER_DEFINED_PLATFORM} ]; then
		PLATFORM_DISPLAY=${USER_DEFINED_PLATFORM}
		[ "$DEBUG_OUTPUT" ] && echo "User defined agent type is $PLATFORM_DISPLAY"
		return
	fi

	PLATFORM=$(uname -m)
	case $PLATFORM in
		x86_64)AGENT_PLATFORM="x64";;
		i686)AGENT_PLATFORM="x86";;
		armv7l)AGENT_PLATFORM="ARM";;
		aarch64 | aarch64_be)AGENT_PLATFORM="ARM64";;
		arm64 | armv8b | armv8l)AGENT_PLATFORM="ARM64";;
		
		*)
			>&2 echo "Unrecognized architecture $PLATFORM."
			fail
			;;
	esac
	[ "$DEBUG_OUTPUT" ] && echo "Detected architechture is $AGENT_PLATFORM"
		
	if ! command -v X >/dev/null 2>&1; then
		AGENT_DISPLAY="Headless"
		[ "$DEBUG_OUTPUT" ] && echo "System detected as Headless"
	else
		AGENT_DISPLAY="Headed"
		[ "$DEBUG_OUTPUT" ] && echo "System detected as Headful"
	fi

	PLATFORM_DISPLAY="Linux_$AGENT_PLATFORM"
	if [ $AGENT_DISPLAY  = "Headless" ]; then
		PLATFORM_DISPLAY="${PLATFORM_DISPLAY}_Headless"
	fi
	if [ $XTHUB_AGENT ]; then
		PLATFORM_DISPLAY="${PLATFORM_DISPLAY}_XTremeHub"
	fi

	[ "$DEBUG_OUTPUT" ] && echo "Agent type is $PLATFORM_DISPLAY"
}

# Check for a file and if it is missing try to download it. 
# syntax:
# getFile fileName downloadLink validateCert
# examples:
# getFile $CONFIG_FILE $INI_FILE_LINK
# getFile $CONFIG_FILE $INI_FILE_LINK true
# getFile $TAR_FILE_NAME $TAR_FILE_LINK$PLATFORM_DISPLAY
getFile() {
	[ "$DEBUG_OUTPUT" ] && echo "Checking for $1 in current directory"
	if [ ! -f "$1" ]; then
		[ "$DEBUG_OUTPUT" ] && echo "$1 not found in current directory. Attempting to fetch from server."
		CERT_CHECK="--no-check-certificate"
		[ "$3" ] && CERT_CHECK="--secure-protocol=auto"
		#Download File
		if [ "$USE_CURL" = true ];then
			curl --insecure -o "$1" "$2" >/dev/null 2>&1
		else
			wget --no-check-certificate -O "$1" "$2" >/dev/null 2>&1
		fi

		if [ $? != 0 ]; then
			rm -f "$1"
			echo "Error when downloading $1 from server.. http client error"
			return 1
		elif [ ! -s "$1" ]; then
			rm -f "$1"
			echo "Error when downloading $1 from server..file is empty"
			return 1
		else
			[ "$DEBUG_OUTPUT" ] && echo "$1 downloaded successfully."
			return 0
		fi
	else
		[ "$DEBUG_OUTPUT" ] && echo "$1 found in current directory"
		return 0
	fi
}

#Remove untarred installer directory.
cleanInstaller() {
	rm -r installer >/dev/null 2>&1
}

#Use socket checking command as available on the system
getNetworkCommand () {
	if command -v ss >/dev/null; then
		ss -ptn state connected | grep "mobicontrol" >/dev/null
		return $?
	elif command -v lsof >/dev/null; then
		lsof -i -Fc | grep cmobicontrol >/dev/null #cmobicontrol isn't a typo, lsof prepends it to specify it as a "command name"
		return $?
	elif command -v netstat >/dev/null; then
		netstat -ptn | grep ESTABLISHED.*/mobicontrol >/dev/null
		return $?
	else
		>&2 echo "No compatible network command found. Unable to check connection."
		return 0
	fi
}
#Remove current agent and config file.
fullClean() {
	killRunningAgent
	[ "$DEBUG_OUTPUT" ] && echo "Removing installed agent and settings..."
	rm $INSTALL_DIR/$AGENT_FILE >/dev/null 2>&1
	rm $INSTALL_DIR/pdb.ini >/dev/null 2>&1
	rm $INSTALL_DIR/pdbt.ini >/dev/null 2>&1
	rm $INSTALL_DIR/pdbBackup.ini >/dev/null 2>&1
	cleanInstaller
}

killRunningAgent() {
	[ "$DEBUG_OUTPUT" ] && echo "Killing running agent..."
	systemctl stop mobicontrol >/dev/null 2>&1 || initctl stop mobicontrol >/dev/null 2>&1 || /etc/init.d/mobicontrol stop >/dev/null 2>&1
}

#Print usage message and exit.
getHelp() {
	printf "Usage: install.sh [OPTIONS] [-p <platform>]\n-c\n  Clean install. Will remove existing agent and configuration before installing.\n  Will require confirmation if not used with -y."
	printf "\n-v\n  Verbose output."
	printf "\n-h\n  Help. Prints this message and exits.\n-y\n  Automatically accepts all prompts. Use at your own risk."
	printf "\n-p\n  Agent platform to install, examples of supported platforms:\n  %s""$PLATFORM_LIST"
	printf "\n-n\n  No Install. Will not start installation, only download required files."
	printf "\n-x\n  Install agent as an XTremeHub agent. See https://www.soti.net/mc/help/v15.4/en/console/data/xtremehubs/xtreme_hubs.html for more information."
	printf "\n"
	exit 1
}

#Read user input. True if y or Y is pressed (or -y option is set), false otherwise. 

getUserResponse() {
	if [ "$AUTOACCEPT_PROMPTS" ]; then
		return 0
	fi
	read -r userResponse
	case $userResponse in
		[yY])
			return 0;;
		*)
			return 1;;
	esac
}

#returns 0 for true and 1 for false.
isKnownPlatform() {
	for p in $XTHUB_PLATFORMS; do
		[ "$p" = "$1" ] && return 0
	done
	return 1
}

isXTHubPlatform() {
	for p in $PLATFORM_LIST; do
		[ "$p" = "$1" ] && return 0
	done
	return 1
}

installLocalDotNet() {
	[ $1 ] && INSTALL_DIR=$1
	DOTNET_URL=
	DOTNET_CHECKSUM=
	ASPNET_URL=
	ASPNET_CHECKSUM=
	#.NET 6 only provides Linux binaries for x64, ARM, and ARM64
	if [ $AGENT_PLATFORM = "ARM" -o $AGENT_PLATFORM = "ARM_Headless" ]; then
		DOTNET_URL="https://download.visualstudio.microsoft.com/download/pr/1dc20d39-a5c4-4e23-a70b-842fcd6d603a/814d37d9c67811d9d2837905e4330eab/dotnet-runtime-8.0.7-linux-arm.tar.gz"
		DOTNET_CHECKSUM="ccfe95a95be3c64d568c6f79df391daf73304fa2c2aedf4616cd9981efe11cac698c157d8375da3afda691b78124cc6672fde7353b0fea4d45da15e003040a2a"
		ASPNET_URL="https://download.visualstudio.microsoft.com/download/pr/d37fc703-70c6-46f2-a5a1-b60f45fd71d0/6a74aa0bb89feb7f795df1ea92d030bf/aspnetcore-runtime-8.0.7-linux-arm.tar.gz"
		ASPNET_CHECKSUM="d0107441223a44f1c4d9fa08c2d66b1875d20917fb1dacab7f80a42f0da1428570dd1cb86bc1f6e4eef3414e1770768fc8f17b836d0f7ab9b890848bc18ce8b0"
	elif [ $AGENT_PLATFORM = "ARM64" -o $AGENT_PLATFORM = "ARM64_Headless" ]; then
		DOTNET_URL="https://download.visualstudio.microsoft.com/download/pr/710337b9-9cb6-4bc8-8d13-daeab2578a08/b3ec8c17f85e340820a0ab36a3870168/dotnet-runtime-8.0.7-linux-arm64.tar.gz"
		DOTNET_CHECKSUM="99e6959a1156d5abc8f0c73b3d493fc1e10a42d48a573226ebcfbdf96bb6fb1c8701db5b3582a4303ce26a4f784e74eb402cb6e5e4bcdbb5dfab8fea221cfe02"
		ASPNET_URL="https://download.visualstudio.microsoft.com/download/pr/421d499f-85cb-43dd-97b2-8ebfd06dda8a/61b03be4662125e4af044c7881e66f0e/aspnetcore-runtime-8.0.7-linux-arm64.tar.gz"
		ASPNET_CHECKSUM="5f1d31b0efc793655abf4289f8f1c7e8cd1ffabfd65b385b49e3f5232277c62ccfbbdad2a51731a8a88594a06c2c9774e38865cb3f7e19c9925a12b25b40b485"
	elif [ $AGENT_PLATFORM = "x64" -o $AGENT_PLATFORM = "x64_Headless" ]; then
		DOTNET_URL="https://download.visualstudio.microsoft.com/download/pr/cf3418ca-0e14-4b76-b615-ac2f2497f8ec/2583028ea52460cb1534d929dc7970fe/dotnet-runtime-8.0.7-linux-x64.tar.gz"
		DOTNET_CHECKSUM="88e9ac34ad5ac76eec5499f2eb8d1aa35076518c842854ec1053953d34969c7bf1c5b2dbce245dbace3a18c3b8a4c79d2ef2d2ff105ce9d17cbbdbe813d8b16f"
		ASPNET_URL="https://download.visualstudio.microsoft.com/download/pr/06cbb934-ef54-4627-8848-a24a879f2130/52d4247944cee754ec8f4fd617d502a6/aspnetcore-runtime-8.0.7-linux-x64.tar.gz"
		ASPNET_CHECKSUM="c7479dc008fce77c2bfcaa1ac1c9fe6f64ef7e59609fff6707da14975aade73e3cb22b97f2b3922a2642fa8d843a3caf714ab3a2b357abeda486b9d0f8bebb18"
	fi

	#Download runtime archive files
	DOTNET_FILENAME=$(echo "$DOTNET_URL" | awk -F/ '{print $NF}')
	ASPNET_FILENAME=$(echo "$ASPNET_URL" | awk -F/ '{print $NF}')
	if ! getFile "$DOTNET_FILENAME" "$DOTNET_URL" "true"; then
		echo "Error downloading .NET runtime from $DOTNET_URL. Aborting."
		fail
	fi
	if ! getFile "$ASPNET_FILENAME" "$ASPNET_URL" "true"; then
		echo "Error downloading ASP.NET runtime from $ASPNET_URL. Aborting."
		fail
	fi

	#Verify checksums against downloaded archives
	if command -v sha512sum >/dev/null 2>&1; then
		DOTNET_DOWNLOADED_CHECKSUM=$(sha512sum $DOTNET_FILENAME | awk -F' ' '{print $1}')
		ASPNET_DOWNLOADED_CHECKSUM=$(sha512sum $ASPNET_FILENAME | awk -F' ' '{print $1}')
		if [ $DOTNET_DOWNLOADED_CHECKSUM != $DOTNET_CHECKSUM ]; then
			echo "Checksum for $DOTNET_FILENAME is a mismatch. Expected: $DOTNET_CHECKSUM Downloaded: $DOTNET_DOWNLOADED_CHECKSUM Aborting."
			fail
		elif [ $ASPNET_DOWNLOADED_CHECKSUM != $ASPNET_CHECKSUM ]; then
			echo "Checksum for $ASPNET_FILENAME is a mismatch. Expected: $ASPNET_CHECKSUM Downloaded: $ASPNET_DOWNLOADED_CHECKSUM Aborting."
			fail
		fi
	else
		echo "WARNING! sha512sum not available. Downloaded file checksums will NOT be validated."
	fi

	#Install from archives to agent install directory
	mkdir -p $INSTALL_DIR/dotnet >/dev/null 2>&1
	if ! tar -xzf $DOTNET_FILENAME --directory $INSTALL_DIR/dotnet >/dev/null 2>&1; then
		echo "Error extracting $DOTNET_FILENAME to $INSTALL_DIR/dotnet. Aborting."
		fail
	fi
	if ! tar -xzf $ASPNET_FILENAME --directory $INSTALL_DIR/dotnet >/dev/null 2>&1; then
		echo "Error extracting $ASPNET_FILENAME to $INSTALL_DIR/dotnet. Aborting."
		fail
	fi
}

isHostnameFQDN() {
	#This is not the exact regex used by the server, but it uses PCRE, which isn't available with some (e.g. Busybox) greps
	fqdnRegex='^([a-z0-9]+(-[a-z0-9]+)*\.?)+[a-z]{2,}$'
	echo $1 | tr A-Z a-z | grep -E "$fqdnRegex" && return 0
	return 1
}

checkHostnames() {
	! command -v hostname >/dev/null 2>&1 && >&2 echo "hostname command not available. Cannot validate hostnames." && return 1
	for hostname in $(hostname 2>/dev/null) $(hostname -f 2>/dev/null) $(hostname -A 2>/dev/null); do
		isHostnameFQDN $hostname && echo "Using valid FQDN $hostname for XTremeHub." && return 0
		[ $DEBUG_OUTPUT ] && echo "Hostname $hostname is not a valid FQDN."
	done
	return 1
}

# -------------------------------------------------------------------------
# -                              MAIN                                     -
# -------------------------------------------------------------------------

#check command line parameters
while getopts cvhypxs:n option; do
	case "${option}" in
		c)CLEAN_INSTALL=true;;
		v)DEBUG_OUTPUT=true;;
		h)getHelp;;
		y)AUTOACCEPT_PROMPTS=true;;
		p)AGENT_PLATFORM=${OPTARG};;
		n)NO_INSTALL=true;;
		s)SYSTEM_DOTNET=true;;
		\?)getHelp;;
	esac
done

# Check for root
ID=$(id -u 2>/dev/null)
if [ -z "$ID" ] ;then
	ID=$(ps -o euid= -p $$ | awk '{print $1}')
fi
if [ ! $NO_INSTALL ] && [ "$ID" != "0" ]; then
	>&2 echo "This script must be run as root."
	exit 1
fi

[ $DEBUG_OUTPUT ] && echo ' ____   ___ _____ ___ '
[ $DEBUG_OUTPUT ] && echo '/ ___| / _ \_   _|_ _|'
[ $DEBUG_OUTPUT ] && echo '\___ \| | | || |  | | '
[ $DEBUG_OUTPUT ] && echo ' ___) | |_| || |  | | '
[ $DEBUG_OUTPUT ] && echo '|____/ \___/ |_| |___|'
[ $DEBUG_OUTPUT ] && echo
[ $DEBUG_OUTPUT ] && echo "MobiControl Installer Version $SCRIPT_VERSION"

isUnifiedEnrollment=true
# check if it is unified enrollment or not.
# to decide if we should attempt to download installer.tar.gz
if echo $TAR_FILE_LINK | grep '_FILE_' > /dev/null 2>&1; then
    isUnifiedEnrollment=false;
fi

#Sanity check in case XTHUB_AGENT is not set properly
if echo $XTHUB_AGENT | grep '@' > /dev/null 2>&1; then
	XTHUB_AGENT=
fi

if $isUnifiedEnrollment; then
	#During unified enrollment, server will set XTHUB_ENROLLMENT_OVERRIDE to an empty string if the device is not intended to be an XTHub. If it does not, we set XTHUB_AGENT.
	if echo $XTHUB_ENROLLMENT_OVERRIDE | grep "IS_XTHUB" >/dev/null 2>&1; then
		XTHUB_AGENT=true
	fi 
fi

mv pdb.ini MCSetup.ini >/dev/null 2>&1
[ ! -x "$(command -v curl)" ] && USE_CURL=false

if [ -e installer ]; then
	echo "A file or directory named 'installer' exists in the current directory. This file would be deleted during installation. Delete file/directory now?[Y/N]"
	if getUserResponse; then
		rm -r installer
	else
		echo "Exiting."
		exit 1
	fi
fi

if [ ! $NO_INSTALL ] && [ $CLEAN_INSTALL ]; then
	echo "Clean installation requested. The existing agent and configuration on the device will be irrevocably removed before installation. Confirm?[Y/N]"
	if getUserResponse; then
		fullClean
	else
		echo "Exiting."
		exit 1
	fi
fi

#Get architecture and headed/headless status
getPlatform

if ! $isUnifiedEnrollment; then
	#this is not unified enrollment, we skip downloading tar file
    [ $DEBUG_OUTPUT ] && printf "Not Unified enrollment, skipping installer.tar.gz download.\n"
else
	#Download tar file if its not available in current directory.
	requestParams="?platform="
	if [ ${USER_DEFINED_PLATFORM} ]; then
		requestParams="${requestParams}${USER_DEFINED_PLATFORM}"
	else
		requestParams="${requestParams}Linux_${AGENT_PLATFORM}"
		if [ $XTHUB_AGENT ]; then
			requestParams="${requestParams}_XTremeHub"
		fi
		requestParams="${requestParams}&headless="
		if [ $AGENT_DISPLAY = "Headless" ]; then
			requestParams="${requestParams}true"
		else
			requestParams="${requestParams}false"
		fi
	fi
	getFile $TAR_FILE_NAME "${TAR_FILE_LINK}${requestParams}"
fi

#Download INI file
if ! getFile $CONFIG_FILE $INI_FILE_LINK; then
	# could not find or download MCSetup.ini file
        fail
fi

#Check if installer.tar available in current folder or not
if [ -f ${TAR_FILE_NAME} ];then
	#Attempt to extract agent tgz
	if ! tar -xzf $TAR_FILE_NAME >/dev/null 2>&1; then
		>&2 echo "Could not extract from $TAR_FILE_NAME"
		fail
	fi
	TARFILEEXISTENCE=true
fi

# If NO_INSTALL is set to true, exit with status 0.
[ $NO_INSTALL ] && exit 0

#Create required directories
[ $DEBUG_OUTPUT ] && echo "Creating installation directory $INSTALL_DIR"
mkdir -p $INSTALL_DIR
if ! chmod 0700 $INSTALL_DIR; then
	>&2 echo "Could not chmod of $INSTALL_DIR." >&2
	fail
fi
[ $DEBUG_OUTPUT ] && echo "Creating COMM status directory $COMM_STATUS_DIR"
mkdir -p $COMM_STATUS_DIR
if ! chmod 0555 $COMM_STATUS_DIR; then
	>&2 echo "Could not chmod of $COMM_STATUS_DIR." >&2
	fail
fi

#Move agent and config file to installation directory
[ $DEBUG_OUTPUT ] && echo "Installing agent"
if [ -s $AGENT_FILE ]; then
	:
elif [ -s installer/$AGENT_FILE ]; then
	mv installer/$AGENT_FILE .
	mv installer/uninstall.sh .
else
	>&2 echo "Cannot find agent file."
	fail
fi

[ $DEBUG_OUTPUT ] && echo "Copying agent binary from $PWD to $INSTALL_DIR"
if ! cp $AGENT_FILE $INSTALL_DIR/$AGENT_FILE >/dev/null 2>&1; then
	>&2 echo "Error installing agent. If an agent is already installed, run again with -c to perform a clean installation."
	fail
fi
chmod 0744 $INSTALL_DIR/$AGENT_FILE

if [ $XTHUB_AGENT ]; then
	#XTHub requires a valid FQDN for the device to generate a certificate
	if ! checkHostnames; then
		>&2 echo "Cannot find a valid FQDN for the device. XTremeHub enrollment will likely fail. Continue?[Y/N]"
		[ $AUTOACCEPT_PROMPTS ] || ! getUserResponse && fail
	fi
	#If agent is installing to PWD, the files are already where they need to be
	INSTALLER_DIR="."
	if [ $TARFILEEXISTENCE ]; then
		INSTALLER_DIR="installer"
	fi
	[ $DEBUG_OUTPUT ] && echo "Copying XTremeHub library."
	if ! cp -r $INSTALLER_DIR/xthub $INSTALL_DIR; then
		>&2 echo "Error copying XTremeHub library. Aborting."
		fail
	fi
	if [ ! $SYSTEM_DOTNET ]; then
		installLocalDotNet $INSTALL_DIR
	else
		[ $DEBUG_OUTPUT ] && echo "Use of system .NET specified, skipping .NET installation."
	fi
fi

[ $DEBUG_OUTPUT ] && echo "Installing config file."
if [ -s $CONFIG_FILE ]; then
	[ $DEBUG_OUTPUT ] && echo "Copying config file from $PWD to $INSTALL_DIR"
	#File has carriage returns when downloaded from server. This removes them. Printf is required since busybox sed doesnt read the escape properly.
	sed -i "s/$(printf '\r')\$//" $CONFIG_FILE
	if ! cp $CONFIG_FILE $INSTALL_DIR/pdb.ini >/dev/null 2>&1; then
		>&2 echo "Error installing config file. If an agent is already installed, run again with -c to perform a clean installation."
		fail
	fi
else
	>&2 echo "Cannot find config file."
	fail
fi
chmod 0700 $INSTALL_DIR/pdb.ini

[ $DEBUG_OUTPUT ] && echo "Detecting init system."
if [ -d /run/systemd/system ]; then
	INITSYSTEM=systemd
elif /sbin/init --version 2>/dev/null | grep "upstart"; then
	INITSYSTEM=upstart
elif [ -L /sbin/init ] && [ -d /etc/rc.d ]; then
	INITSYSTEM=busybox
elif [ -d /etc/init.d ]; then
	INITSYSTEM=sysvinit
else
	>&2 echo "Unrecognized init system."
	fail
fi
[ $DEBUG_OUTPUT ] && echo "Detected $INITSYSTEM"


case $INITSYSTEM in
	systemd)
		if [ $TARFILEEXISTENCE ]; then
			if [ ! -s installer/$SYSTEMD_FILE ]; then
				>&2 echo "systemd service file not found."
				fail
			fi
			[ $DEBUG_OUTPUT ] && echo "Installing agent service."
			if ! cp installer/$SYSTEMD_FILE /etc/systemd/system >/dev/null 2>&1; then
				>&2 echo "Could not copy installer/$SYSTEMD_FILE to /etc/systemd/system"
				fail
			fi
		else
			if [ ! -s $SYSTEMD_FILE ]; then
				>&2 echo "systemd service file not found."
				fail
			fi
			[ $DEBUG_OUTPUT ] && echo "Installing agent service."
			if ! cp $SYSTEMD_FILE /etc/systemd/system >/dev/null 2>&1; then
				>&2 echo "Could not copy $SYSTEMD_FILE to /etc/systemd/system"
				fail
			fi
		fi
		[ $DEBUG_OUTPUT ] && echo "Registering agent service."
		systemctl daemon-reload
		systemctl enable mobicontrol
		[ $DEBUG_OUTPUT ] && echo "Starting agent service."
		systemctl start mobicontrol >/dev/null 2>&1
		;;
	upstart)
		if [ $TARFILEEXISTENCE ]; then
			if [ ! -s installer/$UPSTART_FILE ]; then
				>&2 echo "upstart service file not found."
				fail
			fi
			[ $DEBUG_OUTPUT ] && echo "Installing agent service."
			if ! cp installer/$UPSTART_FILE /etc/init >/dev/null 2>&1; then
				>&2 echo "Could not copy installer/$UPSTART_FILE to /etc/init"
				fail
			fi
		else
			if [ ! -s $UPSTART_FILE ]; then
				>&2 echo "upstart service file not found."
				fail
			fi
			[ $DEBUG_OUTPUT ] && echo "Installing agent service."
			if ! cp $UPSTART_FILE /etc/init >/dev/null 2>&1; then
				>&2 echo "Could not copy $UPSTART_FILE to /etc/init"
				fail
			fi
		fi
		[ $DEBUG_OUTPUT ] && echo "Starting agent service."
		initctl start mobicontrol >/dev/null 2>&1
		;;
	busybox)
		if [ $TARFILEEXISTENCE ]; then
			if [ ! -s installer/$INITD_FILE ]; then
				>&2 echo "init.d service file not found."
				fail
			fi
			[ $DEBUG_OUTPUT ] && echo "Installing agent service."
			chmod 0755 installer/$INITD_FILE
			chown root:root installer/$INITD_FILE
			if ! cp installer/$INITD_FILE /etc/init.d/ >/dev/null 2>&1; then
				>&2 echo "Could not copy installer/$INITD_FILE to /etc/init.d/"
				fail
			fi
		else
			if [ ! -s $INITD_FILE ]; then
				>&2 echo "init.d service file not found."
				fail
			fi
			[ $DEBUG_OUTPUT ] && echo "Installing agent service."
			chmod 0755 $INITD_FILE
			chown root:root $INITD_FILE
			if ! cp $INITD_FILE /etc/init.d/ >/dev/null 2>&1; then
				>&2 echo "Could not copy $INITD_FILE to /etc/init.d/"
				fail
			fi
		fi
		[ $DEBUG_OUTPUT ] && echo "Registering agent service."
		if ! ln -fs /etc/init.d/mobicontrol /etc/rc.d/S99mobicontrol; then #no runlevels at busybox init
			>&2 echo "Could not symlink /etc/init.d/mobicontrol to /etc/rc.d/S99mobicontrol"
			fail
		fi
		[ $DEBUG_OUTPUT ] && echo "Starting agent service."
		/etc/init.d/mobicontrol start >/dev/null 2>&1
		;;
	sysvinit)
		if [ $TARFILEEXISTENCE ]; then
			if [ ! -s installer/$INITD_FILE ]; then
				>&2 echo "init.d service file not found."
				fail
			fi
			[ $DEBUG_OUTPUT ] && echo "Installing agent service."
			chmod 0755 installer/$INITD_FILE
			chown root:root installer/$INITD_FILE
			if ! cp installer/$INITD_FILE /etc/init.d/ >/dev/null 2>&1; then
				>&2 echo "Could not copy installer/$INITD_FILE to /etc/init.d/"
				fail
			fi
		else
			if [ ! -s $INITD_FILE ]; then
				>&2 echo "init.d service file not found."
				fail
			fi
			[ $DEBUG_OUTPUT ] && echo "Installing agent service."
			chmod 0755 $INITD_FILE
			chown root:root $INITD_FILE
			if ! cp $INITD_FILE /etc/init.d/ >/dev/null 2>&1; then
				>&2 echo "Could not copy $INITD_FILE to /etc/init.d/"
				fail
			fi
		fi
		[ $DEBUG_OUTPUT ] && echo "Registering agent service."
		if ! ln -fs /etc/init.d/mobicontrol /etc/rc3.d/S99mobicontrol; then #no runlevels at busybox init
			>&2 echo "Could not symlink /etc/init.d/mobicontrol to /etc/rc.d/S99mobicontrol"
			fail
		fi
		[ $DEBUG_OUTPUT ] && echo "Starting agent service."
		/etc/init.d/mobicontrol start >/dev/null 2>&1
		;;
esac
#Test connection to server
pass

