#!/bin/sh

# --- Configuration ---
echo "Please enter the last part of the IP address:"
read ip_last_part
ip="192.168.1.$ip_last_part"

# Target e-ink dimensions (Update if necessary)
width=1404
height=1872
password=""  # Empty password by default
remote_port="22"
remote_user="root"
remote_tmp_img="/tmp/eink_display.png" # Path on the remote device

# --- SSH Connection Settings ---
ssh_control_path="/tmp/ssh_control_${remote_user}@${ip}:${remote_port}"
ssh_connection_timeout=300  # 5 minutes
ssh_keepalive_interval=30000  # 5 minutes

# --- Image Processing Settings ---
# Adjust these for optimal appearance on your specific e-ink display
contrast_stretch_black=5    # % black point (Increase if blacks aren't black enough)
contrast_stretch_white=95    # % white point (Decrease if whites aren't white enough)
gamma=1.0                   # Usually 1.0 is fine with thresholding
use_thresholding=1          # Set to 1 to use threshold, 0 to use dithering
threshold_level=35          # % cutoff for thresholding (adjust 0-100)
# --- Dithering (only used if use_thresholding=0) ---
dither_method="FloydSteinberg" # 'FloydSteinberg', 'o8x8', etc. if thresholding is off
# --- General Processing ---
# Sharpening often increases noise - keep disabled unless needed
# sharpen_radius=0.5
# sharpen_amount=1.0
despeckle_output=0           # Set to 1 to enable despeckle filter (can help post-thresholding)
# Final output polarity: Set 'negate_final=1' for white-on-black, '0' for black-on-white
negate_final=1

# --- Performance & Update Settings ---
screenshot_cmd="import -window" # Or "maim -i"
active_polling_interval=0.1   # Poll every 100ms when active
idle_polling_interval=1       # Poll every 5s when idle
idle_threshold=30000           # 2 seconds before considering idle
last_activity_time=$(date +%s.%N)

# --- Cursor Visualization ---
show_cursor=1               # Set to 0 to disable cursor drawing
cursor_size=8
# Cursor color will be set dynamically based on negate_final
cursor_shape="circle"       # circle or cross

# --- Temporary Files ---
current_raw_image="/tmp/eink_current_raw.png"
processed_image="/tmp/eink_processed.png"
last_uploaded_image="/tmp/eink_last_uploaded.png"
timing_log="/tmp/eink_display_timing.log"
last_mouse_pos_file="/tmp/last_mouse_pos"

# --- Function Definitions ---

log_timing() {
    local event="$1"; local start_time="$2"; local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    printf "%s | %-25s | %.4fs\n" "$(date '+%Y-%m-%d %H:%M:%S.%N')" "$event" "$duration" >> "$timing_log"
}

get_cursor_position() {
    local start_time=$(date +%s.%N)
    local pos_output
    pos_output=$(xdotool getmouselocation --shell 2>/dev/null)
    local exit_code=$?
    log_timing "get_cursor_position" "$start_time"
    if [ $exit_code -eq 0 ] && [ -n "$pos_output" ]; then
        eval "$pos_output" # Sets X and Y
        echo "$X $Y"
    else
        echo "0 0"
    fi
}

check_user_activity() {
    local current_pos
    current_pos=$(xdotool getmouselocation --shell 2>/dev/null)
    if [ -n "$current_pos" ]; then
        if [ -f "$last_mouse_pos_file" ]; then
            if [ "$current_pos" != "$(cat "$last_mouse_pos_file")" ]; then
                echo "$current_pos" > "$last_mouse_pos_file"
                return 0
            fi
        else
            echo "$current_pos" > "$last_mouse_pos_file"
            return 0
        fi
    fi
    return 1
}

interruptible_sleep() {
    local duration=$1; local check_interval=0.05; local target_end_time
    target_end_time=$(echo "$(date +%s.%N) + $duration" | bc)
    while (( $(echo "$(date +%s.%N) < $target_end_time" | bc -l) )); do
        if check_user_activity; then
            last_activity_time=$(date +%s.%N); return 0
        fi
        sleep $check_interval
    done
    return 1
}

# Process image for E-Ink
process_image_for_eink() {
    local input_image="$1"; local output_image="$2"
    local start_time=$(date +%s.%N)

    # Combine all operations in a single ImageMagick command to avoid multiple processing passes
    local processing_steps="-colorspace Gray \
        -contrast-stretch ${contrast_stretch_black}%x${contrast_stretch_white}% \
        -gamma $gamma"

    # Add threshold or dither in same command
    if [ "$use_thresholding" -eq 1 ]; then
        processing_steps="$processing_steps -threshold ${threshold_level}%"
    else
        # Dithering
        if [ "$dither_method" = "FloydSteinberg" ]; then
             processing_steps="$processing_steps -dither FloydSteinberg -remap pattern:gray50"
        else
            processing_steps="$processing_steps -ordered-dither $dither_method"
        fi
    fi

    # Add optional despeckle
    if [ "$despeckle_output" -eq 1 ]; then
        processing_steps="$processing_steps -despeckle"
    fi

    # Add optional final negation in same command
    if [ "$negate_final" -eq 1 ]; then
        processing_steps="$processing_steps -negate"
    fi

    # Execute the conversion
    convert "$input_image" $processing_steps "$output_image"

    convert_status=$?
    log_timing "process_image_eink" "$start_time"
    return $convert_status
}

