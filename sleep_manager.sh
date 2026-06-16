#!/bin/bash

# need to know
# macos rely on EC.RTC for almost every maintenance task. there's only so much i can do.

# Configuration
IDLE_TIME_SEC=900            # idle_time
TIME_RESOLUTION=60           # time_resolution
THRESHOLD_PERCENT=15         # threshold (battery drop % during sleep to trigger hibernate)
LOW_BATTERY_THRESHOLD=20     # low_battery_threshold
# TODO: add time threshold on battery
THRESHOLD_RESPONSE="hibernate" # threshold_response (hibernate or sleep)
PERMISSION="tty"             # permission {none, tty} - prevent sleep if active tty/ssh exists
is_tcp_keepalive=false
# darkwake, sched related
is_calaccessd_allowed=true          # necessary for calendar time to leave. unless you don't use icalendar.
is_analytics_allowed=false
## extra
is_lessbright_allowed=false
# Internal State Variables
STATE="awake"
BATTERY_AT_SLEEP=100

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}
get_idle_time() {
    echo $(( $(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF; exit}') / 1000000000 ))
}
# use ioreg to avoid stale data
get_battery_level() {
    # Try raw SMC read first
    local cap=$(ioreg -r -n AppleSmartBattery | awk '/CurrentCapacity/{print $NF; exit}')
    local max=$(ioreg -r -n AppleSmartBattery | awk '/MaxCapacity/{print $NF; exit}')
    if [[ -n "$cap" && -n "$max" && "$max" -gt 0 ]]; then
        echo $(( cap * 100 / max ))
    else
        echo ""
    fi
}
is_on_ac() {
    pmset -g batt | grep -q "AC Power"
    return $?
}
is_display_asleep() {
    # State 4 = on, anything less = dimmed/off/asleep
    ! ioreg -n IODisplayWrangler | grep -i IOPowerManagement | grep -q 'CurrentPowerState"=4'
}
# prevent sleep collision with full wake transition
is_full_wake() {
    # Graphics capability. Full wake is [CDNVA], darkwake is [CDN] (no V/A).
    # Set when the kernel commits to the wake, before the panel lits up
    pmset -g systemstate 2>/dev/null \
        | awk -F: '/System Capabilities/{print $2}' | grep -q "Graphics" && return 0
    pmset -g assertions 2>/dev/null \
        | grep -qE '^[[:space:]]*UserIsActive[[:space:]]+1' && return 0
    ! is_display_asleep && return 0
    return 1
}
has_active_tty() {
    if [[ "$PERMISSION" == "tty" ]]; then
        # Only count SSH sessions, not local terminal windows
        ACTIVE_TTYS=$(who | grep -v "console" | grep -v "ttys" | wc -l)
        if [[ "$ACTIVE_TTYS" -gt 0 ]]; then
            return 0
        fi
        # Also check for active SSH processes directly
        if pgrep -x sshd > /dev/null 2>&1; then
            SSH_SESSIONS=$(ss -tnp 2>/dev/null | grep -c ":22" || netstat -an | grep "\.22 " | grep -c ESTABLISHED)
            if [[ "$SSH_SESSIONS" -gt 0 ]]; then
                return 0
            fi
        fi
    fi
    return 1
}
pause_media() {
    log_msg "Pausing known media players..."
    # native pause
    osascript -e 'ignoring application responses' \
              -e 'tell application "System Events"' \
              -e '  if exists (processes where name is "VLC") then tell application "VLC" to stop' \
              -e '  if exists (processes where name is "Spotify") then tell application "Spotify" to pause' \
              -e 'end tell' \
              -e 'end ignoring' >/dev/null 2>&1

    # pause known process ignoring that.
    if pgrep -x "mpv" > /dev/null; then
        log_msg "mpv detected. Attempting to pause or kill."
        # Try to send media pause key
        osascript -e 'tell application "System Events" to key code 100'
        # TODO: test if sigterm is necessary
        # killall -TERM mpv
    fi
}

enforce_pmset() {
    sudo pmset -a hibernatemode 3
    # short standby on all profiles since delay is not reevaluated on power source change
    sudo pmset -a standbydelaylow 300
    sudo pmset -a standbydelayhigh 300
    sudo pmset -b powernap 0
    sudo pmset -b womp 0
    if [[ "$is_tcp_keepalive" == false ]]; then
        sudo pmset -b tcpkeepalive 0
        sudo pmset -b networkoversleep 0
    fi
    if [[ "$is_lessbright_allowed" == false ]]; then
        sudo pmset -b lessbright 0
    fi
}
hibernate_now() {
    log_msg "Initiating hibernate..."
    if is_full_wake; then
        log_msg "Full wake in progress, aborting hibernate."
        return 1
    fi
    pause_media
    sudo pmset -a standbydelaylow 0
    sudo pmset -b networkoversleep 0
    sudo pmset -a standbydelayhigh 0
    sudo pmset -a hibernatemode 25
    sudo pmset -b powernap 0
    sudo pmset -b womp 0
    sleep 5
    if is_full_wake; then
        log_msg "User woke during hibernate prep. Restoring defaults."
        sudo pmset -a hibernatemode 3
        sudo pmset -a standbydelaylow 10800
        sudo pmset -a standbydelayhigh 86400
        return 1
    fi
    sudo pmset sleepnow
    STATE="sleeping"
}
sleep_now() {
    log_msg "Initiating sleep..."
    if is_full_wake; then
        log_msg "Full wake in progress, aborting sleep."
        return 1
    fi
    pause_media
    sudo pmset -a hibernatemode 3
    sudo pmset -b powernap 0
    sudo pmset -b womp 0
    sleep 5
    sudo pmset sleepnow
    STATE="sleeping"
}
log_msg "Starting Sleep Manager..."
# Check if Intel Mac laptop to set GPU preference to reduce power usage
MACHINE_MODEL=$(sysctl -n hw.model)
if [[ "$MACHINE_MODEL" == MacBook* ]] || [[ "$MACHINE_MODEL" == MacBookPro* ]] || [[ "$MACHINE_MODEL" == MacBookAir* ]]; then
    if ! sysctl hw.optional.arm64 2>/dev/null | grep -q ": 1"; then
        log_msg "Intel Mac detected. Setting GPU preference to integrated."
        sudo pmset -a gpuswitch 0
    fi
fi
# one-time init that only needs to run at daemon start
if [[ "$is_calaccessd_allowed" == false ]]; then
    log_msg "Disabling calaccessd to prevent calendar events from scheduling darkwake"
    console_uid=$(stat -f %u /dev/console)
    if [[ "$console_uid" == "0" || -z "$console_uid" ]]; then
        log_msg "No GUI user logged in; skipping calaccessd toggle."
    else
        launchctl disable "gui/${console_uid}/com.apple.calaccessd"
        sudo killall calaccessd 2>/dev/null && log_msg "Stopped calaccessd."
    fi
fi
if [[ "$is_analytics_allowed" == false ]]; then
    log_msg "Disabling analyticsd to prevent analytics events from waking the system."
    sudo defaults write /Library/Application\ Support/CrashReporter/DiagnosticMessagesHistory.plist AutoSubmit -bool false
    sudo defaults write /Library/Application\ Support/CrashReporter/DiagnosticMessagesHistory.plist ThirdPartyDataSubmit -bool false
fi
enforce_pmset
log_msg "Applied pmset settings."
while true; do
    sleep $TIME_RESOLUTION
    
    AC_POWER=0
    is_on_ac && AC_POWER=1
    
    IDLE=$(get_idle_time)
    BATT=$(get_battery_level)
    
    if [[ -z "$BATT" ]]; then continue; fi

    # Check if system just woke up or is in darkwake
    if ! is_full_wake; then
        # Dark: sleeping or darkwake (no graphics, no user, panel off).
        
        # Absolute low battery check happens only when display is off
        if [[ "$AC_POWER" -eq 0 && "$BATT" -le "$LOW_BATTERY_THRESHOLD" ]]; then
            log_msg "Low battery threshold met while display off ($BATT%). Response: $THRESHOLD_RESPONSE"
            BATTERY_AT_SLEEP=$BATT
            if [[ "$THRESHOLD_RESPONSE" == "hibernate" ]]; then
                hibernate_now
            else
                sleep_now
            fi
            continue
        fi

        # Check against battery drain threshold for hibernation transition:
        if [[ "$STATE" == "sleeping" ]]; then
            BATT_DROP=$(( BATTERY_AT_SLEEP - BATT ))
            if [[ "$BATT_DROP" -ge "$THRESHOLD_PERCENT" ]]; then
                log_msg "Battery dropped by $BATT_DROP%. Hibernating."
                sleep 30 # wait for VM settle
               	if ! is_full_wake; then
	                if [[ "$THRESHOLD_RESPONSE" == "hibernate" ]]; then
	                    hibernate_now
	                else
	                    sleep_now
	                fi
                else
                	log_msg "Aborted re-sleep, display is on (user woke system)."
               	fi
            else
                # Not enough drain yet, but re-sleep in case of phantom wake like t2 macbook touchbar
                # handle darkwake here
                log_msg "Darkwake detected. Waiting 30s to settle before sleep."
                sleep 30
                if ! is_full_wake; then
                    pmset sleepnow
                else
                    log_msg "Aborted re-sleep, display is on (user woke system)."
                fi
            fi
        elif [[ "$STATE" == "awake" ]]; then
           # Display off but we never initiated sleep — lid was closed
           # or system entered darkwake on its own. Force sleep.
           if has_active_tty; then
               # TTY is actively running, skip forcing manual sleep 
               # (low battery is already handled above)
               :
           else
               log_msg "Display off and awake with no TTY. Battery: $BATT%. Forcing sleep."
               BATTERY_AT_SLEEP=$BATT
               sleep_now
           fi
        fi
        continue
    else
        # Display is on, update state to awake
        if [[ "$STATE" == "sleeping" ]]; then
            log_msg "System woke up."
            STATE="awake"
            enforce_pmset
            # coreaudiod fails to resync its ring buffer positions after
            # hibernate (mode 25) wake, causing a ~536M frame offset
            sudo killall coreaudiod 2>/dev/null && log_msg "Restarted coreaudiod."
        fi
    fi
    # Block sleeping if there is an active TTY session and permissions require it
    if has_active_tty; then
        continue
    fi
    # Idle timeout check
    if [[ "$IDLE" -gt "$IDLE_TIME_SEC" ]]; then
        log_msg "Idle for $IDLE seconds. Recording battery at $BATT% and sleeping."
        BATTERY_AT_SLEEP=$BATT
        sleep_now
    fi
done