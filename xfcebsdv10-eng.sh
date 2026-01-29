#!/bin/sh

readonly BSDDIALOG_OK=0
readonly BSDDIALOG_YES=$BSDDIALOG_OK
readonly BSDDIALOG_NO=1

DIALOG=bsddialog
LOGFILE="/tmp/freebsd-desktop-install.log"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

# Package installation function with error handling
install_pkg() {
    local pkgs="$*"
    local tmplog="/tmp/pkg-install-$$.log"
    local exitcode_file="/tmp/pkg-exit-$$.code"
    
    log ">>> Install: $pkgs"
    echo ""
    echo "=========================================="
    echo ">>> Install: $pkgs"
    echo "=========================================="
    echo ""
    
    # Execute pkg install:
    # 1. Show output on screen AND save it to log (using tee)
    # 2. Capture pkg error code in a temporary file
    (pkg install -y $pkgs 2>&1; echo $? > "$exitcode_file") | tee "$tmplog"
    
    # Read the captured exit code
    local pkg_exit=$(cat "$exitcode_file")
    rm -f "$exitcode_file"

    # Append temporary log to main log
    cat "$tmplog" >> "$LOGFILE"
    rm -f "$tmplog"

    if [ "$pkg_exit" -eq 0 ]; then
        log "OK: Packages installed successfully"
        echo ""
        echo "✓ Installation Complete"
        echo ""
        sleep 1
        return 0
    else
        log "ERROR: Installation failed (exit code: $pkg_exit) per: $pkgs"
        echo ""
        echo "✗ ERROR during installation (exit code: $pkg_exit)"
        echo ""
        if which $DIALOG > /dev/null 2>&1; then
            $DIALOG --title "Error Installation" \
                --msgbox "Error during installation:\n$pkgs\n\nCode error: $pkg_exit\nCheck log: $LOGFILE" 0 0
        fi
        return 1
    fi
}

# Virtual Machine detection function
detect_vm_type() {
    # Check sysctl
    local vm_guest=$(sysctl -n kern.vm_guest 2>/dev/null)
    if [ -n "$vm_guest" ] && [ "$vm_guest" != "none" ]; then
        echo "$vm_guest"
        return 0
    fi
    
    # Check dmesg for hypervisor
    if dmesg | grep -qi "Hypervisor: Origin.*KVMKVMKVM"; then
        echo "kvm"
        return 0
    elif dmesg | grep -qi "Hypervisor: Origin.*Microsoft Hv"; then
        echo "hyperv"
        return 0
    elif dmesg | grep -qi "Hypervisor: Origin.*VMwareVMware"; then
        echo "vmware"
        return 0
    elif dmesg | grep -qi "Hypervisor: Origin.*XenVMMXenVMM"; then
        echo "xen"
        return 0
    fi
    
    # Additional QEMU/KVM detection methods
    if dmesg | grep -qiE "QEMU|virtio"; then
        echo "kvm"
        return 0
    fi
    
    # Check hw.model
    if sysctl -n hw.model 2>/dev/null | grep -qi "qemu"; then
        echo "kvm"
        return 0
    fi
    
    # Check for virtio devices
    if pciconf -lv 2>/dev/null | grep -qi "virtio"; then
        echo "kvm"
        return 0
    fi
    
    # Fallback to none
    echo "none"
    return 1
}


# --- 1. PRELIMINARY CHECKS ---

> "$LOGFILE"
log "=== Starting FreeBSD Desktop installation ==="

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run this script as root"
    exit 1
fi

# Install bsddialog if not present
if ! which $DIALOG > /dev/null 2>&1; then
    log "Installing bsddialog..."
    pkg install -y bsddialog
fi

# Check hostname
if [ -z "$(hostname)" ]; then
    $DIALOG --title "Hostname Required" \
        --msgbox "Configure a hostname before continuing.\n\nExample:\n  hostname mypc.local\n  sysrc hostname=\"mypc\"" 0 0
    exit 1
fi

# Check internet connection
log "Checking internet connection..."
echo "Testing internet connectivity (ping 8.8.8.8)..."
if ! ping -c 1 -t 5 8.8.8.8; then
    $DIALOG --title "Connection Error" \
        --msgbox "No internet connection.\n\nConfigure network and try again." 0 0
    exit 1
fi
echo "✓ Internet connection OK"
echo ""

# --- SMART TIME CHECK ---
log "Checking time offset..."
echo "Verifying time against NTP server..."

# 1. Query server without setting time (-q)
# Output format: "... offset -123.456 sec"
ntp_output=$(ntpdate -q 0.freebsd.pool.ntp.org 2>/dev/null | tail -n 1)

# Extract offset
offset=$(echo "$ntp_output" | awk '{ print $(NF-1) }')

if [ -n "$offset" ]; then
    # 2. Check if difference is > 180 seconds (3 mins) using awk
    # Returns 1 if diff > 180, else 0
    needs_sync=$(echo "$offset" | awk '{ if ($1 < 0) $1 = -$1; if ($1 > 180) print 1; else print 0; }')

    if [ "$needs_sync" -eq 1 ]; then
        log "Significant time offset detected: ${offset}s"
        
        # 3. Propose sync to user
        $DIALOG --title "System Time Mismatch" \
            --yesno "System time differs by approx $offset seconds from server.\n\nSynchronize now?\n(Recommended to avoid SSL package errors)" 0 0
        
        if [ $? -eq $BSDDIALOG_YES ]; then
            log "User accepted time sync."
            echo "Synchronizing time..."
            service ntpd stop >/dev/null 2>&1
            ntpd -g -q >/dev/null 2>&1
            sysrc ntpd_enable="YES" >/dev/null 2>&1
            sysrc ntpd_sync_on_start="YES" >/dev/null 2>&1
            log "Time updated: $(date)"
            echo "✓ Time synchronized."
        else
            log "User declined time sync."
        fi
    else
        log "Time is in sync (diff: ${offset}s). No action needed."
        echo "✓ Time correct (offset: ${offset}s)"
    fi
