# Kobo E-Ink Live Cast

Live-cast your desktop or application window to a remote kobo e-ink display over SSH, with automatic image processing and cursor visualization.

This script captures a specific window on your desktop, processes the image for optimal viewing on an e-ink display, and transmits it over SSH to a remote e-ink device (like a Kobo e-reader) for near real-time display using `fbink`.

## Features

*   **Window Casting:** Captures the currently active window.
*   **E-Ink Image Processing:** Optimizes the captured image using ImageMagick with configurable options:
    *   Contrast Stretching
    *   Gamma Correction
    *   Thresholding or Dithering (Floyd-Steinberg, Ordered Dither)
    *   Optional Despeckling
    *   Optional Image Negation (for white-on-black display)
*   **Cursor Visualization:** Optionally draws a cursor indicator on the e-ink display.
*   **Efficient Updates:**
    *   Uses image hashing to avoid unnecessary processing and uploads if the window content hasn't changed.
    *   Adjusts polling frequency based on user activity (mouse movement) to reduce CPU usage when idle.
*   **Persistent SSH Connection:** Uses SSH ControlMaster for faster and more efficient uploads.
*   **Automatic Reconnect:** Attempts to re-establish the SSH connection if uploads fail repeatedly.
*   **Timing Logs:** Records timing for different stages of the process in `/tmp/eink_display_timing.log` for debugging performance.
*   **Cross-Platform Support:** Works on both Linux and Windows systems.

## Requirements

### Host Machine (Where you run the script)

#### Linux Requirements:
*   **Shell:** A standard Unix shell (like `bash` or `zsh`).
*   **`ImageMagick`:** For image capture (`import`) and processing (`convert`).
    *   *Alternative:* `maim` can be used for screenshots by changing `screenshot_cmd`.
*   **`xdotool`:** To get the active window ID and mouse cursor position.
*   **`ssh` client:** For connecting to the remote device.
*   **`sshpass`:** To handle the SSH password non-interactively (required even for empty passwords in the current script setup). This can be changed to use key-based authentication by removing sshpass.
*   **`bc`:** For floating-point arithmetic used in timing and polling logic.

#### Windows Requirements:
*   **PowerShell 5.1 or later**
*   **ImageMagick:** For image processing (`convert`).
*   **OpenSSH Client:** For SSH connections (usually comes with Windows 10/11).
*   **sshpass:** For handling SSH passwords (can be installed via Chocolatey or other package managers).
*   **Windows Forms and Drawing assemblies:** These are included with .NET Framework.

### Remote E-Ink Device (e.g., Kobo)

