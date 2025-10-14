#!/bin/sh

errorHandling() {
    if [ $1 -eq 1 ]; then
        echo "Agent could not be unenrolled because the script is not running as root"
        exit 1
    elif [ $1 -eq 2 ]; then
        echo "Agent could not be unenrolled due to the failure of deleting file(s)"
        exit 2
    elif [ $1 -eq 3 ]; then
        echo "Agent could not be unenrolled due to the failure of reverting USB rule states"
        echo "Agent could not be unenrolled due to the failure of reverting USB rule states"
        exit 3
    elif [ $1 -eq 4 ]; then
        echo "Agent could not be unenrolled due to the failure of reverting the Wifi settings"
        exit 4
    elif [ $1 -eq 5 ]; then
        echo "Agent could not be unenrolled due to the failure of killing Restart.sh"
        exit 5
    elif [ $1 -eq 6 ]; then
        echo "Agent could not be unenrolled due to the failure of killing mobicontrol"
        exit 6
    elif [ $1 -eq 7 ]; then
        echo "Agent could not be unenrolled due to the failure of unblocking applications from ARC list"
        exit 7
    else
        : # default case
    fi
}

removeFileWithErrorChecking() {
    rm -rf $1 >/dev/null 2>&1
    rmRet=$?
    if [ $rmRet -ne 0 ]; then
        errorHandling 2
    fi
}

checkRootPrivilege(){
    ID=$(id -u 2>/dev/null)
    if [ -z "$ID" ] ;then
        ID=$(ps -o euid= -p $$ | awk '{print $1}')
    fi

    if [ "$ID" != "0" ]; then
        errorHandling 1
    fi
}

USBRulesUninstall(){
    if [  -f  /etc/udev/rules.d/mobicontrol-usb.rules ]; then
        removeFileWithErrorChecking "/etc/udev/rules.d/mobicontrol-usb.rules"

        if [  -f  /etc/udev/rules.d/69-libmtp.rules ]; then
            removeFileWithErrorChecking "/etc/udev/rules.d/69-libmtp.rules"
            removeFileWithErrorChecking "/lib/udev/check_gui_user_group.sh"
        fi
        udevadm control --reload-rules && udevadm trigger 2>/dev/null
        udevadmRet=$?
        if [ $udevadmRet -ne 0 ]; then
            errorHandling 3
        fi
    fi
    if [  -f  /usr/local/bin/mobicontrol-usb-rules.sh ]; then
        removeFileWithErrorChecking "/usr/local/bin/mobicontrol-usb-rules.sh"
    fi
}

killAgentMonitor () {
    pkill -9 Restart.sh >/dev/null 2>&1
    pkill -f Restart.sh >/dev/null 2>&1
    PID=$(ps -e | grep Restart.sh|awk '{print$1}')
    if kill -0 $PID >/dev/null 2>&1; then
        kill -9 $PID >/dev/null 2>&1
        killRet=$?
        if [ $killRet -ne 0 ]; then
            errorHandling 5
        fi
    else
        : # echo "Restart.sh has been stopped"
    fi
}

killRunningMobicontrol () {
    pkill -f mobicontrol >/dev/null 2>&1
    if command -v pidof >/dev/null; then
        PID=$(pidof mobicontrol)
    else
        PID=$(ps -e | grep mobicontrol|awk '{print$1}')
    fi
    if kill -0 $PID >/dev/null 2>&1; then
        kill -9 $PID >/dev/null 2>&1
        killRet=$?
        if [ $killRet -ne 0 ]; then
            errorHandling 6
        fi
    else
        : #echo "mobicontrol has been stopped"
    fi
}

StopAndDeleteServices (){
 systemctl stop mobicontrol >/dev/null 2>&1 || initctl stop mobicontrol >/dev/null 2>&1 || /etc/init.d/mobicontrol stop >/dev/null 2>&1
 removeFileWithErrorChecking "/etc/systemd/system/mobicontrol.service"
 removeFileWithErrorChecking "/etc/systemd/system/mobicontrol"
 removeFileWithErrorChecking "/etc/init.d/mobicontrol"
 removeFileWithErrorChecking "/etc/init/mobicontrol"
}

WebContentFilterRulesUninstall(){
iptables -D OUTPUT -p tcp --dport 80 -j mobicontrolchain 2>/dev/null;iptables -D OUTPUT -p tcp --dport 443 -j mobicontrolchain 2>/dev/null;iptables -D OUTPUT -p udp --dport 80 -j mobicontrolchain 2>/dev/null;iptables -D OUTPUT -p udp --dport 443 -j mobicontrolchain 2>/dev/null;iptables -F mobicontrolchain 2>/dev/null;iptables -X mobicontrolchain 2>/dev/null
ip6tables -D OUTPUT -p tcp --dport 80 -j mobicontrolchain 2>/dev/null;ip6tables -D OUTPUT -p tcp --dport 443 -j mobicontrolchain 2>/dev/null;ip6tables -D OUTPUT -p udp --dport 80 -j mobicontrolchain 2>/dev/null;ip6tables -D OUTPUT -p udp --dport 443 -j mobicontrolchain 2>/dev/null;ip6tables -F mobicontrolchain 2>/dev/null;ip6tables -X mobicontrolchain 2>/dev/null
}