else
    log "Could not query NTP server."
    echo "⚠ NTP check failed (proceeding)"
fi
echo ""

# Initialize pkg
if ! pkg -N >/dev/null 2>&1; then
    log "Initializing pkg..."
    pkg bootstrap -y
fi

# Check if repository is up to date (check catalog age)
CATALOG_AGE=$(find /var/db/pkg/repo-*.sqlite 2>/dev/null -mmin +1440 | wc -l)

if [ "$CATALOG_AGE" -gt 0 ] || [ ! -f /var/db/pkg/repo-*.sqlite 2>/dev/null ]; then
    # Catalog older than 24 hours or missing -> automatic update
    log "Updating repository (catalog old or missing)..."
    echo "Updating FreeBSD package repository..."
    if ! pkg update; then
        $DIALOG --title "Repository Error" \
            --msgbox "Cannot update pkg repositories.\n\nCheck connection." 0 0
        exit 1
    fi
else
    log "Repository already up to date, skipping update"
    echo "✓ Repository already up to date (< 24 hours)"
    echo ""
fi

# Checking disk space...sponibile
log "Checking disk space..."
MIN_SPACE_GB=5
available_space=$(df -g / | awk 'NR==2 {print $4}')
if [ "$available_space" -lt "$MIN_SPACE_GB" ]; then
    $DIALOG --title "Insufficient Disk Space" \
        --msgbox "Available space: ${available_space}GB\nMinimum required: ${MIN_SPACE_GB}GB\n\nFree up space and try again." 0 0
    exit 1
fi
log "Available space: ${available_space}GB"

# --- 2. HARDWARE DETECTION ---

log "Detecting hardware..."

# Boot method
BOOTMETHOD=$(sysctl -n machdep.bootmethod 2>/dev/null || echo "BIOS")
log "Boot method: $BOOTMETHOD"

# Laptop detection
IS_LAPTOP="NO"
if sysctl -n hw.acpi.battery.units >/dev/null 2>&1; then
    BATTERY=$(sysctl -n hw.acpi.battery.units 2>/dev/null || echo 0)
    [ "$BATTERY" -gt 0 ] && IS_LAPTOP="YES"
fi
log "System type: $([ "$IS_LAPTOP" = "YES" ] && echo "Laptop" || echo "Desktop")"

# SSD detection
HAS_SSD="NO"
camcontrol devlist 2>/dev/null | grep -qi "ssd\|solid state\|nvme" && HAS_SSD="YES"
log "Storage: $([ "$HAS_SSD" = "YES" ] && echo "SSD" || echo "HDD")"

# GPU detection
VGA_INFO=$(pciconf -lv | grep -A 4 vga)
PCI_FULL=$(pciconf -lv)
AUTO_GPU="Generic"
VM_TYPE=$(detect_vm_type)

log "VM Type detected: $VM_TYPE"

# Priority 1: Check for virtualization-specific GPUs first
if echo "$VGA_INFO" | grep -qi "qxl"; then
    AUTO_GPU="QEMU"
    log "Detected QXL video device"
elif echo "$VGA_INFO" | grep -qi "virtio"; then
    AUTO_GPU="QEMU"
    log "Detected VirtIO GPU"
elif echo "$VGA_INFO" | grep -q "vendor.*0x1234"; then
    # QEMU standard VGA (vendor ID 0x1234, device 0x1111)
    AUTO_GPU="QEMU"
    log "Detected QEMU standard VGA (vendor 0x1234)"
elif echo "$PCI_FULL" | grep -qi "qxl"; then
    AUTO_GPU="QEMU"
    log "Detected QXL device in PCI"
elif echo "$PCI_FULL" | grep -qi "virtio.*display\|virtio.*vga\|virtio.*gpu"; then
    AUTO_GPU="QEMU"
    log "Detected VirtIO display device"
elif echo "$VGA_INFO" | grep -qi "vmware"; then
    AUTO_GPU="VMware"
elif echo "$VGA_INFO" | grep -qi "virtualbox"; then
    AUTO_GPU="VirtualBox"
elif echo "$VGA_INFO" | grep -qi "hyperv\|hyper-v"; then
    AUTO_GPU="HyperV"
# Priority 2: If VM detected but no specific GPU, match by VM type
elif [ "$VM_TYPE" = "kvm" ] || [ "$VM_TYPE" = "qemu" ]; then
    AUTO_GPU="QEMU"
    log "QEMU/KVM detected via VM type, using QEMU driver"
elif [ "$VM_TYPE" = "hyperv" ]; then
    AUTO_GPU="HyperV"
    log "Hyper-V detected via VM type"
elif [ "$VM_TYPE" = "vmware" ]; then
    AUTO_GPU="VMware"
    log "VMware detected via VM type"
# Priority 3: Physical hardware GPUs
elif echo "$VGA_INFO" | grep -qi "intel"; then
    AUTO_GPU="Intel"
elif echo "$VGA_INFO" | grep -qi "nvidia"; then
    AUTO_GPU="NVIDIA"
elif echo "$VGA_INFO" | grep -qi "amd\|ati\|radeon"; then
    if echo "$VGA_INFO" | grep -qiE "HD [7-9][0-9]{3}|R[5-9]|RX|Vega|Navi"; then
        AUTO_GPU="AMD"
    else
        AUTO_GPU="Radeon"
    fi
fi

log "GPU detected: $AUTO_GPU"

SYSINFO="System: $([ "$IS_LAPTOP" = "YES" ] && echo "Laptop" || echo "Desktop")
Storage: $([ "$HAS_SSD" = "YES" ] && echo "SSD" || echo "HDD")
Boot: $BOOTMETHOD
GPU detected: $AUTO_GPU"

# --- 3. DESKTOP ENVIRONMENT SELECTION ---