# Calculate image hash for more efficient change detection
calculate_image_hash() {
    local image="$1"
    identify -format "%#" "$image" 2>/dev/null
}

# Add cursor indicator to image
add_cursor_indicator() {
    local image="$1"; local cursor_x="$2"; local cursor_y="$3"
    local start_time=$(date +%s.%N)

    # Determine cursor color based on final image polarity
    local draw_color="black" # Default for black-on-white
    if [ "$negate_final" -eq 1 ]; then
        draw_color="black" # White cursor for white-on-black
    fi

    # Combine cursor drawing and rotation in a single command
    if [ "$cursor_shape" = "circle" ]; then
        convert "$image" -fill "$draw_color" -stroke none \
            -draw "circle $cursor_x,$cursor_y $((cursor_x + cursor_size)),$cursor_y" \
            -rotate 90 "$image"
    else # cross
        convert "$image" -fill none -stroke "$draw_color" -strokewidth 2 \
            -draw "line $((cursor_x - cursor_size)),$cursor_y $((cursor_x + cursor_size)),$cursor_y" \
            -draw "line $cursor_x,$((cursor_y - cursor_size)) $cursor_x,$((cursor_y + cursor_size))" \
            -rotate 90 "$image"
    fi

    log_timing "add_cursor_and_rotate" "$start_time"
}

# Initialize SSH connection
init_ssh_connection() {
    local start_time=$(date +%s.%N)
    if ! ssh -O check -o ControlPath="$ssh_control_path" "${remote_user}@${ip}" -p "$remote_port" >/dev/null 2>&1; then
        echo "[$(date +%T)] SSH Control Master not found or inactive, creating..."
        rm -f "$ssh_control_path"
        local ssh_cmd="ssh -fnN -M -S $ssh_control_path \
            -o ControlPersist=$ssh_connection_timeout \
            -o ServerAliveInterval=$ssh_keepalive_interval \
            -o ServerAliveCountMax=3 \
            -o ConnectTimeout=10 \
            -p $remote_port ${remote_user}@${ip}"

        # Always use sshpass with the empty password
        if ! command -v sshpass > /dev/null; then
            echo "[$(date +%T)] Error: 'sshpass' needed but not found." >&2; exit 1
        fi
        sshpass -p "$password" $ssh_cmd
        
        local ssh_init_status=$?
        sleep 1
        if [ $ssh_init_status -ne 0 ] || ! ssh -O check -o ControlPath="$ssh_control_path" "${remote_user}@${ip}" -p "$remote_port" >/dev/null 2>&1; then
             echo "[$(date +%T)] Error: Failed to establish persistent SSH connection." >&2
        else
             echo "[$(date +%T)] Persistent SSH connection established."
        fi
    fi
    log_timing "init_ssh_connection" "$start_time"
}

# Cleanup SSH connection
cleanup_ssh_connection() {
    echo "Closing SSH connection..."
    if [ -e "$ssh_control_path" ]; then
        ssh -O exit -o ControlPath="$ssh_control_path" "${remote_user}@${ip}" -p "$remote_port" >/dev/null 2>&1
    fi
    rm -f "$ssh_control_path" "$current_raw_image" "$processed_image" \
          "$last_uploaded_image" "$last_mouse_pos_file"
}

# Upload and display image using persistent connection
upload_and_display() {
    local image_path="$1"; local start_time=$(date +%s.%N)
    
    # Only initialize SSH connection if not already established
    if ! ssh -O check -o ControlPath="$ssh_control_path" "${remote_user}@${ip}" -p "$remote_port" >/dev/null 2>&1; then
        init_ssh_connection
    fi
    
    local scp_opts="-o ControlPath=$ssh_control_path -P $remote_port"
    local ssh_opts="-o ControlPath=$ssh_control_path -p $remote_port"
    local remote_target="${remote_user}@${ip}"
    local scp_cmd="scp $scp_opts $image_path ${remote_target}:${remote_tmp_img}"
    local ssh_cmd="ssh $ssh_opts ${remote_target}"
    local fbink_cmd="fbink -g file=${remote_tmp_img},w=$width,h=$height"

    # Always use sshpass with the empty password for SCP
    if ! command -v sshpass > /dev/null; then
        echo "[$(date +%T)] Error: 'sshpass' needed but not found." >&2; exit 1
    fi
    
    # Try to upload image with compression to reduce transfer time
    if sshpass -p "$password" $scp_cmd; then
        if sshpass -p "$password" $ssh_cmd "$fbink_cmd > /dev/null 2>&1"; then
             log_timing "upload_and_display_success" "$start_time"
             cp -p "$image_path" "$last_uploaded_image"
        else
            echo "[$(date +%T)] Error: Failed displaying image on remote device via SSH." >&2
            log_timing "display_FAIL" "$start_time"
        fi
    else
        echo "[$(date +%T)] Error: Failed uploading image via SCP." >&2
        log_timing "upload_FAIL" "$start_time"
    fi
}

