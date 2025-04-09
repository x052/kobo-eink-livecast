# --- Configuration ---
$ip_last_part = Read-Host "Please enter the last part of the IP address"
$ip = "192.168.1.$ip_last_part"

# Target e-ink dimensions (Update if necessary)
$width = 1404
$height = 1872
$password = ""  # Empty password by default
$remote_port = "22"
$remote_user = "root"
$remote_tmp_img = "/tmp/eink_display.png" # Path on the remote device

# --- SSH Connection Settings ---
$ssh_control_path = "/tmp/ssh_control_${remote_user}@${ip}:${remote_port}"
$ssh_connection_timeout = 300  # 5 minutes
$ssh_keepalive_interval = 30000  # 5 minutes

# --- Image Processing Settings ---
# Adjust these for optimal appearance on your specific e-ink display
$contrast_stretch_black = 5    # % black point (Increase if blacks aren't black enough)
$contrast_stretch_white = 95    # % white point (Decrease if whites aren't white enough)
$gamma = 1.0                   # Usually 1.0 is fine with thresholding
$use_thresholding = 1          # Set to 1 to use threshold, 0 to use dithering
$threshold_level = 35          # % cutoff for thresholding (adjust 0-100)
# --- Dithering (only used if use_thresholding=0) ---
$dither_method = "FloydSteinberg" # 'FloydSteinberg', 'o8x8', etc. if thresholding is off
# --- General Processing ---
$despeckle_output = 0           # Set to 1 to enable despeckle filter (can help post-thresholding)
$negate_final = 1              # Final output polarity: Set '1' for white-on-black, '0' for black-on-white

# --- Performance & Update Settings ---
$active_polling_interval = 0.1   # Poll every 100ms when active
$idle_polling_interval = 1       # Poll every 5s when idle
$idle_threshold = 30000           # 2 seconds before considering idle
$last_activity_time = Get-Date

# --- Cursor Visualization ---
$show_cursor = 1               # Set to 0 to disable cursor drawing
$cursor_size = 8
$cursor_shape = "circle"       # circle or cross

# --- Temporary Files ---
$current_raw_image = "/tmp/eink_current_raw.png"
$processed_image = "/tmp/eink_processed.png"
$last_uploaded_image = "/tmp/eink_last_uploaded.png"
$timing_log = "/tmp/eink_display_timing.log"
$last_mouse_pos_file = "/tmp/last_mouse_pos"

# --- Function Definitions ---

function Log-Timing {
    param (
        [string]$event,
        [DateTime]$start_time
    )
    $end_time = Get-Date
    $duration = ($end_time - $start_time).TotalSeconds
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') | $($event.PadRight(25)) | $($duration.ToString('F4'))s" | Out-File -FilePath $timing_log -Append
}

function Get-CursorPosition {
    $start_time = Get-Date
    try {
        $pos = [System.Windows.Forms.Cursor]::Position
        Log-Timing "get_cursor_position" $start_time
        return "$($pos.X) $($pos.Y)"
    }
    catch {
        Log-Timing "get_cursor_position" $start_time
        return "0 0"
    }
}

function Check-UserActivity {
    $current_pos = Get-CursorPosition
    if (Test-Path $last_mouse_pos_file) {
        $last_pos = Get-Content $last_mouse_pos_file
        if ($current_pos -ne $last_pos) {
            $current_pos | Out-File -FilePath $last_mouse_pos_file
            return $true
        }
    }
    else {
        $current_pos | Out-File -FilePath $last_mouse_pos_file
        return $true
    }
    return $false
}

function Interruptible-Sleep {
    param (
        [double]$duration
    )
    $check_interval = 0.05
    $target_end_time = (Get-Date).AddSeconds($duration)
    
    while ((Get-Date) -lt $target_end_time) {
        if (Check-UserActivity) {
            $script:last_activity_time = Get-Date
            return $true
        }
        Start-Sleep -Milliseconds ($check_interval * 1000)
    }
    return $false
}

function Process-ImageForEink {
    param (
        [string]$input_image,
        [string]$output_image
    )
    $start_time = Get-Date

    # Combine all operations in a single ImageMagick command
    $processing_steps = "-colorspace Gray -contrast-stretch ${contrast_stretch_black}%x${contrast_stretch_white}% -gamma $gamma"

    if ($use_thresholding -eq 1) {
        $processing_steps += " -threshold ${threshold_level}%"
    }
    else {
        if ($dither_method -eq "FloydSteinberg") {
            $processing_steps += " -dither FloydSteinberg -remap pattern:gray50"
        }
        else {
            $processing_steps += " -ordered-dither $dither_method"
        }
    }

    if ($despeckle_output -eq 1) {
        $processing_steps += " -despeckle"
    }

    if ($negate_final -eq 1) {
        $processing_steps += " -negate"
    }

    # Execute the conversion
    $result = & convert $input_image $processing_steps $output_image
    $convert_status = $LASTEXITCODE

    Log-Timing "process_image_eink" $start_time
    return $convert_status -eq 0
}