DE_CHOICE=$($DIALOG --title "Desktop Environment" \
    --extra-button --extra-label "System Info" \
    --radiolist "Choose desktop environment:" 12 60 3 \
    "XFCE"  "Lightweight and fast (Recommended)" on \
    "KDE"   "Modern and elegant" off \
    "GNOME" "Complete experience" off \
    3>&1 1>&2 2>&3 3>&-)

exit_status=$?

# Se premuto "System Info"
if [ $exit_status -eq 3 ]; then
    $DIALOG --title "System Information" --msgbox "$SYSINFO" 0 0
    exec "$0"  # Riavvia script
fi

[ $exit_status -ne $BSDDIALOG_OK ] && exit 1
[ -z "$DE_CHOICE" ] && exit 0

log "Desktop selected: $DE_CHOICE"

# --- 4. LANGUAGE SELECTION ---

LOCALE_CHOICE=$($DIALOG --title "Desktop Language" \
    --radiolist "Select language:" 18 50 10 \
    "it_IT.UTF-8" "Italian" on \
    "en_US.UTF-8" "English (US)" off \
    "en_GB.UTF-8" "English (UK)" off \
    "de_DE.UTF-8" "German" off \
    "fr_FR.UTF-8" "French" off \
    "es_ES.UTF-8" "Spanish" off \
    "pt_BR.UTF-8" "Portuguese" off \
    "ru_RU.UTF-8" "Russian" off \
    "ja_JP.UTF-8" "Japanese" off \
    "zh_CN.UTF-8" "Chinese" off \
    3>&1 1>&2 2>&3 3>&-)

[ $? -ne $BSDDIALOG_OK ] && exit 1
[ -z "$LOCALE_CHOICE" ] && LOCALE_CHOICE="en_US.UTF-8"

LANG_CODE=$(echo "$LOCALE_CHOICE" | cut -d'_' -f1)
log "Language selected: $LOCALE_CHOICE"

# Language -> keyboard layout mapping
case $LANG_CODE in
    it) KB_LAYOUT="it" ;;
    de) KB_LAYOUT="de" ;;
    fr) KB_LAYOUT="fr" ;;
    es) KB_LAYOUT="es" ;;
    pt) KB_LAYOUT="pt" ;;
    ru) KB_LAYOUT="ru" ;;
    ja) KB_LAYOUT="jp" ;;
    zh) KB_LAYOUT="cn" ;;
    en)
        # Distinguish US/UK
        case $LOCALE_CHOICE in
            en_GB*) KB_LAYOUT="gb" ;;
            *) KB_LAYOUT="us" ;;
        esac
        ;;
    *) KB_LAYOUT="us" ;;
esac

log "Keyboard layout: $KB_LAYOUT"

# --- 5. VIDEO DRIVER SELECTION ---

# Set suggestion
case $AUTO_GPU in
    Intel) D_INTEL="on" ;;
    AMD) D_AMD="on" ;;
    Radeon) D_RADEON="on" ;;
    NVIDIA) D_NVIDIA="on" ;;
    VirtualBox) D_VBOX="on" ;;
    VMware) D_VMWARE="on" ;;
    QEMU) D_QEMU="on" ;;
    HyperV) D_HYPERV="on" ;;
    *)
        if [ "$BOOTMETHOD" = "UEFI" ]; then
            D_SCFB="on"
        else
            D_VESA="on"
        fi
        ;;
esac

gpu=$($DIALOG --title "Video Driver" \
    --radiolist "Video driver (suggested: $AUTO_GPU):" 16 60 10 \
    "Intel"      "Intel HD Graphics" ${D_INTEL:-off} \
    "AMD"        "AMD Radeon (modern)" ${D_AMD:-off} \
    "Radeon"     "AMD legacy" ${D_RADEON:-off} \
    "NVIDIA"     "NVIDIA" ${D_NVIDIA:-off} \
    "VirtualBox" "VirtualBox Guest" ${D_VBOX:-off} \
    "VMware"     "VMware Guest" ${D_VMWARE:-off} \
    "QEMU"       "QEMU/KVM" ${D_QEMU:-off} \
    "HyperV"     "Hyper-V Guest" ${D_HYPERV:-off} \
    "SCFB"       "UEFI Framebuffer" ${D_SCFB:-off} \
    "VESA"       "VESA BIOS" ${D_VESA:-off} \
    3>&1 1>&2 2>&3 3>&-)

[ $? -ne $BSDDIALOG_OK ] && exit 1
[ -z "$gpu" ] && exit 0

log "Driver video selezionato: $gpu"

# --- 6. VIDEO DRIVER CONFIGURATION ---

GPU_PKGS=""
GPU_KMOD=""
GPU_LOADER=""