*   **SSH Server:** Running and accessible from the host machine.
*   **`fbink`:** A command-line tool for drawing images directly to the Kobo framebuffer. (Ensure it's installed and in the `PATH` for the remote user).
*   **Network Connectivity:** The device must be on the same network as the host machine.

## Setup

### Linux Setup:
1.  **Clone/Download:** Get the `display.sh` script onto your host machine.
2.  **Install Host Dependencies:** Use your system's package manager (e.g., `apt`, `pacman`, `brew`) to install `imagemagick`, `xdotool`, `sshpass`, and `bc`.
    ```bash
    # Example for Debian/Ubuntu
    sudo apt update
    sudo apt install imagemagick xdotool sshpass bc

    # Example for Arch/Manjaro
    sudo pacman -Syu imagemagick xdotool sshpass bc
    ```

### Windows Setup:
1.  **Clone/Download:** Get the `display.ps1` script onto your host machine.
2.  **Install Dependencies:**
    ```powershell
    # Install ImageMagick using Chocolatey
    choco install imagemagick

    # Install sshpass using Chocolatey
    choco install sshpass

    # Install OpenSSH Client (if not already installed)
    Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
    ```
3.  **Enable Script Execution:**
    ```powershell
    # Run PowerShell as Administrator
    Set-ExecutionPolicy RemoteSigned
    ```

### Common Setup Steps:
1.  **Install Remote Dependencies:**
    *   Ensure an SSH server is running on your e-ink device.
    *   Install `fbink` on the e-ink device. Refer to `fbink` documentation or community guides for your specific device model.
2.  **Configure the Script:**
    *   Open either `display.sh` (Linux) or `display.ps1` (Windows) and modify the configuration variables near the top:
        *   `ip_last_part`: The script will prompt you for this, or you can hardcode the full `ip`.
        *   `width`, `height`: Set these to the screen resolution of your e-ink device.
        *   `password`: Set the SSH password for the remote user. **Leave empty (`""`) if using key-based authentication or no password.**
        *   `remote_user`: The username for SSH login on the e-ink device (often `root` for Kobo devices).
        *   `remote_port`: The SSH port on the remote device (usually `22`).
        *   Review and adjust the **Image Processing Settings** (`contrast_stretch_black`, `contrast_stretch_white`, `gamma`, `use_thresholding`, `threshold_level`, `dither_method`, `despeckle_output`, `negate_final`) to achieve the best visual result on your specific display.
        *   Review **Cursor Visualization** settings (`show_cursor`, `cursor_size`, `cursor_shape`).
        *   Review **Performance & Update Settings** (`active_polling_interval`, `idle_polling_interval`, `idle_threshold`).

## Usage

### Linux Usage:
1.  **Make the script executable:**
    ```bash
    chmod +x display.sh
    ```
2.  **Run the script:**
    ```bash
    ./display.sh
    ```

### Windows Usage:
1.  **Run the script:**
    ```powershell
    .\display.ps1
    ```

### Common Usage Steps:
1.  The script will prompt for the last part of the remote device's IP address.
2.  It will then attempt to establish a persistent SSH connection.
3.  Click on the window you want to cast to make it active.
4.  The script will start capturing the active window, processing the image, and sending it to the e-ink device.
5.  Press `Ctrl+C` in the terminal where the script is running to stop it and clean up the SSH connection.

## Configuration Details

*   **`ip`**: Target IP address of the e-ink device.
*   **`width`, `height`**: Resolution of the e-ink screen.
*   **`password`**: SSH password (use `""` for empty or key-based auth).
*   **`remote_user`, `remote_port`**: SSH connection details.
*   **`remote_tmp_img`**: Temporary location on the remote device to store the image before display.
*   **`ssh_control_path`**: Path for the SSH ControlMaster socket.
*   **Image Processing**:
    *   `contrast_stretch_black`/`white`: Adjust black/white points (%).
    *   `gamma`: Gamma correction value.
    *   `use_thresholding`: `1` for simple black/white thresholding, `0` for dithering.
    *   `threshold_level`: Cutoff percentage (0-100) if `use_thresholding=1`.
    *   `dither_method`: Dithering algorithm (e.g., `FloydSteinberg`, `o8x8`) if `use_thresholding=0`.
    *   `despeckle_output`: `1` to enable despeckle filter.
    *   `negate_final`: `1` for white-on-black output, `0` for black-on-white.
*   **Performance**:
    *   `active_polling_interval`: Update interval (seconds) when mouse activity is detected.
    *   `idle_polling_interval`: Update interval (seconds) after a period of inactivity.
    *   `idle_threshold`: Time (milliseconds) of inactivity before switching to `idle_polling_interval`.
*   **Cursor**:
    *   `show_cursor`: `1` to draw a cursor overlay, `0` to disable.
    *   `cursor_size`, `cursor_shape`: Appearance of the drawn cursor.

## Troubleshooting

### Common Issues:
*   **Connection Errors:**
    *   Verify the IP address, remote user, password, and port.
    *   Ensure the SSH server is running on the remote device.
    *   Check firewall rules on both host and remote device.
    *   Ensure `sshpass` is installed on the host.
*   **Image Not Displaying / Incorrect:**
    *   Verify `fbink` is installed correctly on the remote device and is in the `PATH`.
    *   Check if the `width` and `height` settings match your device.
    *   Adjust the image processing settings (`contrast`, `gamma`, `threshold`/`dither`, `negate`) for better results.
    *   Check the temporary file path (`remote_tmp_img`) has write permissions for the `remote_user`.
*   **Slow Performance:**
    *   Increase `active_polling_interval` and `idle_polling_interval`.
    *   Ensure the host machine has sufficient resources.
    *   Network latency can significantly impact performance. A wired connection or strong Wi-Fi signal is recommended.

### Linux-Specific Issues:
*   **`import: command not found` or `convert: command not found`:** Install `imagemagick`.
*   **`xdotool: command not found`:** Install `xdotool`.
*   **`sshpass: command not found`:** Install `sshpass`.
*   **`bc: command not found`:** Install `bc`.

### Windows-Specific Issues:
*   **PowerShell Execution Policy Error:**
    ```powershell
    Set-ExecutionPolicy RemoteSigned
    ```
*   **ImageMagick Not Found:**
    *   Ensure ImageMagick is installed and in your PATH
    *   Restart PowerShell after installation
*   **SSH Connection Issues:**
    *   Ensure OpenSSH Client is installed
    *   Check if sshpass is properly installed
    *   Verify SSH key permissions if using key-based authentication

## License

MIT