function Calculate-ImageHash {
    param (
        [string]$image
    )
    try {
        return (Get-FileHash -Path $image -Algorithm SHA256).Hash
    }
    catch {
        return $null
    }
}

function Add-CursorIndicator {
    param (
        [string]$image,
        [int]$cursor_x,
        [int]$cursor_y
    )
    $start_time = Get-Date

    $draw_color = if ($negate_final -eq 1) { "black" } else { "black" }

    if ($cursor_shape -eq "circle") {
        & convert $image -fill $draw_color -stroke none `
            -draw "circle $cursor_x,$cursor_y $($cursor_x + $cursor_size),$cursor_y" `
            -rotate 90 $image
    }
    else {
        & convert $image -fill none -stroke $draw_color -strokewidth 2 `
            -draw "line $($cursor_x - $cursor_size),$cursor_y $($cursor_x + $cursor_size),$cursor_y" `
            -draw "line $cursor_x,$($cursor_y - $cursor_size) $cursor_x,$($cursor_y + $cursor_size)" `
            -rotate 90 $image
    }

    Log-Timing "add_cursor_and_rotate" $start_time
}

function Initialize-SshConnection {
    $start_time = Get-Date
    $check_cmd = "ssh -O check -o ControlPath=`"$ssh_control_path`" ${remote_user}@${ip} -p $remote_port 2>&1"
    $check_result = Invoke-Expression $check_cmd

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] SSH Control Master not found or inactive, creating..."
        Remove-Item -Path $ssh_control_path -ErrorAction SilentlyContinue

        $ssh_cmd = "ssh -fnN -M -S $ssh_control_path " +
            "-o ControlPersist=$ssh_connection_timeout " +
            "-o ServerAliveInterval=$ssh_keepalive_interval " +
            "-o ServerAliveCountMax=3 " +
            "-o ConnectTimeout=10 " +
            "-p $remote_port ${remote_user}@${ip}"

        if (-not (Get-Command sshpass -ErrorAction SilentlyContinue)) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Error: 'sshpass' needed but not found." -ForegroundColor Red
            exit 1
        }

        $ssh_init_result = & sshpass -p $password $ssh_cmd
        Start-Sleep -Seconds 1

        if ($LASTEXITCODE -ne 0 -or (Invoke-Expression $check_cmd).ExitCode -ne 0) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Error: Failed to establish persistent SSH connection." -ForegroundColor Red
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Persistent SSH connection established."
        }
    }
    Log-Timing "init_ssh_connection" $start_time
}

function Cleanup-SshConnection {
    Write-Host "Closing SSH connection..."
    if (Test-Path $ssh_control_path) {
        & ssh -O exit -o ControlPath="$ssh_control_path" "${remote_user}@${ip}" -p "$remote_port" 2>&1 | Out-Null
    }
    Remove-Item -Path $ssh_control_path, $current_raw_image, $processed_image, $last_uploaded_image, $last_mouse_pos_file -ErrorAction SilentlyContinue
}

function Upload-AndDisplay {
    param (
        [string]$image_path
    )
    $start_time = Get-Date

    if (-not (Test-SshConnection)) {
        Initialize-SshConnection
    }

    $scp_opts = "-o ControlPath=$ssh_control_path -P $remote_port"
    $ssh_opts = "-o ControlPath=$ssh_control_path -p $remote_port"
    $remote_target = "${remote_user}@${ip}"
    $scp_cmd = "scp $scp_opts $image_path ${remote_target}:${remote_tmp_img}"
    $ssh_cmd = "ssh $ssh_opts ${remote_target}"
    $fbink_cmd = "fbink -g file=${remote_tmp_img},w=$width,h=$height"

    if (-not (Get-Command sshpass -ErrorAction SilentlyContinue)) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Error: 'sshpass' needed but not found." -ForegroundColor Red
        exit 1
    }

    $upload_result = & sshpass -p $password $scp_cmd
    if ($LASTEXITCODE -eq 0) {
        $display_result = & sshpass -p $password $ssh_cmd $fbink_cmd 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log-Timing "upload_and_display_success" $start_time
            Copy-Item -Path $image_path -Destination $last_uploaded_image -Force
            return $true
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Error: Failed displaying image on remote device via SSH." -ForegroundColor Red
            Log-Timing "display_FAIL" $start_time
        }
    }
    else {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Error: Failed uploading image via SCP." -ForegroundColor Red
        Log-Timing "upload_FAIL" $start_time
    }
    return $false
}