case $gpu in
    Intel)
        GPU_PKGS="drm-kmod mesa-gallium-va libva-utils libva-intel-media-driver"
        GPU_KMOD="i915kms"
        ;;
    AMD)
        GPU_PKGS="drm-kmod mesa-gallium-va libva-utils"
        GPU_KMOD="amdgpu"
        ;;
    Radeon)
        GPU_PKGS="drm-kmod mesa-gallium-va libva-utils"
        GPU_KMOD="radeonkms"
        ;;
    NVIDIA)
        # Ask which NVIDIA version
        NV_VER=$($DIALOG --title "NVIDIA Driver" \
            --radiolist "Driver version:" 10 50 3 \
            "latest" "Latest version" on \
            "470"    "Legacy 470" off \
            "390"    "Legacy 390" off \
            3>&1 1>&2 2>&3 3>&-)
        
        case $NV_VER in
            latest) 
                GPU_PKGS="nvidia-drm-kmod"
                GPU_KMOD="nvidia-drm"
                GPU_LOADER='hw.nvidiadrm.modeset="1"'
                ;;
            470) 
                GPU_PKGS="nvidia-driver-470"
                GPU_KMOD="nvidia-modeset"
                ;;
            390) 
                GPU_PKGS="nvidia-driver-390"
                GPU_KMOD="nvidia-modeset"
                ;;
        esac
        log "NVIDIA Driver: $NV_VER"
        ;;
    VirtualBox)
        GPU_PKGS="virtualbox-ose-additions"
        # VirtualBox usa servizi invece di kmod
        ;;
    VMware)
        GPU_PKGS="xf86-video-vmware open-vm-tools"
        ;;
    QEMU)
        # Detect specific QEMU GPU type
        if pciconf -lv | grep -q "vendor.*0x1af4.*device.*0x1050"; then
            # VirtIO-GPU
            GPU_PKGS="xf86-video-scfb"
            log "Using SCFB driver for VirtIO-GPU"
        elif pciconf -lv | grep -qi "qxl"; then
            # QXL
            GPU_PKGS="xf86-video-qxl"
            log "Using QXL driver"
        elif pciconf -lv | grep -q "vendor.*0x1234"; then
            # QEMU standard VGA - use SCFB for UEFI or VESA for BIOS
            if [ "$BOOTMETHOD" = "UEFI" ]; then
                GPU_PKGS="xf86-video-scfb"
                log "Using SCFB driver for QEMU standard VGA (UEFI)"
            else
                GPU_PKGS="xf86-video-vesa"
                log "Using VESA driver for QEMU standard VGA (BIOS)"
            fi
        else
            # Fallback to SCFB
            GPU_PKGS="xf86-video-scfb"
            log "Using SCFB driver for QEMU (fallback)"
        fi
        ;;
    HyperV)
        GPU_PKGS="xf86-video-scfb"
        # Hyper-V uses synthetic video driver (scfb with hyperv_fb)
        ;;
    SCFB)
        GPU_PKGS="xf86-video-scfb"
        ;;
    VESA)
        GPU_PKGS="xf86-video-vesa"
        ;;
esac

# --- 7. EXTRA APPLICATIONS ---

exec 5>&1
EXTRA_APPS=$($DIALOG --title "Extra Applications" \
    --checklist "Select additional applications:" 16 60 8 \
    "libreoffice" "Office Suite + CUPS" off \
    "gimp" "Image editor" off \
    "vlc" "Media player" off \
    "git" "Version control" off \
    "thunderbird" "Email client" off \
    2>&1 1>&5)
exec 5>&-

log "Extra applications: $EXTRA_APPS"

# --- 8. PACKAGE DEFINITION ---

# Base packages
PKG_BASE="xorg dbus pulseaudio pavucontrol"

# Common utilities
PKG_UTILS="nano firefox xarchiver gvfs mpv 7-zip"

# Font
PKG_FONTS="noto-basic liberation-fonts-ttf dejavu"

# Language
PKG_LANG=""
PKG_LANG_APPS=""
NEEDS_FCITX5="NO"

case $LANG_CODE in
    it) 
        PKG_LANG="it-hunspell it-hyphen it-mythes"
        echo "$EXTRA_APPS" | grep -q "libreoffice" && PKG_LANG_APPS="$PKG_LANG_APPS it-libreoffice"
        ;;
    de) 
        PKG_LANG="de-hunspell de-mythes"
        echo "$EXTRA_APPS" | grep -q "libreoffice" && PKG_LANG_APPS="$PKG_LANG_APPS de-libreoffice"
        ;;
    fr) 
        PKG_LANG="fr-hunspell fr-hyphen fr-mythes"
        echo "$EXTRA_APPS" | grep -q "libreoffice" && PKG_LANG_APPS="$PKG_LANG_APPS fr-libreoffice"
        ;;
    es) 
        PKG_LANG="es-hunspell es-hyphen es-mythes"
        echo "$EXTRA_APPS" | grep -q "libreoffice" && PKG_LANG_APPS="$PKG_LANG_APPS es-libreoffice"
        ;;
    pt) 
        PKG_LANG="pt-hunspell pt-hyphen pt-mythes"
        echo "$EXTRA_APPS" | grep -q "libreoffice" && PKG_LANG_APPS="$PKG_LANG_APPS pt-libreoffice"
        ;;
    ru) 
        PKG_LANG="ru-hunspell ru-hyphen ru-mythes"
        echo "$EXTRA_APPS" | grep -q "libreoffice" && PKG_LANG_APPS="$PKG_LANG_APPS ru-libreoffice"
        PKG_FONTS="$PKG_FONTS noto-cyrillic"
        ;;
    ja) 
        # Japanese: no language packages available on FreeBSD ports
        PKG_LANG=""
        ;;
    zh) 
        # Chinese: no language packages available on FreeBSD ports
        PKG_LANG=""
        ;;
esac

# Aggiungi language pack solo se l'app è selezionata
[ -n "$PKG_LANG_APPS" ] && PKG_LANG="$PKG_LANG $PKG_LANG_APPS"

# --- AGGIUNTA DIPENDENZE LIBREOFFICE ---
if echo "$EXTRA_APPS" | grep -q "libreoffice"; then
    log "LibreOffice selected: adding CUPS subsystem (CUPS)..."
    # Aggiunge cups e cups-pdf alla lista delle app da installare
    EXTRA_APPS="$EXTRA_APPS cups cups-pdf"
fi

log "Language packages: $PKG_LANG"


# Desktop Environment
case $DE_CHOICE in
    XFCE)
        PKG_DE="xfce xfce4-goodies xfce4-pulseaudio-plugin sddm networkmgr"
        DM_SERVICE="sddm"
        ;;
    KDE)
        PKG_DE="kde sddm networkmgr"
        DM_SERVICE="sddm"
        ;;
    GNOME)
        PKG_DE="gnome gdm networkmgr"
        DM_SERVICE="gdm"
        ;;
esac

# --- 9. PACKAGE INSTALLATION ---

# Prepara lista applicazioni per riepilogo
APPS_LIST=""
if [ -n "$EXTRA_APPS" ]; then
    APPS_LIST=$(echo "$EXTRA_APPS" | tr ' ' '\n' | sed 's/^/  • /' | tr '\n' ' ')
else
    APPS_LIST="  (None)"
fi

