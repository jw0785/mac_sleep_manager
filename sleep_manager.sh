#!/bin/bash

# need to know
# macos rely on EC.RTC for almost every maintenance task. there's only so much i can do.

# Configuration
IDLE_TIME_SEC=900            # idle_time
TIME_RESOLUTION=60           # time_resolution
THRESHOLD_PERCENT=15         # threshold (battery drop % during sleep to trigger hibernate)
LOW_BATTERY_THRESHOLD=20     # low_battery_threshold
IDLE_DURATION_THRESHOLD=86400   # in seconds (trigger hibernate after sleep duration on BATTERY)
THRESHOLD_RESPONSE="hibernate" # threshold_response (hibernate or sleep)
PERMISSION="tty"             # permission {none, tty} - prevent sleep if active tty/ssh exists
is_tcp_keepalive=false
# darkwake, sched related
is_calaccessd_allowed=false         # necessary for calendar time to leave. unless you don't use icalendar.
                                    # TODO: disable for now, trigger rapid consecutive darkwake and cause states desync
is_analytics_allowed=false
is_handoff_allowed=false
## extra
is_lessbright_allowed=false
# Internal State Variables
STATE="awake"
wake_sec=$(sysctl -n kern.waketime 2>/dev/null | sed 's/{ sec = \([0-9]*\).*/\1/')
is_new_wake=false
BATTERY_AT_SLEEP=100
LAST_HANDLED_WAKE=0
SLEEP_START_TIME=0
CAFFEINATE_PID=""