function Test-SshConnection {
    $check_cmd = "ssh -O check -o ControlPath=`"$ssh_control_path`" ${remote_user}@${ip} -p $remote_port 2>&1"
    return (Invoke-Expression $check_cmd).ExitCode -eq 0
}

# --- Main Loop ---
Write-Host "Starting e-ink display script. Press Ctrl+C to stop."
Remove-Item -Path $current_raw_image, $processed_image, $last_uploaded_image, $last_mouse_pos_file, $timing_log -ErrorAction SilentlyContinue

# Initialize SSH connection once at startup
Initialize-SshConnection

# Set up cleanup on script termination
$cleanup = {
    Cleanup-SshConnection
    Write-Host "Exiting script."
    exit 0
}
[Console]::TreatControlCAsInput = $true
$Host.UI.RawUI.FlushInputBuffer()

# Variables for tracking image changes
$last_image_hash = ""
$frames_skipped = 0
$consecutive_upload_failures = 0

while ($true) {
    $loop_start_time = Get-Date

    # Check for Ctrl+C
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
            & $cleanup
        }
    }

    # Adjust polling interval based on activity
    $current_polling_interval = $idle_polling_interval
    if (Check-UserActivity) {
        $current_polling_interval = $active_polling_interval
        $last_activity_time = Get-Date
    }
    else {
        $time_since_activity = ((Get-Date) - $last_activity_time).TotalMilliseconds
        if ($time_since_activity -lt $idle_threshold) {
            $current_polling_interval = $active_polling_interval
        }
    }

    # Capture the current screen
    $capture_start_time = Get-Date
    try {
        # Using Windows.Forms to capture screen
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save($current_raw_image, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bitmap.Dispose()
        Log-Timing "window_capture" $capture_start_time
    }
    catch {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Error capturing screen." -ForegroundColor Red
        Log-Timing "capture_FAIL" $capture_start_time
        Start-Sleep -Seconds 0.5
        continue
    }

    # Check if raw image has changed significantly
    $current_hash = Calculate-ImageHash $current_raw_image

    # Skip processing if image hasn't changed and we're not moving the cursor
    if ($current_hash -eq $last_image_hash -and $frames_skipped -lt 10) {
        $frames_skipped++
        Log-Timing "skipped_unchanged_frame" $loop_start_time
        Start-Sleep -Seconds $current_polling_interval
        continue
    }

    $frames_skipped = 0
    $last_image_hash = $current_hash
    $cursor_pos = Get-CursorPosition -split ' '
    $cursor_x = [int]$cursor_pos[0]
    $cursor_y = [int]$cursor_pos[1]

    if (-not (Process-ImageForEink $current_raw_image $processed_image)) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Error processing image. Skipping frame." -ForegroundColor Red
        continue
    }

    if ($show_cursor -eq 1) {
        Add-CursorIndicator $processed_image $cursor_x $cursor_y
    }
    else {
        $rotate_start_time = Get-Date
        & convert $processed_image -rotate 90 $processed_image
        Log-Timing "rotate_image" $rotate_start_time
    }

    $upload_this_cycle = $false
    if (-not (Test-Path $last_uploaded_image) -or -not (Compare-Object (Get-Content $processed_image) (Get-Content $last_uploaded_image))) {
        $upload_this_cycle = $true
    }

    if ($upload_this_cycle) {
        if (-not (Upload-AndDisplay $processed_image)) {
            $consecutive_upload_failures++
            if ($consecutive_upload_failures -ge 3) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Multiple upload failures, recreating SSH connection" -ForegroundColor Red
                & ssh -O exit -o ControlPath="$ssh_control_path" "${remote_user}@${ip}" -p "$remote_port" 2>&1 | Out-Null
                Remove-Item -Path $ssh_control_path -ErrorAction SilentlyContinue
                Initialize-SshConnection
                $consecutive_upload_failures = 0
            }
        }
        else {
            $consecutive_upload_failures = 0
        }
    }

    Log-Timing "total_loop" $loop_start_time

    $sleep_start_time = Get-Date
    if ($current_polling_interval -gt 0.1) {
        Interruptible-Sleep $current_polling_interval
    }
    else {
        Start-Sleep -Seconds $current_polling_interval
    }
    Log-Timing "sleep_wait" $sleep_start_time
}

exit 0 