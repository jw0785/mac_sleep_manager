#!/bin/bash

# need to know
# macos rely on EC.RTC for almost every maintenance task. there's only so much i can do.

# Configuration
IDLE_TIME_SEC=900            # idle_time
TIME_RESOLUTION=60           # time_resolution
TIME_RESOLUTION_SLEEP=5      # time_resolution during sleep
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
# Internal _State Variables
_STATE="awake"
_wake_sec=$(sysctl -n kern.waketime 2>/dev/null | sed 's/{ sec = \([0-9]*\).*/\1/')
_is_new_wake=false
_BATTERY_AT_SLEEP=100
_LAST_HANDLED_WAKE=0
_SLEEP_START_TIME=0
_CAFFEINATE_PID=""
_IS_GAUGE_DESYNC=false
_PREV_BATT=""
_BATT_CURRENT_MA=0
_BATT_DATA_AGE=0
_SLEEP_CURRENT_LIMIT=1500
_BG_ASSERT_BIN="/tmp/.sleep_mgr_assert"
_HAS_T2=$(system_profiler SPiBridgeDataType 2>/dev/null | grep -q "T2" && echo true || echo false)

start_caffeinate() {
    [[ -n "$_CAFFEINATE_PID" ]] && kill "$_CAFFEINATE_PID" 2>/dev/null
    caffeinate -s -w $$ &
    _CAFFEINATE_PID=$!
}
stop_caffeinate() {
    [[ -n "$_CAFFEINATE_PID" ]] && kill "$_CAFFEINATE_PID" 2>/dev/null
    _CAFFEINATE_PID=""
}

