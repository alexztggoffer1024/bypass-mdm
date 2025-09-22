#!/bin/bash

# Define color codes
RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
PUR='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

# Debug and logging helpers
DEBUG="${BYPASS_DEBUG:-0}"
log_info() { echo -e "${BLU}[INFO]${NC} $1"; }
log_ok() { echo -e "${GRN}[OK]${NC} $1"; }
log_warn() { echo -e "${YEL}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERR]${NC} $1"; }
if [ "$DEBUG" = "1" ]; then
    PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
    set -x
fi

# Function to get the system volume name (as shown under /Volumes)
get_system_volume() {
    system_volume=$(diskutil info / | awk -F': *' '/Volume Name/ {print $2; exit}')
    echo "$system_volume"
}

# Function to get the corresponding Data volume path without renaming
get_data_volume_path() {
    local sysvol="$1"
    local datavol="/Volumes/${sysvol} - Data"
    if [ -d "$datavol" ]; then
        echo "$datavol"
    elif [ -d "/Volumes/Data" ]; then
        echo "/Volumes/Data"
    else
        echo "" 
    fi
}

# Try to auto-discover a mounted system Data volume by presence of dslocal
find_data_volume_candidate() {
    local candidates=()
    for v in /Volumes/*; do
        if [ -d "$v/private/var/db/dslocal/nodes/Default" ]; then
            candidates+=("$v")
        fi
    done
    if [ ${#candidates[@]} -eq 1 ]; then
        echo "${candidates[0]}"
        return
    fi
    # Prefer volumes whose name ends with " - Data"
    for v in "${candidates[@]}"; do
        case "$(basename "$v")" in
            *" - Data") echo "$v"; return ;;
        esac
    done
    if [ ${#candidates[@]} -gt 0 ]; then
        echo "${candidates[0]}"
        return
    fi
    echo ""
}

# Ensure the chosen Data volume is writable; try unlocking if needed
ensure_writable_data_volume() {
    local path="$1"
    if touch "$path/.bypass_mdm_write_test" >/dev/null 2>&1; then
        rm -f "$path/.bypass_mdm_write_test"
        echo "$path"
        return 0
    fi
    local dev_id
    dev_id=$(diskutil info "$path" 2>/dev/null | awk -F': *' '/Device Identifier/ {print $2; exit}')
    if [ -n "$dev_id" ]; then
        echo -n "Volume appears locked or read-only. Enter FileVault passphrase to unlock (leave empty to skip): "
        read -r -s fvpass
        echo ""
        if [ -n "$fvpass" ]; then
            if diskutil apfs unlockVolume "$dev_id" -passphrase "$fvpass" >/dev/null 2>&1; then
                if touch "$path/.bypass_mdm_write_test" >/dev/null 2>&1; then
                    rm -f "$path/.bypass_mdm_write_test"
                    echo "$path"
                    return 0
                fi
            fi
        fi
    fi
    echo ""
    return 1
}

# Get the system volume name
system_volume=$(get_system_volume)
log_info "Detected system volume: $system_volume"

# Display header
echo -e "${CYAN}Bypass MDM By Assaf Dori (assafdori.com)${NC}"
echo ""

# Prompt user for choice
PS3='Please enter your choice: '
options=("Bypass MDM from Recovery" "Reboot & Exit")
select opt in "${options[@]}"; do
    case $opt in
        "Bypass MDM from Recovery")
            # Bypass MDM from Recovery
            echo -e "${YEL}Bypass MDM from Recovery"
            data_volume_path=$(find_data_volume_candidate)
            if [ -z "$data_volume_path" ]; then
                data_volume_path=$(get_data_volume_path "$system_volume")
            fi
			log_info "Candidate Data volume path: ${data_volume_path:-<none>}"
            if [ -z "$data_volume_path" ]; then
                echo -e "${RED}Could not locate Data volume for '$system_volume'. Ensure the target disk is mounted.${NC}"
                break
            fi
            # Validate this is a target system Data volume and it is writable
            if [ ! -d "$data_volume_path/private/var/db/dslocal/nodes/Default" ]; then
                echo -e "${RED}$data_volume_path does not look like a macOS system Data volume (dslocal missing). Mount the installed system's Data volume (e.g., 'Macintosh HD - Data') and try again.${NC}"
                break
            fi
            writable_path=$(ensure_writable_data_volume "$data_volume_path")
            if [ -z "$writable_path" ]; then
                echo -e "${RED}$data_volume_path is not writable. Unlock or mount as read-write, then rerun.${NC}"
                break
            fi
			log_ok "Using Data volume: $data_volume_path"

            # Create Temporary User
            echo -e "${NC}Create a Temporary User"
            read -p "Enter Temporary Fullname (Default is 'Apple'): " realName
            realName="${realName:=Apple}"
            read -p "Enter Temporary Username (Default is 'Apple'): " username
            username="${username:=Apple}"
            read -p "Enter Temporary Password (Default is '1234'): " passw
            passw="${passw:=1234}"

			# Create User
            dscl_path="$data_volume_path/private/var/db/dslocal/nodes/Default"
			log_info "dscl path: $dscl_path"
            # Ensure username does not already exist; if it does, append a numeric suffix
            if dscl -f "$dscl_path" localhost -read "/Local/Default/Users/$username" >/dev/null 2>&1; then
                base_username="$username"
                suffix=1
                while dscl -f "$dscl_path" localhost -read "/Local/Default/Users/$username" >/dev/null 2>&1; do
                    username="${base_username}${suffix}"
                    suffix=$((suffix+1))
                done
                echo -e "${YEL}Username exists. Using '$username' instead.${NC}"
            fi

            # Find an available UniqueID starting at 501
            existing_uids=$(dscl -f "$dscl_path" localhost -list "/Local/Default/Users" UniqueID 2>/dev/null | awk '{print $2}')
            target_uid=501
            if [ -n "$existing_uids" ]; then
                while echo "$existing_uids" | grep -qx "$target_uid"; do
                    target_uid=$((target_uid+1))
                done
            fi
			echo -e "${GREEN}Creating Temporary User"
            dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username"
            # Assign RecordName and GeneratedUID so the user is properly recognized by loginwindow
            dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" RecordName "$username"
            generated_guid=$(uuidgen)
            dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" GeneratedUID "$generated_guid"
            dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" UserShell "/bin/zsh"
            dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" RealName "$realName"
            dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" UniqueID "$target_uid"
            dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" PrimaryGroupID "20"
			log_info "username=$username realName=$realName uid=$target_uid guid=$generated_guid"
            mkdir -p "$data_volume_path/Users/$username"
            dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" NFSHomeDirectory "/Users/$username"
            dscl -f "$dscl_path" localhost -passwd "/Local/Default/Users/$username" "$passw"
            # Add to admin both by short name and GUID to satisfy different membership checks
            dscl -f "$dscl_path" localhost -append "/Local/Default/Groups/admin" GroupMembership "$username"
            dscl -f "$dscl_path" localhost -append "/Local/Default/Groups/admin" GroupMembers "$generated_guid"
            # Ensure home directory ownership is correct
            chown -R "$target_uid:20" "$data_volume_path/Users/$username"

			# Block MDM domains on target Data volume
            hosts_file="$data_volume_path/etc/hosts"
            if [ ! -f "$hosts_file" ] && [ -f "$data_volume_path/private/etc/hosts" ]; then
                hosts_file="$data_volume_path/private/etc/hosts"
            fi
			log_info "Using hosts file: ${hosts_file:-<none>}"
            if [ -f "$hosts_file" ]; then
                echo "0.0.0.0 deviceenrollment.apple.com" >>"$hosts_file"
                echo "0.0.0.0 mdmenrollment.apple.com" >>"$hosts_file"
                echo "0.0.0.0 iprofiles.apple.com" >>"$hosts_file"
                echo -e "${GRN}Successfully blocked MDM & Profile Domains"
            else
                echo -e "${YEL}Hosts file not found under $data_volume_path; skipping domain block${NC}"
            fi

            # Remove configuration profiles on target Data volume
            touch "$data_volume_path/private/var/db/.AppleSetupDone"
            rm -rf "$data_volume_path/var/db/ConfigurationProfiles/Settings/.cloudConfigHasActivationRecord"
            rm -rf "$data_volume_path/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound"
            touch "$data_volume_path/var/db/ConfigurationProfiles/Settings/.cloudConfigProfileInstalled"
            touch "$data_volume_path/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound"

            echo -e "${GRN}MDM enrollment has been bypassed!${NC}"
            echo -e "${NC}Exit terminal and reboot your Mac.${NC}"
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
