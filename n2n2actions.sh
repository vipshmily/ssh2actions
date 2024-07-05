#!/usr/bin/env bash
#
# Copyright (c) 2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/ssh2actions
# File name：ngrok2actions.sh
# Description: Connect to Github Actions VM via SSH by using n2n
# Version: 2.0
#

Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Green_background_prefix="\033[42;37m"
Red_background_prefix="\033[41;37m"
Font_color_suffix="\033[0m"
INFO="[${Green_font_prefix}INFO${Font_color_suffix}]"
ERROR="[${Red_font_prefix}ERROR${Font_color_suffix}]"
LOG_FILE='/tmp/n2n.log'
ERR_FILE='/tmp/n2n.err'
TELEGRAM_LOG="/tmp/telegram.log"
CONTINUE_FILE="/tmp/continue"

# Check secret - n2n token
if [[ -z "${N2N_ARG}" ]]; then
    echo -e "${N2N_ARG} Please set 'N2N_ARG' environment variable."
    exit 2
fi

# Change user pass
if [[ -z "${SSH_PASSWORD}" ]]; then
    echo -e "${ERROR} Please set 'SSH_PASSWORD' environment variable."
    exit 3
else
    echo -e "${INFO} Set user(${USER}) password ..."
    echo -e "${SSH_PASSWORD}\n${SSH_PASSWORD}" | sudo passwd "${USER}"
fi

# Install n2n
if [[ -n "$(uname | grep -i Linux)" ]]; then
    echo -e "${INFO} Install n2n ..."
    wget https://github.com/ntop/n2n/releases/download/3.1.1/n2n_3.1.1_amd64.deb
    sudo -E dpkg -i n2n_3.1.1_amd64.deb
    edge -h
elif [[ -n "$(uname | grep -i Darwin)" ]]; then
    echo -e "${INFO} Install n2n ..."
    echo -e "${INFO} n2n installion on MacOS is not tested yest, may failed..."
    wget https://github.com/ntop/n2n/releases/download/3.1.1/n2n_3.1.1_amd64.deb
    sudo -E dpkg -i n2n_3.1.1_amd64.deb
    edge -h
    USER=root
    echo -e "${INFO} Set SSH service ..."
    echo 'PermitRootLogin yes' | sudo tee -a /etc/ssh/sshd_config >/dev/null
    sudo launchctl unload /System/Library/LaunchDaemons/ssh.plist
    sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist
else
    echo -e "${ERROR} This system is not supported!"
    exit 1
fi

# Start n2n tcp tunnel to port 22
random_id=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)
echo -e "${INFO} Starting n2n edgenode, with random ID $random_id..."
sudo edge -d edge0 -r -I $random_id $N2N_ARG 2>${ERR_FILE} | sed '/supernode/d' | tee ${LOG_FILE}

# Wait till online
echo -e "${INFO} Wait for DHCP finish.."
echo -e "${INFO} Please allow up to 10s ..."
while ((${SECONDS_LEFT:=10} > 0)); do
    grep -q 'created local tap device IP' ${LOG_FILE} && break

    echo -e "${INFO} Please wait ${SECONDS_LEFT}s ..."
    sleep 1
    SECONDS_LEFT=$((${SECONDS_LEFT} - 1))
done

# Get connection info
if [[ -n `grep 'created local tap device IP' ${LOG_FILE}` ]]; then
    ipaddress=$(ip -o -4 addr show dev edge0 | awk '{split($4,a,"/"); print a[1]}')
    SSH_CMD="ssh runner@$ipaddress"
else
    echo -e "${ERROR} Fail initializing n2n edge"
    cat ${ERR_FILE}
    exit 4
fi

# Send connection info to Telegram
MSG="
*GitHub Actions - n2n session info:*

⚡ *CLI:*
\`${SSH_CMD}\`

🔔 *TIPS:*
Run '\`touch ${CONTINUE_FILE}\`' to continue to the next step.
"
if [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    echo -e "${INFO} Sending message to Telegram..."
    curl -sSX POST "${TELEGRAM_API_URL:-https://api.telegram.org}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=Markdown" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${MSG}" >${TELEGRAM_LOG}
    TELEGRAM_STATUS=$(cat ${TELEGRAM_LOG} | jq -r .ok)
    if [[ ${TELEGRAM_STATUS} != true ]]; then
        echo -e "${ERROR} Telegram message sending failed: $(cat ${TELEGRAM_LOG})"
    else
        echo -e "${INFO} Telegram message sent successfully!"
    fi
fi

print_info(){
    echo "------------------------------------------------------------------------"
    echo "To connect to this session copy and paste the following into a terminal:"
    echo -e "${Green_font_prefix}$SSH_CMD${Font_color_suffix}"
    echo -e "TIPS: Run 'touch ${CONTINUE_FILE}' to continue to the next step.(ignore in background mode)"
    echo "------------------------------------------------------------------------"
}

# Keepalive(Foreground) or Background
if [[ ${IN_BACKGROUND} != true ]]; then
    # Print connection info
    while ((${PRT_COUNT:=1} <= ${PRT_TOTAL:=10})); do
        SECONDS_LEFT=${PRT_INTERVAL_SEC:=10}
        while ((${PRT_COUNT} > 1)) && ((${SECONDS_LEFT} > 0)); do
            echo -e "${INFO} (${PRT_COUNT}/${PRT_TOTAL}) Please wait ${SECONDS_LEFT}s ..."
            sleep 1
            SECONDS_LEFT=$((${SECONDS_LEFT} - 1))
        done
        print_info
        PRT_COUNT=$((${PRT_COUNT} + 1))
    done

    # Check continue
    while [[ -n $(pgrep n2n) ]]; do
        sleep 1
        if [[ -e ${CONTINUE_FILE} ]]; then
            echo -e "${INFO} Continue to the next step."
            exit 0
        fi
    done
else
    print_info
    echo -e "${INFO} Connection info will be written in /tmp/conn.inf"
    # Write connection info to file
    cat >> /tmp/conn.inf << EOF
[$(date +"%c")]
n2n edge's UP now!
CLI: ${SSH_CMD}
EOF
    echo -e "${INFO} Continue to the next step."
    exit 0
fi