WifiSetting() {
    if [ -f /usr/opt/MobiControl/WifiSetting/ConnectedWifiName/WifiName ] || [ -f $PWD/WifiSetting/ConnectedWifiName/WifiName ]; then
        if [ -f /usr/opt/MobiControl/WifiSetting/ConnectedWifiName/WifiName ]; then
           wifi=/usr/opt/MobiControl/WifiSetting/ConnectedWifiName/WifiName
        else
           wifi=$PWD/WifiSetting/ConnectedWifiName/WifiName
        fi

    while read line
            do
               removeFileWithErrorChecking "/etc/NetworkManager/system-connections/$line"
               removeFileWithErrorChecking "/etc/sysconfig/network-scripts/keys-$line"
               removeFileWithErrorChecking "/etc/sysconfig/network-scripts/ifcfg-$line"
               if [ -f /etc/wpa_supplicant/wpa_supplicant.conf_Original ]; then
                 sleep 1
                 sed -i "s/$line//g" /etc/wpa_supplicant/wpa_supplicant.conf >/dev/null 2>&1
               fi
            done < $wifi
        if [ -f  /etc/init.d/dhcpcd ]; then
            (systemctl restart NetworkManager.service >/dev/null 2>&1;service network-manager restart >/dev/null 2>&1) ; /etc/init.d/dhcpcd restart >/dev/null 2>&1
        else
            (systemctl restart NetworkManager.service >/dev/null 2>&1;service network-manager restart >/dev/null 2>&1)
        fi
        networkRestartRet=$?
        if [ $networkRestartRet -ne 0 ]; then
            errorHandling 4
        fi
    fi
}

unblockAppsFromARCList() {
    input="/usr/opt/MobiControl/pdb.ini"
    count=0
    prefix="PRC"
    appIndex="${prefix}${count}"

    while IFS= read -r line
    do
        case $line in
            "$appIndex"*)
                appName=$(echo "$line" | cut -d "=" -f2)
                fullDir=$(which $appName)
                chmod go+x $fullDir $1 >/dev/null 2>&1
                chmodRet=$?
                if [ $chmodRet -ne 0 ]; then
                    errorHandling 7
                fi
                count=$(( count + 1 ))
                appIndex="${prefix}${count}"
                ;;
        esac
    done < "$input"
}

#Check if running the script with root
checkRootPrivilege

echo "q" >/tmp/uninstall_status.txt >/dev/null 2>&1
chmod 777 /tmp/uninstall_status.txt >/dev/null 2>&1

if [  -f  /etc/systemd/system/mobicontrol.service ]; then
    systemctl stop mobicontrol.service 2>/dev/null
fi

#Revert Wifi Profile Setting changes
WifiSetting

#USB rules uninstallation
USBRulesUninstall

#WebContentFilter rules uninstallation
WebContentFilterRulesUninstall

killAgentMonitor

killRunningMobicontrol

StopAndDeleteServices

#Unblock applications from ARC list
unblockAppsFromARCList

removeFileWithErrorChecking "/tmp/AllowOFC"
removeFileWithErrorChecking "/tmp/pipo"
removeFileWithErrorChecking "/usr/opt/MobiControl"
removeFileWithErrorChecking "/tmp/mobicontrol_status"
removeFileWithErrorChecking "/var/log/PkCtrlSv.log"
removeFileWithErrorChecking "/var/log/XTAgent.log"
#echo "Delete all mobicontrol files in system successfully"

echo >/tmp/uninstall_status.txt
mv pdb.ini MCSetup.ini >/dev/null 2>&1
RELEASE_NAME=$(lsb_release -r >/dev/null 2>&1|awk -F '[:]' '{print$2}' >/dev/null 2>&1)
if [ "${RELEASE_NAME}" = "12.04" ] || [ "${RELEASE_NAME}" = "14.04" ] ;then
    MOBICONTROLPID=$(ps -ef >/dev/null 2>&1|grep mobicontrol >/dev/null 2>&1| awk -F ' ' '{print$2}' >/dev/null 2>&1)
    if kill -0 $MOBICONTROLPID >/dev/null 2>&1; then
        kill -9 $MOBICONTROLPID >/dev/null 2>&1
        killRet=$?
        if [ $killRet -ne 0 ]; then
            errorHandling 6
        fi
    else
        : #echo "mobicontrol has been stopped"
    fi
fi

echo "Agent has been uninstalled"