# Show summary and ask for confirmation
$DIALOG --title "Confirm Installation" \
    --yesno "Configuration summary:\n\n\
Desktop Environment: $DE_CHOICE\n\
Display Manager: $DM_SERVICE\n\
Language: $LOCALE_CHOICE\n\
Keyboard Layout: $KB_LAYOUT$([ "$KB_LAYOUT" != "us" ] && echo " + us")\n\
Video Driver: $gpu\n\
\n\
Extra applications:\n\
$APPS_LIST\n\
\n\
Proceed with installation?" 20 70

if [ $? -ne $BSDDIALOG_YES ]; then
    log "Installation cancelled by user"
    exit 0
fi

clear
echo "=========================================="
echo "  FreeBSD Desktop Installation"
echo "=========================================="
echo ""
echo "Desktop: $DE_CHOICE"
echo "Language: $LOCALE_CHOICE"
echo "GPU: $gpu"
echo ""
echo "Installation will take a few minutes..."
echo "Log available at: $LOGFILE"
echo ""
sleep 2

# Package installation optimized in two phases:
# - PHASE 1: All critical packages (base system + desktop + drivers)
# - PHASE 2: Optional extra applications

# PHASE 1: Base system + Desktop Environment + Video drivers (all together for efficiency)
log "=== PHASE 1: Installing base system and desktop ==="
ALL_CRITICAL_PKGS="$PKG_BASE $PKG_DE $PKG_UTILS $PKG_FONTS $PKG_LANG"
[ -n "$GPU_PKGS" ] && ALL_CRITICAL_PKGS="$ALL_CRITICAL_PKGS $GPU_PKGS"

if ! install_pkg $ALL_CRITICAL_PKGS; then
    $DIALOG --title "Critical Error" \
        --msgbox "Desktop system installation failed.\n\nCheck: $LOGFILE\n\nPackages installed:\n- Base system (Xorg, D-Bus, Audio)\n- Desktop: $DE_CHOICE\n- Video driver: $gpu" 0 0
    exit 1
fi

# PHASE 2: Extra applications (optional - non-blocking)
if [ -n "$EXTRA_APPS" ]; then
    log "=== PHASE 2: Installing extra applications (optional) ==="
    if ! install_pkg $EXTRA_APPS; then
        log "WARNING: Some extra applications were not installed"
        $DIALOG --title "Warning" \
            --yesno "Some extra applications were not installed.\n\nContinue with configuration anyway?" 0 0
        [ $? -ne $BSDDIALOG_YES ] && exit 1
    fi
fi

# --- 10. SYSTEM CONFIGURATION ---

log "=== Configuring system...="

# Backup rc.conf se non esiste già
if [ ! -f /etc/rc.conf.backup ]; then
    log "Creating backup of /etc/rc.conf..."
    cp /etc/rc.conf /etc/rc.conf.backup
    log "OK: Backup saved in /etc/rc.conf.backup"
fi

# D-Bus
log "Configuring D-Bus..."
sysrc dbus_enable=YES

# Display Manager
log "Configuring Display Manager: $DM_SERVICE"
sysrc "${DM_SERVICE}_enable=YES"

# --- CORRECT AUDIO CONFIGURATION ---
log "Configuring Audio and PulseAudio..."

# 1. Load audio driver in Kernel (CRITICAL)
current_kld=$(sysrc -n kld_list 2>/dev/null || echo "")
if ! echo "$current_kld" | grep -q "snd_driver"; then
    sysrc kld_list+="snd_driver"
    log "OK: Added snd_driver to kld_list"
fi

# 2. PulseAudio configuration file
PA_DIR="/usr/local/etc/pulse"
PA_CONF="$PA_DIR/default.pa"
PA_SAMPLE="$PA_DIR/default.pa.sample"

mkdir -p "$PA_DIR"

if [ ! -f "$PA_CONF" ]; then
    if [ -f "$PA_SAMPLE" ]; then
        log "Copying default.pa from sample template..."
        cp "$PA_SAMPLE" "$PA_CONF"
    else
        log "WARNING: default.pa.sample not found!"
    fi
fi

if [ -f "$PA_CONF" ]; then
    # Enable module-oss (try to uncomment if it exists, otherwise append)
    if grep -q "#load-module module-oss" "$PA_CONF"; then
        sed -i '' 's/#load-module module-oss/load-module module-oss/' "$PA_CONF"
        log "OK: Uncommented module-oss in default.pa"
    elif ! grep -q "^load-module module-oss" "$PA_CONF"; then
        echo "load-module module-oss" >> "$PA_CONF"
        log "OK: Added module-oss to default.pa"
    fi
else
    # Extreme fallback if sample didn't exist
    echo "load-module module-oss" > "$PA_CONF"
fi

# Configuring GPU - KMOD (Secure append)
if [ -n "$GPU_KMOD" ]; then
    log "Configuration driver for video kernel module: $GPU_KMOD"
    
    current=$(sysrc -n kld_list 2>/dev/null || echo "")
    if ! echo "$current" | grep -q "$GPU_KMOD"; then
        sysrc kld_list+="$GPU_KMOD"
        log "OK: Added $GPU_KMOD a kld_list"
    fi
fi

# GPU Configuration - LOADER.CONF
if [ -n "$GPU_LOADER" ]; then
    log "Configuring loader.conf: $GPU_LOADER"
    if ! grep -q "hw.nvidiadrm.modeset" /boot/loader.conf 2>/dev/null; then
        echo "$GPU_LOADER" >> /boot/loader.conf
        log "OK: Added to /boot/loader.conf"
    fi
fi

# VirtualBox servizi
if [ "$gpu" = "VirtualBox" ]; then
    log "Configuring VirtualBox..."
    sysrc vboxguest_enable=YES
    sysrc vboxservice_enable=YES
    
    # Fix UEFI poweroff
    if [ "$BOOTMETHOD" = "UEFI" ]; then
        if ! grep -q "hw.efi.poweroff" /boot/loader.conf 2>/dev/null; then
            echo 'hw.efi.poweroff=0' >> /boot/loader.conf
            log "OK: VirtualBox UEFI poweroff fix"
        fi
    fi