start_caffeinate() {
    [[ -n "$CAFFEINATE_PID" ]] && kill "$CAFFEINATE_PID" 2>/dev/null
    caffeinate -s -w $$ &
    CAFFEINATE_PID=$!
}
stop_caffeinate() {
    [[ -n "$CAFFEINATE_PID" ]] && kill "$CAFFEINATE_PID" 2>/dev/null
    CAFFEINATE_PID=""
}

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
_is_on_ac() {
    pmset -g batt | grep -q "AC Power"
    return $?
}
_is_display_asleep() {
    if ! ioreg -n IODisplayWrangler | grep -i IOPowerManagement | grep -q 'CurrentPowerState"=4'; then
        return 0
    fi
    # apparently mpv can hold wrangler at 4 with lid closed — fall back to clamshell
    if pgrep -x "mpv" > /dev/null; then
        ioreg -c IOPMrootDomain | grep -q '"AppleClamshellState" = Yes'
        return $?
    fi
    return 1
}
# prevent sleep collision with full wake transition
is_full_wake() {
    if ! _is_display_asleep; then
        # address usb insertion phantom wake
        ioreg -c IOPMrootDomain | grep -q '"AppleClamshellState" = Yes' && ! _is_on_ac && return 1
        return 0
    fi
    # lid-open transition: woke recently(30 sec) from lid open, display not on yet
    local wake_sec
    wake_sec=$(sysctl -n kern.waketime 2>/dev/null | sed 's/{ sec = \([0-9]*\).*/\1/')
    if [[ -n "$wake_sec" ]] && (( $(date +%s) - wake_sec < 30 )); then
        ioreg -c IOPMrootDomain | grep -q '"Wake Reason" = "EC.LidOpen"' && return 0
    fi
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

    if pgrep -x "mpv" > /dev/null; then
        rm -f /tmp/mpv_resume.*.playlist /tmp/mpv_resume.*.pos /tmp/mpv_resume.*.time
        local idx=0 saved_socks=()
        for sock in /tmp/mpvsocket.*; do
            [[ -S "$sock" ]] || continue
            local raw_pl raw_pos raw_time
            raw_pl=$(echo '{"command":["get_property","playlist"]}' | nc -w 1 -U "$sock" 2>/dev/null)
            raw_pos=$(echo '{"command":["get_property","playlist-pos"]}' | nc -w 1 -U "$sock" 2>/dev/null)
            raw_time=$(echo '{"command":["get_property","time-pos"]}' | nc -w 1 -U "$sock" 2>/dev/null)
            echo "$raw_pl" | grep -o '"filename":"[^"]*"' | sed 's/"filename":"//;s/"$//' > "/tmp/mpv_resume.${idx}.playlist"
            echo "$raw_pos" | sed 's/.*"data":\([0-9]*\).*/\1/' > "/tmp/mpv_resume.${idx}.pos"
            echo "$raw_time" | sed 's/.*"data":\([0-9.]*\).*/\1/' > "/tmp/mpv_resume.${idx}.time"
            if [[ -s "/tmp/mpv_resume.${idx}.playlist" ]]; then
                log_msg "mpv: saved state from $sock (idx=$idx)."
                saved_socks+=("$sock")
                (( idx++ ))
            else
                rm -f "/tmp/mpv_resume.${idx}.playlist" "/tmp/mpv_resume.${idx}.pos" "/tmp/mpv_resume.${idx}.time"
            fi
        done
        if (( ${#saved_socks[@]} > 0 )); then
            for sock in "${saved_socks[@]}"; do
                echo '{"command":["quit"]}' | nc -w 1 -U "$sock" >/dev/null 2>&1
            done
            log_msg "mpv: quit ${#saved_socks[@]} instance(s) via IPC."
            sleep 1
            pgrep -x "mpv" > /dev/null && killall mpv 2>/dev/null && log_msg "mpv: killed remaining instances."
        else
            log_msg "mpv: no IPC sockets found. Sending SIGSTOP."
            killall -STOP mpv
        fi
    fi
}
disable_powernap() {
    local src="/System/Library/FeatureFlags/Domain/powerd.plist"
    local dst="/Library/FeatureFlags/Domain/powerd.plist"
    if [[ ! -f "$src" ]]; then
        log_msg "powerd feature flag plist not found, skipping."
        return 1
    fi
    sudo mkdir -p /Library/FeatureFlags/Domain
    sudo cp "$src" "$dst"
    local keys
    keys=$(/usr/libexec/PlistBuddy -c "Print" "$dst" 2>/dev/null \
        | grep "= Dict" | sed 's/ *\(.*\) = Dict.*/\1/')
    for key in $keys; do
        local val
        val=$(/usr/libexec/PlistBuddy -c "Print :${key}:Enabled" "$dst" 2>/dev/null)
        if [[ "$val" == "true" ]]; then
            sudo /usr/libexec/PlistBuddy -c "Set :${key}:Enabled false" "$dst"
            log_msg "Disabled feature flag: $key"
        fi
    done
}
enforce_pmset() {
    sudo pmset -a hibernatemode 3
    sudo pmset -a proximitywake 0
    # macOS doesn't re-evaluate standby delay on source change, so we do it
    if _is_on_ac; then
        sudo pmset -a standby 0
    else
        sudo pmset -a standby 1
        sudo pmset -a standbythreshold 20 # default 50%
        sudo pmset -a standbydelaylow 300 # default 10800 min
        sudo pmset -a standbydelayhigh 86400 # default 86400 min
    fi
    sudo pmset -a powernap 0
    sudo pmset -a womp 0
    if [[ "$is_tcp_keepalive" == false ]]; then
        sudo pmset -a tcpkeepalive 0
        sudo pmset -a networkoversleep 0
    fi
    if [[ "$is_lessbright_allowed" == false ]]; then
        sudo pmset -a lessbright 0
    fi
}
handle_wake() {
    log_msg "System woke up."
    local was_hibernating=false
    [[ "$STATE" == "hibernating" ]] && was_hibernating=true
    STATE="awake"
    start_caffeinate
    enforce_pmset
    if pgrep -x "mpv" > /dev/null; then
        killall -CONT mpv 2>/dev/null && log_msg "mpv: sent SIGCONT to surviving instances."
        rm -f /tmp/mpv_resume.*.playlist /tmp/mpv_resume.*.pos /tmp/mpv_resume.*.time
        log_msg "mpv: cleaned stale state files."
    else
        local console_uid console_user
        console_uid=$(stat -f %u /dev/console)
        console_user=$(stat -f %Su /dev/console)
        for pl_file in /tmp/mpv_resume.*.playlist; do
            [[ -f "$pl_file" ]] || continue
            local idx="${pl_file#/tmp/mpv_resume.}" && idx="${idx%.playlist}"
            [[ -f "/tmp/mpv_resume.${idx}.pos" ]] || continue
            local pos time_pos start_args=""
            pos=$(cat "/tmp/mpv_resume.${idx}.pos" 2>/dev/null)
            time_pos=$(cat "/tmp/mpv_resume.${idx}.time" 2>/dev/null)
            [[ -n "$pos" ]] && start_args="--playlist-start=$pos"
            [[ -n "$time_pos" && "$time_pos" != "0" && "$time_pos" != "0.000000" ]] && start_args="$start_args --start=$time_pos"
            launchctl asuser "$console_uid" sudo -u "$console_user" /usr/local/bin/mpv --playlist="$pl_file" $start_args >/dev/null 2>&1 &
            log_msg "mpv: relaunched instance $idx (pos=$pos, time=$time_pos)."
            rm -f "/tmp/mpv_resume.${idx}.pos" "/tmp/mpv_resume.${idx}.time"
        done
    fi
    if [[ "$was_hibernating" == true ]]; then
        sudo killall coreaudiod 2>/dev/null && log_msg "Restarted coreaudiod (post-hibernate)."
    fi
}
hibernate_now() {
    log_msg "Initiating hibernate..."
    if is_full_wake; then
        log_msg "Full wake in progress, aborting hibernate."
        return 1
    fi
    pause_media
    stop_caffeinate
    sudo pmset -a standbydelaylow 0
    sudo pmset -b networkoversleep 0
    sudo pmset -a standbydelayhigh 0
    sudo pmset -a hibernatemode 25
    sudo pmset -b powernap 0
    sudo pmset -b womp 0
    sleep 5
    if is_full_wake; then
        log_msg "User woke during hibernate prep. Restoring defaults."
        enforce_pmset
        return 1
    fi
    sudo pmset sleepnow
    STATE="hibernating"
}
sleep_now() {
    if [[ "$STATE" == "awake" ]]; then
        SLEEP_START_TIME=$(date +%s)
    fi
    log_msg "Initiating sleep..."
    if is_full_wake; then
        log_msg "Full wake in progress, aborting sleep."
        return 1
    fi
    pause_media
    enforce_pmset
    stop_caffeinate
    local ts_before=$(date +%s)
    sudo pmset sleepnow
    STATE="sleeping"
    sleep $TIME_RESOLUTION
    local elapsed=$(( $(date +%s) - ts_before ))
    if (( elapsed < TIME_RESOLUTION + 30 )); then
        log_msg "WARNING: Sleep not honored (returned in ${elapsed}s)."
    fi
}
log_msg "Starting Sleep Manager..."
start_caffeinate
# Check if Intel Mac laptop to set GPU preference to reduce power usage
MACHINE_MODEL=$(sysctl -n hw.model)
if [[ "$MACHINE_MODEL" == MacBook* ]] || [[ "$MACHINE_MODEL" == MacBookPro* ]] || [[ "$MACHINE_MODEL" == MacBookAir* ]]; then
    if ! sysctl hw.optional.arm64 2>/dev/null | grep -q ": 1"; then
        log_msg "Intel Mac detected. Setting GPU preference to integrated."
        sudo pmset -b gpuswitch 0
        sudo pmset -c gpuswitch 1
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
    # purge orphaned wake alarms left in powerd's schedule
    pmset -g sched 2>/dev/null | grep "calaccessd" | while read -r line; do
        local dt
        dt=$(echo "$line" | sed "s/.*wake at \(.*\) by.*/\1/")
        sudo pmset schedule cancel wake "$dt" 2>/dev/null && log_msg "Cancelled orphaned calaccessd wake alarm."
    done
fi
if [[ "$is_analytics_allowed" == false ]]; then
    log_msg "Disabling osanalytics to prevent analytics wake scheduling."
    sudo launchctl disable system/com.apple.osanalytics.osanalyticshelper
    sudo killall osanalyticshelper 2>/dev/null && log_msg "Stopped osanalyticshelper."
    console_uid=$(stat -f %u /dev/console)
    if [[ "$console_uid" != "0" && -n "$console_uid" ]]; then
        launchctl disable "gui/${console_uid}/com.apple.osanalytics.user.cachedelete"
    fi
    pmset -g sched 2>/dev/null | grep "osanalytics" | while read -r line; do
        local dt
        dt=$(echo "$line" | sed "s/.*wake at \(.*\) by.*/\1/")
        sudo pmset schedule cancel wake "$dt" 2>/dev/null && log_msg "Cancelled orphaned osanalytics wake alarm."
    done
fi
if [[ "$is_handoff_allowed" == false ]]; then
    log_msg "Disabling Handoff to prevent handoff wake scheduling."
    sudo defaults write /Library/Preferences/com.apple.coreservices.useractivityd.plist ActivityAdvertisingAllowed -bool false
    sudo defaults write /Library/Preferences/com.apple.coreservices.useractivityd.plist ActivityReceivingAllowed -bool false
    sudo killall useractivityd 2>/dev/null && log_msg "Stopped useractivityd."
fi
disable_powernap
enforce_pmset
log_msg "Applied pmset settings."
PREV_AC_POWER=-1
while true; do
    sleep $TIME_RESOLUTION

    AC_POWER=0
    _is_on_ac && AC_POWER=1

    if [[ "$AC_POWER" -ne "$PREV_AC_POWER" && "$PREV_AC_POWER" -ne -1 ]]; then
        log_msg "Power source changed (AC=$AC_POWER). Re-applying pmset."
        enforce_pmset
    fi
    PREV_AC_POWER=$AC_POWER
    
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
            elif [[ "$AC_POWER" -eq 0 ]] && (( $(date +%s) - SLEEP_START_TIME >= IDLE_DURATION_THRESHOLD )); then
                log_msg "Asleep for $(( $(date +%s) - SLEEP_START_TIME ))s on battery, exceeds ${IDLE_DURATION_THRESHOLD}s threshold. Hibernating."
                hibernate_now
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
    elif is_full_wake; then
        # Display is on, update state to awake
        wake_sec=$(sysctl -n kern.waketime 2>/dev/null | sed 's/{ sec = \([0-9]*\).*/\1/')
        is_new_wake=false
        if [[ -n "$wake_sec" ]] && (( wake_sec > LAST_HANDLED_WAKE )); then
            is_new_wake=true
            LAST_HANDLED_WAKE=$wake_sec
        fi
        if [[ "$STATE" != "awake" ]] || [[ "$is_new_wake" == true ]]; then
            handle_wake
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