# --- Main Loop ---
echo "Starting e-ink display script. Press Ctrl+C to stop."
rm -f "$current_raw_image" "$processed_image" "$last_uploaded_image" \
      "$last_mouse_pos_file" "$timing_log"
# Initialize SSH connection once at startup
init_ssh_connection
trap 'cleanup_ssh_connection; echo "Exiting script."; exit 0' INT TERM EXIT HUP

# Variables for tracking image changes
last_image_hash=""
frames_skipped=0
consecutive_upload_failures=0

while true; do
    loop_start_time=$(date +%s.%N)
    
    # Adjust polling interval based on activity
    current_polling_interval=$idle_polling_interval
    if check_user_activity; then
        current_polling_interval=$active_polling_interval
        last_activity_time=$(date +%s.%N)
    else
        current_time=$(date +%s.%N)
        time_since_activity=$(echo "($current_time - $last_activity_time) * 1000 / 1" | bc)
        if [ "$time_since_activity" -lt "$idle_threshold" ]; then
            current_polling_interval=$active_polling_interval
        fi
    fi

    # Capture the current screen
    capture_start_time=$(date +%s.%N)
    active_win_id=$(xdotool getactivewindow 2>/dev/null)
    if [ -z "$active_win_id" ]; then
        echo "[$(date +%T)] Error: Could not get active window ID." >&2; sleep 2; continue
    fi
    if ! $screenshot_cmd "$active_win_id" "$current_raw_image"; then
        echo "[$(date +%T)] Error capturing window ID $active_win_id." >&2; log_timing "capture_FAIL" "$capture_start_time"; sleep 0.5; continue
    fi
    log_timing "window_capture" "$capture_start_time"

    # Check if raw image has changed significantly
    current_hash=$(calculate_image_hash "$current_raw_image")
    
    # Skip processing if image hasn't changed and we're not moving the cursor
    if [ "$current_hash" = "$last_image_hash" ] && [ "$frames_skipped" -lt 10 ]; then
        frames_skipped=$((frames_skipped + 1))
        log_timing "skipped_unchanged_frame" "$loop_start_time"
        sleep $current_polling_interval
        continue
    fi
    
    frames_skipped=0
    last_image_hash="$current_hash"
    read cursor_x cursor_y <<< $(get_cursor_position)

    if ! process_image_for_eink "$current_raw_image" "$processed_image"; then
         echo "[$(date +%T)] Error processing image. Skipping frame." >&2; continue
    fi

    if [ "$show_cursor" -eq 1 ]; then
        add_cursor_indicator "$processed_image" "$cursor_x" "$cursor_y"
    else
        # If cursor is not shown, still need to rotate the image
        rotate_start_time=$(date +%s.%N)
        convert "$processed_image" -rotate 90 "$processed_image"
        log_timing "rotate_image" "$rotate_start_time"
    fi

    upload_this_cycle=0
    if [ ! -f "$last_uploaded_image" ] || ! cmp -s "$processed_image" "$last_uploaded_image"; then
        upload_this_cycle=1
    fi

    if [ "$upload_this_cycle" -eq 1 ]; then
        upload_and_display "$processed_image"
        if [ $? -ne 0 ]; then
            consecutive_upload_failures=$((consecutive_upload_failures + 1))
            if [ $consecutive_upload_failures -ge 3 ]; then
                echo "[$(date +%T)] Multiple upload failures, recreating SSH connection" >&2
                ssh -O exit -o ControlPath="$ssh_control_path" "${remote_user}@${ip}" -p "$remote_port" >/dev/null 2>&1
                rm -f "$ssh_control_path"
                init_ssh_connection
                consecutive_upload_failures=0
            fi
        else
            consecutive_upload_failures=0
        fi
    fi

    log_timing "total_loop" "$loop_start_time"

    sleep_start_time=$(date +%s.%N)
    if (( $(echo "$current_polling_interval > 0.1" | bc -l) )); then
         interruptible_sleep "$current_polling_interval"
    else
         sleep "$current_polling_interval"
    fi
     log_timing "sleep_wait" "$sleep_start_time"
done

exit 0