fi

# --- QEMU GUEST AGENT ---
if [ "$gpu" = "QEMU" ]; then
    log "Installing QEMU Guest Agent..."
    if install_pkg qemu-guest-agent; then
        sysrc qemu_guest_agent_enable="YES"
        sysrc qemu_guest_agent_flags="-d"
        
        log "Configuring VirtIO modules..."
        if ! grep -q "virtio_load" /boot/loader.conf 2>/dev/null; then
            cat >> /boot/loader.conf <<'VIRTIO_MODULES'
# VirtIO modules for QEMU/KVM
virtio_load="YES"
virtio_pci_load="YES"
virtio_blk_load="YES"
virtio_scsi_load="YES"
virtio_balloon_load="YES"
virtio_random_load="YES"
virtio_console_load="YES"
if_vtnet_load="YES"
VIRTIO_MODULES
        fi
        
        log "OK: QEMU guest agent configured"
    else
        log "WARNING: QEMU guest agent installation failed"
    fi
fi

# --- HYPER-V INTEGRATION SERVICES ---
if [ "$gpu" = "HyperV" ]; then
    log "Configuring Hyper-V Integration Services..."
    
    # Load Hyper-V modules
    if ! grep -q "hyperv_load" /boot/loader.conf 2>/dev/null; then
        log "Configuring Hyper-V modules..."
        cat >> /boot/loader.conf <<'HYPERV_MODULES'
# Hyper-V Integration Services
hv_vmbus_load="YES"
hv_utils_load="YES"
hv_netvsc_load="YES"
hv_storvsc_load="YES"
HYPERV_MODULES
        log "OK: Hyper-V modules configured"
    fi
    
    # Note: hyperv-tools package doesn't exist in FreeBSD yet
    # Manual configuration needed for advanced features
    log "OK: Hyper-V basic configuration completed"
    log "NOTE: For advanced Hyper-V features, manual configuration may be needed"
fi

# GNOME specifico
if [ "$DE_CHOICE" = "GNOME" ]; then
    log "Configuring GNOME..."
    sysrc gnome_enable=YES
    sysrc NetworkManager_enable=YES
fi

# KDE: Ottimizzazioni IPC
if [ "$DE_CHOICE" = "KDE" ]; then
    log "KDE optimizations..."
    if ! grep -q "net.local.stream.recvspace" /etc/sysctl.conf 2>/dev/null; then
        cat >> /etc/sysctl.conf <<'EOF'

# KDE IPC socket optimization
net.local.stream.recvspace=65536
net.local.stream.sendspace=65536
EOF
        log "OK: KDE IPC optimizations applied"
    fi
fi

# Locale sistema
if ! grep -q "export LANG=" /etc/profile 2>/dev/null; then
    log "Configuring system locale..."
    cat >> /etc/profile <<EOF

# Desktop locale
export LANG=${LOCALE_CHOICE}
export LC_ALL=${LOCALE_CHOICE}
EOF
fi

# Ottimizzazioni base (Audio e IPC)
if ! grep -q "kern.ipc.shmmax" /etc/sysctl.conf 2>/dev/null; then
    log "Applying base optimizations..."
    cat >> /etc/sysctl.conf <<EOF

# Desktop performance tweaks
kern.ipc.shmmax=2147483648
kern.ipc.shmall=524288
# Audio tweaks (consente bit-perfect e latenza minore)
hw.snd.verbose=2
EOF
fi

# Laptop: power management
if [ "$IS_LAPTOP" = "YES" ]; then
    log "Configuring laptop power management..."
    install_pkg powerdxx
    sysrc powerdxx_enable=YES
    
    if ! grep -q "hw.acpi.lid_switch_state" /etc/sysctl.conf 2>/dev/null; then
        cat >> /etc/sysctl.conf <<'EOF'

# Laptop power management
hw.acpi.lid_switch_state=S3
EOF
    fi
fi

# Printer Configuration (CUPS)
if echo "$EXTRA_APPS" | grep -q "cups"; then
    log "Configuring printing service (CUPS)..."
    sysrc cupsd_enable=YES
fi

# SSD: TRIM
if [ "$HAS_SSD" = "YES" ]; then
    log "Configuring SSD TRIM..."
    sysrc daily_trim_enable=YES
fi

# --- 11. USER CONFIGURATION ---

log "=== Configuring users...="

# Trova utenti normali
users=$(pw usershow -a | awk -F":" '$NF != "/usr/sbin/nologin" && $3 > 999 {print $1 " \""$1"\" off"}' | sort)

if [ -z "$users" ]; then
    $DIALOG --title "No Users" \
        --msgbox "No users found.\n\nCreate a user:\n  pw useradd -n username -m -G wheel" 0 0
    exit 1
fi

exec 5>&1
SELECTED_USERS=$(echo $users | xargs -o $DIALOG \
    --title "User Configuration" \
    --checklist "Select users for desktop:" 12 50 5 \
    2>&1 1>&5)
exec 5>&-

