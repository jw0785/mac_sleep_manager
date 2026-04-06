#!/bin/bash

# Configuration
IDLE_TIME_SEC=900            # idle_time
TIME_RESOLUTION=60           # time_resolution
THRESHOLD_PERCENT=15         # threshold (battery drop % during sleep to trigger hibernate)
LOW_BATTERY_THRESHOLD=20     # low_battery_threshold
# TODO: add time threshold on battery
THRESHOLD_RESPONSE="hibernate" # threshold_response (hibernate or sleep)
PERMISSION="tty"             # permission {none, tty} - prevent sleep if active tty/ssh exists
is_tcp_keepalive=false
# Internal State Variables
STATE="awake"
BATTERY_AT_SLEEP=100
DARKWAKE_SENT=0

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
hibernate_now() {
    log_msg "Initiating hibernate..."
    if ! is_display_asleep; then
        log_msg "Display on, aborting hibernate."
        return 1
    fi
    sudo pmset -a standbydelaylow 0
    sudo pmset -a standbydelayhigh 0
    sudo pmset -a hibernatemode 25
    sleep 5
    if ! is_display_asleep; then
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
    pmset -a hibernatemode 3
    sleep 5
    pmset sleepnow
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
# toggle tcp keepalive on battery if disabled
if [[ "$is_tcp_keepalive" == false ]]; then
    log_msg "Disabling TCP keepalive to prevent phantom wakes."
    sudo pmset -b tcpkeepalive 0
fi
while true; do
    sleep $TIME_RESOLUTION
    
    AC_POWER=0
    is_on_ac && AC_POWER=1
    
    IDLE=$(get_idle_time)
    BATT=$(get_battery_level)
    
    if [[ -z "$BATT" ]]; then continue; fi

    # Check if system just woke up or is in darkwake
    if is_display_asleep; then
        # Display is off. Could be sleeping or darkwake. 
        
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
               	if is_display_asleep; then
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
                if [[ "$DARKWAKE_SENT" -eq 0 ]]; then
                    log_msg "Darkwake detected. Waiting 30s to settle before sleep."
				    sleep 30
				    if is_display_asleep; then
				        pmset sleepnow
				    else
				        log_msg "Aborted re-sleep, display is on (user woke system)."
				    fi
                    DARKWAKE_SENT=1
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
            DARKWAKE_SENT=0
            sudo pmset -a hibernatemode 3
            sudo pmset -a standbydelaylow 10800
            sudo pmset -a standbydelayhigh 86400
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
