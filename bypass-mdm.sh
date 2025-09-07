#!/bin/bash

# Define color codes
RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
PUR='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

#rootVolume=$(diskutil info / | awk -F: '/Volume Name:/{print $2}' | sed 's/^ *//')
#if [ "$rootVolume" = "macOS Base System" ]; then
#	dataVolume=$(ls -1 /Volumes | grep ' - Data$')
#fi

dataVolume=$(ls -1 /Volumes | grep ' - Data$')
rootVolume=${dataVolume% - Data}
rootVolumeMnt="/Volumes/$rootVolume"
dataVolumeMnt="/Volumes/$dataVolume"
sysconfdir="/var/db/ConfigurationProfiles/Settings"
confdir="$rootVolumeMnt$sysconfdir"

# Display header
echo -e "${CYAN}Bypass MDM By Assaf Dori (assafdori.com)${NC}\n"

# Prompt user for choice
PS3='Please enter your choice: '
options=("Bypass MDM from Recovery" "Reboot & Exit")
select opt in "${options[@]}"; do
	case $opt in
	"Bypass MDM from Recovery")
		# Bypass MDM from Recovery
		echo -e "${YEL}Bypass MDM from Recovery"

		# Create Temporary User
		echo -e "${NC}Create a Temporary User"
		read -p "Enter Temporary Fullname (Default is 'Apple'): " realName
		realName="${realName:=Apple}"
		read -p "Enter Temporary Username (Default is 'Apple'): " username
		username="${username:=Apple}"
		read -p "Enter Temporary Password (Default is '1234'): " passw
		passw="${passw:=1234}"

		# Create User
		dscl_path="${dataVolumeMnt}/private/var/db/dslocal/nodes/Default"
		user_path=/Local/Default/Users
		group_path=/Local/Default/Groups
		echo -e "${GREEN}Creating Temporary User"
		dscl -f "$dscl_path" localhost -create "$user_path/$username"
		dscl -f "$dscl_path" localhost -create "$user_path/$username" UserShell "/bin/zsh"
		dscl -f "$dscl_path" localhost -create "$user_path/$username" RealName "$realName"
		dscl -f "$dscl_path" localhost -create "$user_path/$username" UniqueID "501"
		dscl -f "$dscl_path" localhost -create "$user_path/$username" PrimaryGroupID "20"
		mkdir "${dataVolumeMnt}/Users/$username"
		dscl -f "$dscl_path" localhost -create "$user_path/$username" NFSHomeDirectory "/Users/$username"
		dscl -f "$dscl_path" localhost -passwd "$user_path/$username" "$passw"
		dscl -f "$dscl_path" localhost -append "$group_path/admin" GroupMembership $username

		# Block MDM domains
		hostsfile="$rootVolumeMnt/etc/hosts"
		echo -e "0.0.0.0 deviceenrollment.apple.com\n0.0.0.0 mdmenrollment.apple.com\n0.0.0.0 iprofiles.apple.com" >>"$hostsfile"
		echo -e "${GRN}Successfully blocked MDM & Profile Domains"

		# Remove configuration profiles
		touch "${dataVolumeMnt}/private/var/db/.AppleSetupDone"
		rm -rf "$confdir/.cloudConfigHasActivationRecord" "$confdir/.cloudConfigRecordFound"
		touch "$confdir/.cloudConfigProfileInstalled" "$confdir/.cloudConfigRecordNotFound"

		echo -e "${GRN}MDM enrollment has been bypassed!${NC}"
		echo -e "${NC}Exit terminal and reboot your Mac.${NC}"
		break
		;;
	"Disable Notification (SIP)")
		# Disable Notification (SIP)
		echo -e "${RED}Please Insert Your Password To Proceed${NC}"
		sudo rm -rf $sysconfdir/.cloudConfigHasActivationRecord $sysconfdir/.cloudConfigRecordFound
		sudo touch $sysconfdir/.cloudConfigProfileInstalled $sysconfdir/.cloudConfigRecordNotFound
		break
		;;
	"Disable Notification (Recovery)")
		# Disable Notification (Recovery)
		rm -rf "$confdir/.cloudConfigHasActivationRecord" "$confdir/.cloudConfigRecordFound"
		touch "$confdir/.cloudConfigProfileInstalled" "$confdir/.cloudConfigRecordNotFound"
		break
		;;
	"Check MDM Enrollment")
		# Check MDM Enrollment
		echo -e "\n${GRN}Check MDM Enrollment. Error is success${NC}"
		echo -e "\n${RED}Please Insert Your Password To Proceed${NC}"
		echo ""
		sudo profiles show -type enrollment
		break
		;;
	"Reboot & Exit")
		# Reboot & Exit
		echo "Rebooting..."
		reboot
		break
		;;
	*) echo "Invalid option $REPLY" ;;
	esac
done