LOG_FILE="/tmp/sleep_manager.log"
log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}
get_idle_time() {
    echo $(( $(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF; exit}') / 1000000000 ))
}
get_battery_level() {
    # # TODO: FIX STALE VOLTAGE DURING DARKWAKE
    # _lerp_vsoc() {
    #     local mv=$(( $1 + 50 )) i
    #     local -a mV=(3300 3400 3600 3750 3850 3950 4100 4200)
    #     local -a soc=(0    3    10   30   50   70   90   100)
    #     if (( mv <= mV[0] )); then echo 0; return; fi
    #     if (( mv >= mV[${#mV[@]}-1] )); then echo 100; return; fi
    #     for (( i=1; i<${#mV[@]}; i++ )); do
    #         if (( mv <= mV[i] )); then
    #             echo $(( soc[i-1] + (mv - mV[i-1]) * (soc[i] - soc[i-1]) / (mV[i] - mV[i-1]) ))
    #             return
    #         fi
    #     done
    # }
    local raw
    raw=$(ioreg -r -n AppleSmartBattery)
    local pct
    pct=$(pmset -g batt | grep -oE '[0-9]+%' | head -1 | tr -d '%')
    if [[ -z "$pct" ]]; then
        BATT=""
        return
    fi
    local ext_power amp
    ext_power=$(echo "$raw" | awk '/ExternalConnected/{print $NF; exit}')
    amp=$(echo "$raw" | awk '/"InstantAmperage"/{print $NF; exit}')
    [[ -n "$amp" ]] && _BATT_CURRENT_MA=$(( -amp ))
    if [[ "$ext_power" == "Yes" ]]; then
        BATT=$pct
        _PREV_BATT=""
        return
    fi
    local update_time now
    update_time=$(echo "$raw" | awk '/^ *"UpdateTime"/{print $NF; exit}')
    now=$(date +%s)
    _BATT_DATA_AGE=$(( now - ${update_time:-0} ))
    if [[ "$_IS_GAUGE_DESYNC" == true ]]; then
        BATT=$pct
        return
    fi
    if [[ "${1:-}" != "validate" ]]; then
        BATT=$pct
        return
    fi
    if [[ -n "$_PREV_BATT" ]] && (( pct >= _PREV_BATT + 2 )); then
        log_msg "Gauge desync: ${pct}% > prev ${_PREV_BATT}% on DC (impossible). Locking to hibernate."
        _IS_GAUGE_DESYNC=true
        BATT=$pct
        return
    fi
    _PREV_BATT=$pct
    BATT=$pct
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
    # T2 phantom USBC wake: EC routes USB-C bus noise through ACPI lid sensor for reasons,
    # powering on display even though lid is physically closed.
    # On battery, USBC can never be a real user wake (charger would switch to AC).
    if ! _is_on_ac; then
        local recent_wake
        recent_wake=$(sysctl -n kern.waketime 2>/dev/null | sed 's/{ sec = \([0-9]*\).*/\1/')
        if [[ -n "$recent_wake" ]] && (( $(date +%s) - recent_wake < 120 )); then
            ioreg -c IOPMrootDomain | grep -q '"Wake Reason" = "EC.USBC"' && return 1
        fi
    fi
    if ! _is_display_asleep; then
        # address usb insertion phantom wake
        ioreg -c IOPMrootDomain | grep -q '"AppleClamshellState" = Yes' && ! _is_on_ac && return 1
        return 0
    fi
    # lid-open transition: woke recently(30 sec) from lid open, display not on yet
    local _wake_sec
    _wake_sec=$(sysctl -n kern.waketime 2>/dev/null | sed 's/{ sec = \([0-9]*\).*/\1/')
    if [[ -n "$_wake_sec" ]] && (( $(date +%s) - _wake_sec < 30 )); then
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
        (
            idx=0
            for sock in /tmp/mpvsocket.*; do
                [[ -S "$sock" ]] || continue
                raw_pl=$(echo '{"command":["get_property","playlist"]}' | nc -w 1 -U "$sock" 2>/dev/null)
                raw_pos=$(echo '{"command":["get_property","playlist-pos"]}' | nc -w 1 -U "$sock" 2>/dev/null)
                raw_time=$(echo '{"command":["get_property","time-pos"]}' | nc -w 1 -U "$sock" 2>/dev/null)
                echo "$raw_pl" | grep -o '"filename":"[^"]*"' | sed 's/"filename":"//;s/"$//' > "/tmp/mpv_resume.${idx}.playlist"
                echo "$raw_pos" | sed 's/.*"data":\([0-9]*\).*/\1/' > "/tmp/mpv_resume.${idx}.pos"
                echo "$raw_time" | sed 's/.*"data":\([0-9.]*\).*/\1/' > "/tmp/mpv_resume.${idx}.time"
                if [[ -s "/tmp/mpv_resume.${idx}.playlist" ]]; then
                    log_msg "mpv: saved state from $sock (idx=$idx)."
                    echo '{"command":["quit"]}' | nc -w 1 -U "$sock" >/dev/null 2>&1
                    (( idx++ ))
                else
                    rm -f "/tmp/mpv_resume.${idx}.playlist" "/tmp/mpv_resume.${idx}.pos" "/tmp/mpv_resume.${idx}.time"
                fi
            done
        ) &
        local save_pid=$!
        ( sleep 10; kill "$save_pid" 2>/dev/null ) &
        local wd_pid=$!
        wait "$save_pid" 2>/dev/null
        kill "$wd_pid" 2>/dev/null; wait "$wd_pid" 2>/dev/null
        if ls /tmp/mpv_resume.*.playlist >/dev/null 2>&1; then
            if pgrep -x "mpv" > /dev/null; then
                killall mpv 2>/dev/null
                log_msg "mpv: sent SIGTERM."
                sleep 1
                pgrep -x "mpv" > /dev/null && killall -9 mpv 2>/dev/null && log_msg "mpv: force-killed (SIGKILL)."
            fi
        else
            log_msg "mpv: no IPC sockets found. Sending SIGSTOP."
            killall -STOP mpv 2>/dev/null
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
save_smb_mounts() {
    rm -f /tmp/smb_resume.*
    local idx=0
    while read -r src; do
        echo "$src" > "/tmp/smb_resume.${idx}"
        (( idx++ ))
    done < <(timeout 5 mount -t smbfs 2>/dev/null | awk '{print $1}')
    (( idx > 0 )) && log_msg "SMB: saved $idx active mount(s)."
}
restore_smb_mounts() {
    local has_state=false
    for f in /tmp/smb_resume.*; do [[ -f "$f" ]] && has_state=true && break; done
    [[ "$has_state" == false ]] && return
    local console_uid console_user
    console_uid=$(stat -f %u /dev/console)
    console_user=$(stat -f %Su /dev/console)
    if [[ "$console_uid" == "0" || -z "$console_uid" ]]; then
        log_msg "SMB: no GUI user, skipping restore."
        rm -f /tmp/smb_resume.*
        return
    fi
    for f in /tmp/smb_resume.*; do
        [[ -f "$f" ]] || continue
        local src
        src=$(cat "$f" 2>/dev/null)
        [[ -z "$src" ]] && continue
        if timeout 10 mount -t smbfs 2>/dev/null | grep -qF "$src"; then
            log_msg "SMB: $src still mounted, skipping."
            continue
        fi
        local smb_url="smb://${src#//}"
        launchctl asuser "$console_uid" sudo -u "$console_user" \
            open "$smb_url" 2>/dev/null && \
            log_msg "SMB: reconnecting $smb_url" || \
            log_msg "SMB: failed to open $smb_url"
    done
    rm -f /tmp/smb_resume.*
}
enforce_pmset() {
    sudo pmset -a hibernatemode 3
    sudo pmset -a proximitywake 0
    # macOS doesn't re-evaluate standby/gpuswitch on source change, so we have to enforce it manually
    if _is_on_ac; then
        sudo pmset -a standby 0
    else
        sudo pmset -a standby 1
        sudo pmset -a highstandbythreshold 20 # default 50%
        sudo pmset -a standbydelaylow 300 # default 10800 min
        sudo pmset -a standbydelayhigh 86400 # default 86400 min
    fi
    local machine_model
    machine_model=$(sysctl -n hw.model)
    if [[ "$machine_model" == MacBook* ]] && ! sysctl hw.optional.arm64 2>/dev/null | grep -q ": 1"; then
        if _is_on_ac; then
            sudo pmset -a gpuswitch 1
        else
            sudo pmset -a gpuswitch 0
        fi
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
    [[ "$_STATE" == "hibernating" ]] && was_hibernating=true
    _STATE="awake"
    if [[ "$_IS_GAUGE_DESYNC" == true ]]; then
        log_msg "User wake: clearing gauge desync flag."
        _IS_GAUGE_DESYNC=false
        _PREV_BATT=""
    fi
    start_caffeinate
    enforce_pmset
    restore_smb_mounts
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
    save_smb_mounts
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
    _STATE="hibernating"
}
sleep_now() {
    if [[ "$_STATE" == "awake" ]]; then
        _SLEEP_START_TIME=$(date +%s)
    fi
    if [[ "$_IS_GAUGE_DESYNC" == true ]] && ! _is_on_ac; then
        log_msg "Gauge desync active. Routing to hibernate instead of sleep."
        hibernate_now
        return $?
    fi
    log_msg "Initiating sleep..."
    if is_full_wake; then
        log_msg "Full wake in progress, aborting sleep."
        return 1
    fi
    save_smb_mounts
    pause_media
    enforce_pmset
    stop_caffeinate
    local ts_before=$(date +%s)
    sudo pmset sleepnow
    _STATE="sleeping"
    sleep $TIME_RESOLUTION
    local elapsed=$(( $(date +%s) - ts_before ))
    if (( elapsed < TIME_RESOLUTION + 30 )); then
        log_msg "WARNING: Sleep not honored (returned in ${elapsed}s)."
    fi
}
log_msg "Starting Sleep Manager..."
start_caffeinate
disable_powernap
enforce_pmset
log_msg "Applied pmset settings."
rm -f "$_BG_ASSERT_BIN"
if [[ "$_HAS_T2" == true ]] && ! [[ -x "$_BG_ASSERT_BIN" ]]; then
    cc -framework IOKit -framework CoreFoundation -O2 -o "$_BG_ASSERT_BIN" -x c - <<'ASSERT_SRC'
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>
static IOPMAssertionID aid;
void cleanup(int s) { if (aid) IOPMAssertionRelease(aid); _exit(0); }
int main(int argc, char **argv) {
    signal(SIGTERM, cleanup);
    signal(SIGINT, cleanup);
    if (IOPMAssertionCreateWithName(CFSTR("BackgroundTask"),
            kIOPMAssertionLevelOn, CFSTR("sleep_manager"), &aid))
        return 1;
    sleep(argc > 1 ? atoi(argv[1]) : 65);
    IOPMAssertionRelease(aid);
}
ASSERT_SRC
    [[ -x "$_BG_ASSERT_BIN" ]] && log_msg "Compiled BackgroundTask helper." \
        || log_msg "WARNING: failed to compile BackgroundTask helper."
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
# use Al Dente, don't let OBC schedule and drain battery during sleep
log_msg "Disabling Optimized Battery Charging maintenance wakes."
sudo defaults write com.apple.smartcharging isEnabled -bool false 2>/dev/null
sudo killall PowerUIAgent 2>/dev/null && log_msg "Stopped PowerUIAgent."
pmset -g sched 2>/dev/null | grep "com.apple.obc" | while read -r line; do
    local dt
    dt=$(echo "$line" | sed "s/.*wake at \(.*\) by.*/\1/")
    sudo pmset schedule cancel wake "$dt" 2>/dev/null && log_msg "Cancelled orphaned OBC wake alarm."
done
if [[ "$is_handoff_allowed" == false ]]; then
    log_msg "Disabling Handoff to prevent handoff wake scheduling."
    sudo defaults write /Library/Preferences/com.apple.coreservices.useractivityd.plist ActivityAdvertisingAllowed -bool false
    sudo defaults write /Library/Preferences/com.apple.coreservices.useractivityd.plist ActivityReceivingAllowed -bool false
    sudo killall useractivityd 2>/dev/null && log_msg "Stopped useractivityd."
fi
PREV_AC_POWER=-1
while true; do
    if [[ "$_STATE" == "sleeping" || "$_STATE" == "hibernating" ]]; then
        sleep $TIME_RESOLUTION_SLEEP
    else
        sleep $TIME_RESOLUTION
    fi

    AC_POWER=0
    _is_on_ac && AC_POWER=1

    if [[ "$AC_POWER" -ne "$PREV_AC_POWER" && "$PREV_AC_POWER" -ne -1 ]]; then
        log_msg "Power source changed (AC=$AC_POWER). Re-applying pmset."
        enforce_pmset
        if [[ "$_IS_GAUGE_DESYNC" == true ]]; then
            log_msg "Power source transition: clearing gauge desync flag."
            _IS_GAUGE_DESYNC=false
        fi
        _PREV_BATT=""
    fi
    PREV_AC_POWER=$AC_POWER
    
    # Check if system just woke up or is in darkwake
    if ! is_full_wake; then
        # Dark: sleeping or darkwake (no graphics, no user, panel off).
        get_battery_level validate
        if [[ -z "$BATT" ]]; then continue; fi

        # On battery with stale data: hold darkwake open until battery driver refreshes
        if [[ "$AC_POWER" -eq 0 ]] && (( _BATT_DATA_AGE > 60 )); then
            log_msg "Battery data stale (${_BATT_DATA_AGE}s old). Holding darkwake for fresh reading."
            DW_ASSERT_PID=""
            if [[ "$_HAS_T2" == true ]] && [[ -x "$_BG_ASSERT_BIN" ]]; then
                "$_BG_ASSERT_BIN" 65 &
            else
                caffeinate -s -t 65 &
            fi
            DW_ASSERT_PID=$!
            DW_GOT_FRESH=false
            for (( dw_i=0; dw_i<12; dw_i++ )); do
                sleep 5
                if is_full_wake; then break; fi
                get_battery_level validate
                if (( _BATT_DATA_AGE <= 60 )); then
                    DW_GOT_FRESH=true
                    break
                fi
            done
            kill "$DW_ASSERT_PID" 2>/dev/null; wait "$DW_ASSERT_PID" 2>/dev/null
            if [[ "$DW_GOT_FRESH" == false ]] && ! is_full_wake; then
                log_msg "No fresh battery data after 60s darkwake hold. Forcing hibernation."
                hibernate_now
                continue
            fi
        fi

        # Absolute low battery check happens only when display is off
        if [[ "$AC_POWER" -eq 0 && "$BATT" -le "$LOW_BATTERY_THRESHOLD" ]]; then
            log_msg "Low battery threshold met while display off ($BATT%). Response: $THRESHOLD_RESPONSE"
            _BATTERY_AT_SLEEP=$BATT
            if [[ "$THRESHOLD_RESPONSE" == "hibernate" ]]; then
                hibernate_now
            else
                sleep_now
            fi
            continue
        fi

        # Check against battery drain threshold for hibernation transition:
        if [[ "$_STATE" == "sleeping" ]]; then
            sleep 3
            get_battery_level
            BATT_DROP=$(( _BATTERY_AT_SLEEP - BATT ))
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
            elif [[ "$AC_POWER" -eq 0 ]] && (( $(date +%s) - _SLEEP_START_TIME >= IDLE_DURATION_THRESHOLD )); then
                log_msg "Asleep for $(( $(date +%s) - _SLEEP_START_TIME ))s on battery, exceeds ${IDLE_DURATION_THRESHOLD}s threshold. Hibernating."
                hibernate_now
            elif [[ "$AC_POWER" -eq 0 ]] && (( _BATT_CURRENT_MA > _SLEEP_CURRENT_LIMIT )); then
                log_msg "Abnormal current during sleep: ${_BATT_CURRENT_MA}mA (limit ${_SLEEP_CURRENT_LIMIT}mA). Forcing hibernation."
                hibernate_now
            else
                # Not enough drain yet, but re-sleep in case of phantom wake like t2 macbook touchbar
                # handle darkwake here
                log_msg "Darkwake detected. Re-applying pmset and waiting 30s to settle."
                enforce_pmset
                sleep 30
                if ! is_full_wake; then
                    sudo pmset sleepnow
                else
                    log_msg "Aborted re-sleep, display is on (user woke system)."
                fi
            fi
        elif [[ "$_STATE" == "awake" ]]; then
           # Display off but we never initiated sleep — lid was closed
           # or system entered darkwake on its own. Force sleep.
           if has_active_tty; then
               # TTY is actively running, skip forcing manual sleep
               # (low battery is already handled above)
               :
           else
               log_msg "Display off and awake with no TTY. Battery: $BATT%. Forcing sleep."
               _BATTERY_AT_SLEEP=$BATT
               sleep_now
           fi
        fi
        continue
    elif is_full_wake; then
        # Display is on, update _state to awake
        _wake_sec=$(sysctl -n kern.waketime 2>/dev/null | sed 's/{ sec = \([0-9]*\).*/\1/')
        _is_new_wake=false
        if [[ -n "$_wake_sec" ]] && (( _wake_sec > _LAST_HANDLED_WAKE )); then
            _is_new_wake=true
            _LAST_HANDLED_WAKE=$_wake_sec
        fi
        if [[ "$_STATE" != "awake" ]] || [[ "$_is_new_wake" == true ]]; then
            handle_wake
        fi
    fi
    # Block sleeping if there is an active TTY session and permissions require it
    if has_active_tty; then
        IDLE=$(get_idle_time)
        log_msg "Active TTY detected, skipping sleep. IDLE=$IDLE"
        continue
    fi
    IDLE=$(get_idle_time)
    log_msg "Light path: IDLE=$IDLE wrangler=$(ioreg -n IODisplayWrangler | grep -o 'CurrentPowerState"=[0-9]*')"
    # Idle timeout check (lid-open idle path)
    if [[ "$IDLE" -gt "$IDLE_TIME_SEC" ]]; then
        get_battery_level
        log_msg "Idle for $IDLE seconds. Recording battery at $BATT% and sleeping."
        _BATTERY_AT_SLEEP=$BATT
        sleep_now
    fi
done