if [ -n "$SELECTED_USERS" ]; then
    log "Users selected: $SELECTED_USERS"
    
    # Gruppo video (necessario per X.org)
    if [ "$gpu" != "VESA" ] && [ "$gpu" != "SCFB" ]; then
        log "Configuring video group..."
        pw groupshow video >/dev/null 2>&1 || pw groupadd video
        
        for user in $SELECTED_USERS; do
            pw groupmod video -m "$user"
            log "OK: $user added to video group"
        done
    fi
    
    # Sudo
    $DIALOG --title "Sudo" \
        --yesno "Enable sudo for selected users?" 0 0
    
    if [ $? -eq $BSDDIALOG_YES ]; then
        log "Configuring sudo..."
        which sudo >/dev/null 2>&1 || install_pkg sudo
        
        if [ -f /usr/local/etc/sudoers ]; then
            if ! grep -q "^%wheel ALL=(ALL:ALL) ALL" /usr/local/etc/sudoers; then
                cp /usr/local/etc/sudoers /usr/local/etc/sudoers.bak
                sed -i '' 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /usr/local/etc/sudoers
                log "OK: Sudo enabled for wheel group"
            fi
        fi
        
        for user in $SELECTED_USERS; do
            pw groupshow wheel | grep -q "$user" || pw groupmod wheel -m "$user"
            log "OK: $user added to wheel group"
        done
        
        SUDO_STATUS="Enabled"
    else
        SUDO_STATUS="Disabled"
    fi
    
    # Per-user configuration
    for user in $SELECTED_USERS; do
        user_home=$(pw usershow "$user" | awk -F: '{print $(NF-1)}')
        log "Configuring user: $user (home: $user_home)"
        
        if [ ! -f "${user_home}/.profile" ]; then
            touch "${user_home}/.profile"
        fi
        
        # User locale
        if ! grep -q "export LANG=" "${user_home}/.profile" 2>/dev/null; then
            cat >> "${user_home}/.profile" <<EOF

# Desktop locale
export LANG=${LOCALE_CHOICE}
export LC_ALL=${LOCALE_CHOICE}
EOF
        fi
        
        # PulseAudio autostart
        log "Configuring PulseAudio autostart for $user..."
        user_config="${user_home}/.config"
        mkdir -p "${user_config}/autostart"
        
        cat > "${user_config}/autostart/pulseaudio.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PulseAudio Sound System
Exec=pulseaudio --start --log-target=syslog
Terminal=false
Hidden=false
X-GNOME-Autostart-enabled=true
X-KDE-autostart-phase=1
EOF
        chown -R "${user}:${user}" "${user_config}/autostart/pulseaudio.desktop"
        log "OK: PulseAudio autostart configured for $user"
        
        # Input Method asiatici fcitx5
        if [ "$NEEDS_FCITX5" = "YES" ]; then
            log "Configuring fcitx5 for $user..."
            
            user_config="${user_home}/.config"
            mkdir -p "${user_config}/autostart"
            
            if ! grep -q "GTK_IM_MODULE=fcitx" "${user_home}/.profile" 2>/dev/null; then
                cat >> "${user_home}/.profile" <<'EOF'

# Input Method (fcitx5)
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
EOF
            fi
            
            cat > "${user_config}/autostart/fcitx5.desktop" <<'EOF'
[Desktop Entry]
Name=Fcitx5
Comment=Input Method
Exec=fcitx5 -d
Terminal=false
Type=Application
X-GNOME-Autostart-Phase=Initialization
X-KDE-autostart-phase=1
Version=1.0
EOF
            chown -R "${user}:${user}" "${user_config}"
        fi
        
        # XFCE keyboard configuration
        if [ "$DE_CHOICE" = "XFCE" ]; then
            log "Configuring XFCE keyboard for $user (layout: $KB_LAYOUT + us)..."
            
            user_config="${user_home}/.config"
            xfce_kb_dir="${user_config}/xfce4/xfconf/xfce-perchannel-xml"
            mkdir -p "${xfce_kb_dir}"
            
            # Layout: primary + us (if primary is not already us)
            if [ "$KB_LAYOUT" = "us" ]; then
                KB_LAYOUTS="us"
                KB_VARIANTS=""
            else
                KB_LAYOUTS="${KB_LAYOUT},us"
                KB_VARIANTS=","
            fi
            
            # Create/update keyboard configuration
            cat > "${xfce_kb_dir}/keyboard-layout.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>

<channel name="keyboard-layout" version="1.0">
  <property name="Default" type="empty">
    <property name="XkbDisable" type="bool" value="false"/>
    <property name="XkbLayout" type="string" value="${KB_LAYOUTS}"/>
    <property name="XkbVariant" type="string" value="${KB_VARIANTS}"/>
  </property>
</channel>
EOF
            
            chown -R "${user}:${user}" "${user_config}"
            log "OK: Keyboard .* configured for $user"
        fi
        
        # KDE keyboard configuration
        if [ "$DE_CHOICE" = "KDE" ]; then
            log "Configuring KDE keyboard for $user (layout: $KB_LAYOUT + us)..."
            
            user_config="${user_home}/.config"
            mkdir -p "${user_config}"
            
            # Layout: primary + us (if primary is not already us)
            if [ "$KB_LAYOUT" = "us" ]; then
                KDE_LAYOUTS="us"
            else
                KDE_LAYOUTS="${KB_LAYOUT},us"
            fi
            
            # KDE Plasma 5/6 uses kxkbrc
            cat > "${user_config}/kxkbrc" <<EOF
[Layout]
DisplayNames=
LayoutList=${KDE_LAYOUTS}
LayoutLoopCount=-1
Model=pc104
Options=
ResetOldOptions=true
ShowFlag=true
ShowLabel=true
ShowLayoutIndicator=true
ShowSingle=false
SwitchMode=Global
Use=true
EOF
            
            chown -R "${user}:${user}" "${user_config}"
            log "OK: Keyboard .* configured for $user"
        fi
        
        # GNOME keyboard configuration
        if [ "$DE_CHOICE" = "GNOME" ]; then
            log "Configuring GNOME keyboard for $user (layout: $KB_LAYOUT + us)..."
            
            user_config="${user_home}/.config"
            mkdir -p "${user_config}/autostart"
            
            # Layout: primary + us (if primary is not already us)
            if [ "$KB_LAYOUT" = "us" ]; then
                GNOME_LAYOUTS="[('xkb', 'us')]"
            else
                GNOME_LAYOUTS="[('xkb', '${KB_LAYOUT}'), ('xkb', 'us')]"
            fi
            
            # Script to configure keyboard at login (GNOME uses gsettings)
            cat > "${user_config}/autostart/set-keyboard.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Set Keyboard Layout
Exec=sh -c 'gsettings set org.gnome.desktop.input-sources sources "${GNOME_LAYOUTS}"'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
            
            chown -R "${user}:${user}" "${user_config}"
            log "OK: Keyboard .* configured for $user (active at first login)"
        fi
        
        # LibreOffice language configuration
        if echo "$EXTRA_APPS" | grep -q "libreoffice"; then
            if [ "$LANG_CODE" != "en" ]; then
                log "Configuring LibreOffice for $user (language: $LANG_CODE)..."
                
                lo_config="${user_home}/.config/libreoffice/4/user"
                mkdir -p "${lo_config}"
                
                # registrymodifications.xcu to set UI language and locale
                cat > "${lo_config}/registrymodifications.xcu" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<item oor:path="/org.openoffice.Office.Linguistic/General"><prop oor:name="UILocale" oor:op="fuse"><value>${LOCALE_CHOICE}</value></prop></item>
<item oor:path="/org.openoffice.Setup/L10N"><prop oor:name="ooLocale" oor:op="fuse"><value>${LANG_CODE}</value></prop></item>
<item oor:path="/org.openoffice.Setup/L10N"><prop oor:name="ooSetupSystemLocale" oor:op="fuse"><value>${LOCALE_CHOICE}</value></prop></item>
</oor:items>
EOF
                chown -R "${user}:${user}" "${user_home}/.config/libreoffice"
                log "OK: LibreOffice configured for language ${LANG_CODE}"
            fi
        fi
        
        chown "${user}:${user}" "${user_home}/.profile"
    done
fi

# --- 12. FINAL VERIFICATION ---

log "=== Verifying installation ==="

# Verify video driver installed
if [ -n "$GPU_PKGS" ]; then
    for pkg in $GPU_PKGS; do
        if pkg info "$pkg" >/dev/null 2>&1; then
            log "✓ $pkg installed"
        else
            log "✗ MISSING: $pkg"
        fi
    done
fi

# Verify display manager
if pkg info "$DM_SERVICE" >/dev/null 2>&1; then
    log "✓ Display manager $DM_SERVICE installed"
else
    log "✗ MISSING: Display manager $DM_SERVICE"
fi

# Verify kld_list
if sysrc -n kld_list >/dev/null 2>&1; then
    log "✓ kld_list configured: $(sysrc -n kld_list)"
else
    log "✗ WARNING: kld_list not configured"
fi

# Verifying critical services
log "Verifying critical services..."
SERVICES_OK=true
for svc in dbus ${DM_SERVICE}; do
    if sysrc -n ${svc}_enable 2>/dev/null | grep -q YES; then
        log "✓ Service $svc enabled"
    else
        log "✗ WARNING: Service $svc not enabled"
        SERVICES_OK=false
    fi
done

# Verify PulseAudio daemon
if sysrc -n snd_driver 2>/dev/null | grep -q "snd_driver"; then
    log "✓ Audio driver (snd_driver) configured"
else
    log "✗ WARNING: snd_driver not configured"
fi

if [ "$SERVICES_OK" = "false" ]; then
    log "⚠ Some critical services are not enabled properly"
fi

log "=== Installation completed ==="

# --- 13. COMPLETION ---

clear
cat <<EOF
===================================================
    FreeBSD Desktop Installation Completed!
===================================================

Desktop Environment: $DE_CHOICE
Display Manager: $DM_SERVICE
Language: $LOCALE_CHOICE
Keyboard Layout: $KB_LAYOUT$([ "$KB_LAYOUT" != "us" ] && echo " + us (secondary)")
Video Driver: $gpu

Configured users:
$(echo "$SELECTED_USERS" | tr ' ' '\n' | sed 's/^/  - /')

Sudo: ${SUDO_STATUS:-Not configured}

Applied optimizations:
  - Increased shared memory
  - Audio (snd_driver loaded, PulseAudio fixed)
$([ "$IS_LAPTOP" = "YES" ] && echo "  - Laptop power management (powerdxx)")
$([ "$HAS_SSD" = "YES" ] && echo "  - Automatic SSD TRIM")
$([ "$DE_CHOICE" = "KDE" ] && echo "  - KDE IPC optimizations")
$([ "$gpu" = "VirtualBox" ] && [ "$BOOTMETHOD" = "UEFI" ] && echo "  - VirtualBox UEFI poweroff fix")
$([ "$gpu" = "QEMU" ] && echo "  - QEMU Guest Agent configured")
$([ "$gpu" = "HyperV" ] && echo "  - Hyper-V Integration Services configured")
$([ "$NEEDS_FCITX5" = "YES" ] && echo "  - Input Method fcitx5 configured")

Localization:
$([ "$LANG_CODE" != "en" ] && echo "  - Spell-check and hyphenation dictionaries installed")
$([ -n "$PKG_LANG_APPS" ] && echo "  - Application language packs: LibreOffice, Thunderbird")
$([ "$LANG_CODE" != "en" ] && echo "  - LibreOffice pre-configured in ${LANG_CODE}")
$([ "$LANG_CODE" != "en" ] && echo "  - Firefox: English UI (install firefox-i18n-* manually if available)")

$([ -n "$EXTRA_APPS" ] && echo "Installed applications:" && echo "$EXTRA_APPS" | tr ' ' '\n' | sed 's/^/  - /')

Complete log: $LOGFILE

===================================================
         REBOOT THE SYSTEM WITH: reboot
===================================================

EOF

# Show log if there are errors
if grep -q "ERRORE" "$LOGFILE"; then
    $DIALOG --title "Warning" \
        --yesno "Some errors detected during installation.\n\nView log?" 0 0
    
    if [ $? -eq $BSDDIALOG_YES ]; then
        $DIALOG --title "Installation Log" \
            --textbox "$LOGFILE" 0 0
    fi
fi

# Ask if reboot
$DIALOG --title "Installation Completed" \
    --yesno "Reboot system now?" 0 0

if [ $? -eq $BSDDIALOG_YES ]; then
    log "Rebooting system..."
    reboot
fi
