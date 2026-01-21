#!/bin/sh
#
# FREEBSD DESKTOP INSTALLER - Enhanced & Robust (Fixed Audio)
# Script per installazione Desktop Environment su FreeBSD
# Include fix per PulseAudio e rilevamento driver audio
#

readonly BSDDIALOG_OK=0
readonly BSDDIALOG_YES=$BSDDIALOG_OK
readonly BSDDIALOG_NO=1

DIALOG=bsddialog
LOGFILE="/tmp/freebsd-desktop-install.log"

# Funzione di logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

# Funzione per installare pacchetti con controllo errori

install_pkg() {
    local pkgs="$*"
    local tmplog="/tmp/pkg-install-$$.log"
    local exitcode_file="/tmp/pkg-exit-$$.code"
    
    log ">>> Installazione: $pkgs"
    echo ""
    echo "=========================================="
    echo ">>> Installazione: $pkgs"
    echo "=========================================="
    echo ""
    
    # Esegui pkg install:
    # 1. Mostra output a video E lo salva nel log (usando tee)
    # 2. Cattura il codice di errore di pkg in un file temporaneo
    (pkg install -y $pkgs 2>&1; echo $? > "$exitcode_file") | tee "$tmplog"
    
    # Leggi il codice di uscita catturato
    local pkg_exit=$(cat "$exitcode_file")
    rm -f "$exitcode_file"

    # Aggiungi il log temporaneo al log principale
    cat "$tmplog" >> "$LOGFILE"
    rm -f "$tmplog"

    if [ "$pkg_exit" -eq 0 ]; then
        log "OK: Pacchetti installati con successo"
        echo ""
        echo "✓ Installazione completata"
        echo ""
        sleep 1
        return 0
    else
        log "ERRORE: Installazione fallita (exit code: $pkg_exit) per: $pkgs"
        echo ""
        echo "✗ ERRORE durante installazione (exit code: $pkg_exit)"
        echo ""
        if which $DIALOG > /dev/null 2>&1; then
            $DIALOG --title "Errore Installazione" \
                --msgbox "Errore durante installazione:\n$pkgs\n\nCodice errore: $pkg_exit\nControlla il log: $LOGFILE" 0 0
        fi
        return 1
    fi
}

# --- 1. CONTROLLI PRELIMINARI ---

> "$LOGFILE"
log "=== Inizio installazione Desktop FreeBSD ==="

if [ "$(id -u)" -ne 0 ]; then
    echo "ERRORE: Esegui questo script come root"
    exit 1
fi

# Installa bsddialog se non presente
if ! which $DIALOG > /dev/null 2>&1; then
    log "Installazione bsddialog..."
    pkg install -y bsddialog
fi

# Verifica hostname
if [ -z "$(hostname)" ]; then
    $DIALOG --title "Hostname Richiesto" \
        --msgbox "Configura un hostname prima di continuare.\n\nEsempio:\n  hostname mypc.local\n  sysrc hostname=\"mypc\"" 0 0
    exit 1
fi

# Verifica connessione internet
log "Verifica connessione internet..."
echo "Test connettività internet (ping 8.8.8.8)..."
if ! ping -c 1 -t 5 8.8.8.8; then
    $DIALOG --title "Errore Connessione" \
        --msgbox "Nessuna connessione internet.\n\nConfigura la rete e riprova." 0 0
    exit 1
fi
echo "✓ Connessione internet OK"
echo ""

# --- CONTROLLO ORARIO INTELLIGENTE ---
log "Verifica disallineamento orario..."
echo "Verifica orario server NTP..."

# 1. Interroga il server senza modificare nulla (-q)
# L'output è tipo: "... offset -123.456 sec"
ntp_output=$(ntpdate -q 0.freebsd.pool.ntp.org 2>/dev/null | tail -n 1)

# Estrae l'offset (penultima parola della stringa)
offset=$(echo "$ntp_output" | awk '{ print $(NF-1) }')

if [ -n "$offset" ]; then
    # 2. Calcola se la differenza è maggiore di 180 secondi (3 min) usando awk
    # Restituisce 1 (vero) se diff > 180, altrimenti 0
    needs_sync=$(echo "$offset" | awk '{ if ($1 < 0) $1 = -$1; if ($1 > 180) print 1; else print 0; }')

    if [ "$needs_sync" -eq 1 ]; then
        log "Rilevato offset orario significativo: ${offset}s"
        
        # 3. Propone la sincronizzazione all'utente
        $DIALOG --title "Orario non allineato" \
            --yesno "L'orario di sistema differisce di circa $offset secondi dal server.\n\nVuoi sincronizzarlo ora?\n(Consigliato per evitare errori con i pacchetti SSL)" 0 0
        
        if [ $? -eq $BSDDIALOG_YES ]; then
            log "L'utente ha accettato la sincronizzazione."
            echo "Sincronizzazione orario in corso..."
            service ntpd stop >/dev/null 2>&1
            ntpd -g -q >/dev/null 2>&1
            sysrc ntpd_enable="YES" >/dev/null 2>&1
            sysrc ntpd_sync_on_start="YES" >/dev/null 2>&1
            log "Orario corretto: $(date)"
            echo "✓ Orario sincronizzato."
        else
            log "L'utente ha rifiutato la sincronizzazione."
        fi
    else
        log "Orario allineato (diff: ${offset}s). Nessuna azione necessaria."
        echo "✓ Orario corretto (differenza: ${offset}s)"
    fi
else
    log "Impossibile contattare server NTP per la verifica."
    echo "⚠ Verifica NTP fallita (proseguo)"
fi
echo ""

# Inizializza pkg
if ! pkg -N >/dev/null 2>&1; then
    log "Inizializzazione pkg..."
    pkg bootstrap -y
fi

# Verifica se il repository è aggiornato (controlla età del catalogo)
CATALOG_AGE=$(find /var/db/pkg/repo-*.sqlite 2>/dev/null -mmin +1440 | wc -l)

if [ "$CATALOG_AGE" -gt 0 ] || [ ! -f /var/db/pkg/repo-*.sqlite 2>/dev/null ]; then
    # Catalogo più vecchio di 24 ore o non esistente -> update automatico
    log "Aggiornamento repository (catalogo vecchio o mancante)..."
    echo "Aggiornamento repository pacchetti FreeBSD..."
    if ! pkg update; then
        $DIALOG --title "Errore Repository" \
            --msgbox "Impossibile aggiornare i repository pkg.\n\nVerifica la connessione." 0 0
        exit 1
    fi
else
    log "Repository già aggiornato, skip update"
    echo "✓ Repository già aggiornato (< 24 ore)"
    echo ""
fi

# Verifica spazio disco disponibile
log "Verifica spazio disco..."
MIN_SPACE_GB=5
available_space=$(df -g / | awk 'NR==2 {print $4}')
if [ "$available_space" -lt "$MIN_SPACE_GB" ]; then
    $DIALOG --title "Spazio Disco Insufficiente" \
        --msgbox "Spazio disponibile: ${available_space}GB\nMinimo richiesto: ${MIN_SPACE_GB}GB\n\nLiberare spazio e riprovare." 0 0
    exit 1
fi
log "Spazio disponibile: ${available_space}GB"

# --- 2. RILEVAMENTO HARDWARE ---

log "Rilevamento hardware..."

# Boot method
BOOTMETHOD=$(sysctl -n machdep.bootmethod 2>/dev/null || echo "BIOS")
log "Boot method: $BOOTMETHOD"

# Laptop detection
IS_LAPTOP="NO"
if sysctl -n hw.acpi.battery.units >/dev/null 2>&1; then
    BATTERY=$(sysctl -n hw.acpi.battery.units 2>/dev/null || echo 0)
    [ "$BATTERY" -gt 0 ] && IS_LAPTOP="YES"
fi
log "Tipo sistema: $([ "$IS_LAPTOP" = "YES" ] && echo "Laptop" || echo "Desktop")"

# SSD detection
HAS_SSD="NO"
camcontrol devlist 2>/dev/null | grep -qi "ssd\|solid state\|nvme" && HAS_SSD="YES"
log "Storage: $([ "$HAS_SSD" = "YES" ] && echo "SSD" || echo "HDD")"

# GPU detection
VGA_INFO=$(pciconf -lv | grep -A 4 vga)
AUTO_GPU="Generic"

if echo "$VGA_INFO" | grep -qi "intel"; then
    AUTO_GPU="Intel"
elif echo "$VGA_INFO" | grep -qi "nvidia"; then
    AUTO_GPU="NVIDIA"
elif echo "$VGA_INFO" | grep -qi "amd\|ati\|radeon"; then
    if echo "$VGA_INFO" | grep -qiE "HD [7-9][0-9]{3}|R[5-9]|RX|Vega|Navi"; then
        AUTO_GPU="AMD"
    else
        AUTO_GPU="Radeon"
    fi
elif echo "$VGA_INFO" | grep -qi "vmware"; then
    AUTO_GPU="VMware"
elif echo "$VGA_INFO" | grep -qi "virtualbox"; then
    AUTO_GPU="VirtualBox"
fi

log "GPU rilevata: $AUTO_GPU"

SYSINFO="Sistema: $([ "$IS_LAPTOP" = "YES" ] && echo "Laptop" || echo "Desktop")
Storage: $([ "$HAS_SSD" = "YES" ] && echo "SSD" || echo "HDD")
Boot: $BOOTMETHOD
GPU rilevata: $AUTO_GPU"

# --- 3. SCELTA DESKTOP ENVIRONMENT ---

DE_CHOICE=$($DIALOG --title "Desktop Environment" \
    --extra-button --extra-label "Info Sistema" \
    --radiolist "Scegli ambiente desktop:" 12 60 3 \
    "XFCE"  "Leggero e veloce (Consigliato)" on \
    "KDE"   "Moderno ed elegante" off \
    "GNOME" "Esperienza completa" off \
    3>&1 1>&2 2>&3 3>&-)

exit_status=$?

# Se premuto "Info Sistema"
if [ $exit_status -eq 3 ]; then
    $DIALOG --title "Informazioni Sistema" --msgbox "$SYSINFO" 0 0
    exec "$0"  # Riavvia script
fi

[ $exit_status -ne $BSDDIALOG_OK ] && exit 1
[ -z "$DE_CHOICE" ] && exit 0

log "Desktop selezionato: $DE_CHOICE"

# --- 4. SCELTA LINGUA ---

LOCALE_CHOICE=$($DIALOG --title "Lingua Desktop" \
    --radiolist "Seleziona lingua:" 18 50 10 \
    "it_IT.UTF-8" "Italiano" on \
    "en_US.UTF-8" "English (US)" off \
    "en_GB.UTF-8" "English (UK)" off \
    "de_DE.UTF-8" "Deutsch" off \
    "fr_FR.UTF-8" "Français" off \
    "es_ES.UTF-8" "Español" off \
    "pt_BR.UTF-8" "Português" off \
    "ru_RU.UTF-8" "Русский" off \
    "ja_JP.UTF-8" "日本語" off \
    "zh_CN.UTF-8" "中文" off \
    3>&1 1>&2 2>&3 3>&-)

[ $? -ne $BSDDIALOG_OK ] && exit 1
[ -z "$LOCALE_CHOICE" ] && LOCALE_CHOICE="en_US.UTF-8"

LANG_CODE=$(echo "$LOCALE_CHOICE" | cut -d'_' -f1)
log "Lingua selezionata: $LOCALE_CHOICE"

# Mappatura lingua -> layout tastiera
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
        # Distingui US/UK
        case $LOCALE_CHOICE in
            en_GB*) KB_LAYOUT="gb" ;;
            *) KB_LAYOUT="us" ;;
        esac
        ;;
    *) KB_LAYOUT="us" ;;
esac

log "Layout tastiera: $KB_LAYOUT"

# --- 5. SCELTA DRIVER VIDEO ---

# Imposta suggerimento
case $AUTO_GPU in
    Intel) D_INTEL="on" ;;
    AMD) D_AMD="on" ;;
    Radeon) D_RADEON="on" ;;
    NVIDIA) D_NVIDIA="on" ;;
    VirtualBox) D_VBOX="on" ;;
    VMware) D_VMWARE="on" ;;
    *)
        if [ "$BOOTMETHOD" = "UEFI" ]; then
            D_SCFB="on"
        else
            D_VESA="on"
        fi
        ;;
esac

gpu=$($DIALOG --title "Driver Video" \
    --radiolist "Driver video (suggerito: $AUTO_GPU):" 14 60 8 \
    "Intel"      "Intel HD Graphics" ${D_INTEL:-off} \
    "AMD"        "AMD Radeon moderna" ${D_AMD:-off} \
    "Radeon"     "AMD legacy" ${D_RADEON:-off} \
    "NVIDIA"     "NVIDIA" ${D_NVIDIA:-off} \
    "VirtualBox" "VirtualBox Guest" ${D_VBOX:-off} \
    "VMware"     "VMware Guest" ${D_VMWARE:-off} \
    "SCFB"       "Framebuffer UEFI" ${D_SCFB:-off} \
    "VESA"       "VESA BIOS" ${D_VESA:-off} \
    3>&1 1>&2 2>&3 3>&-)

[ $? -ne $BSDDIALOG_OK ] && exit 1
[ -z "$gpu" ] && exit 0

log "Driver video selezionato: $gpu"

# --- 6. CONFIGURAZIONE DRIVER VIDEO ---

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
        # Chiedi quale versione NVIDIA
        NV_VER=$($DIALOG --title "Driver NVIDIA" \
            --radiolist "Versione driver:" 10 50 3 \
            "latest" "Ultima versione" on \
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
        log "Driver NVIDIA: $NV_VER"
        ;;
    VirtualBox)
        GPU_PKGS="virtualbox-ose-additions"
        # VirtualBox usa servizi invece di kmod
        ;;
    VMware)
        GPU_PKGS="xf86-video-vmware open-vm-tools"
        ;;
    SCFB)
        GPU_PKGS="xf86-video-scfb"
        ;;
    VESA)
        GPU_PKGS="xf86-video-vesa"
        ;;
esac

# --- 7. APPLICAZIONI EXTRA ---

exec 5>&1
EXTRA_APPS=$($DIALOG --title "Applicazioni Extra" \
    --checklist "Seleziona applicazioni aggiuntive:" 16 60 8 \
    "libreoffice" "Suite Office + CUPS" off \
    "gimp" "Editor immagini" off \
    "vlc" "Player multimediale" off \
    "git" "Version control" off \
    "thunderbird" "Client email" off \
    2>&1 1>&5)
exec 5>&-

log "Applicazioni extra: $EXTRA_APPS"

# --- 8. DEFINIZIONE PACCHETTI ---

# Pacchetti base
PKG_BASE="xorg dbus pulseaudio pavucontrol"

# Utility comuni
PKG_UTILS="nano firefox xarchiver gvfs mpv 7-zip"

# Font
PKG_FONTS="noto-basic liberation-fonts-ttf dejavu"

# Lingua
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
        # Giapponese: nessun pacchetto lingua disponibile su FreeBSD ports
        PKG_LANG=""
        ;;
    zh) 
        # Cinese: nessun pacchetto lingua disponibile su FreeBSD ports
        PKG_LANG=""
        ;;
esac

# Aggiungi language pack solo se l'app è selezionata
[ -n "$PKG_LANG_APPS" ] && PKG_LANG="$PKG_LANG $PKG_LANG_APPS"

# --- AGGIUNTA DIPENDENZE LIBREOFFICE ---
if echo "$EXTRA_APPS" | grep -q "libreoffice"; then
    log "LibreOffice selezionato: aggiungo sottosistema stampa (CUPS)..."
    # Aggiunge cups e cups-pdf alla lista delle app da installare
    EXTRA_APPS="$EXTRA_APPS cups cups-pdf"
fi

log "Pacchetti lingua: $PKG_LANG"

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

# --- 9. INSTALLAZIONE PACCHETTI ---

# Prepara lista applicazioni per riepilogo
APPS_LIST=""
if [ -n "$EXTRA_APPS" ]; then
    APPS_LIST=$(echo "$EXTRA_APPS" | tr ' ' '\n' | sed 's/^/  • /' | tr '\n' ' ')
else
    APPS_LIST="  (Nessuna)"
fi

# Mostra riepilogo e chiedi conferma
$DIALOG --title "Conferma Installazione" \
    --yesno "Riepilogo configurazione:\n\n\
Desktop Environment: $DE_CHOICE\n\
Display Manager: $DM_SERVICE\n\
Lingua: $LOCALE_CHOICE\n\
Layout Tastiera: $KB_LAYOUT$([ "$KB_LAYOUT" != "us" ] && echo " + us")\n\
Driver Video: $gpu\n\
\n\
Applicazioni extra:\n\
$APPS_LIST\n\
\n\
Procedere con l'installazione?" 20 70

if [ $? -ne $BSDDIALOG_YES ]; then
    log "Installazione annullata dall'utente"
    exit 0
fi

clear
echo "=========================================="
echo "  Installazione Desktop FreeBSD"
echo "=========================================="
echo ""
echo "Desktop: $DE_CHOICE"
echo "Lingua: $LOCALE_CHOICE"
echo "GPU: $gpu"
echo ""
echo "L'installazione richiederà alcuni minuti..."
echo "Log disponibile in: $LOGFILE"
echo ""
sleep 2

# Installazione pacchetti in due fasi ottimizzate:
# - FASE 1: Tutti i pacchetti critici (sistema base + desktop + driver)
# - FASE 2: Applicazioni extra opzionali

# FASE 1: Sistema base + Desktop Environment + Driver video (tutto insieme per efficienza)
log "=== FASE 1: Installazione sistema base e desktop ==="
ALL_CRITICAL_PKGS="$PKG_BASE $PKG_DE $PKG_UTILS $PKG_FONTS $PKG_LANG"
[ -n "$GPU_PKGS" ] && ALL_CRITICAL_PKGS="$ALL_CRITICAL_PKGS $GPU_PKGS"

if ! install_pkg $ALL_CRITICAL_PKGS; then
    $DIALOG --title "Errore Critico" \
        --msgbox "Installazione sistema desktop fallita.\n\nControlla: $LOGFILE\n\nPacchetti installati:\n- Sistema base (Xorg, D-Bus, Audio)\n- Desktop: $DE_CHOICE\n- Driver video: $gpu" 0 0
    exit 1
fi

# FASE 2: Applicazioni extra (opzionali - non bloccanti)
if [ -n "$EXTRA_APPS" ]; then
    log "=== FASE 2: Installazione applicazioni extra (opzionali) ==="
    if ! install_pkg $EXTRA_APPS; then
        log "ATTENZIONE: Alcune applicazioni extra non sono state installate"
        $DIALOG --title "Avviso" \
            --yesno "Alcune applicazioni extra non sono state installate.\n\nContinuare comunque con la configurazione?" 0 0
        [ $? -ne $BSDDIALOG_YES ] && exit 1
    fi
fi

# --- 10. CONFIGURAZIONE SISTEMA ---

log "=== Configurazione sistema ==="

# Backup rc.conf se non esiste già
if [ ! -f /etc/rc.conf.backup ]; then
    log "Creazione backup di /etc/rc.conf..."
    cp /etc/rc.conf /etc/rc.conf.backup
    log "OK: Backup salvato in /etc/rc.conf.backup"
fi

# D-Bus
log "Configurazione D-Bus..."
sysrc dbus_enable=YES

# Display Manager
log "Configurazione Display Manager: $DM_SERVICE"
sysrc "${DM_SERVICE}_enable=YES"

# --- CONFIGURAZIONE AUDIO CORRETTA ---
log "Configurazione Audio e PulseAudio..."

# 1. Carica driver audio nel Kernel (CRITICO)
current_kld=$(sysrc -n kld_list 2>/dev/null || echo "")
if ! echo "$current_kld" | grep -q "snd_driver"; then
    sysrc kld_list+="snd_driver"
    log "OK: Aggiunto snd_driver a kld_list"
fi

# 2. Configurazione file PulseAudio
PA_DIR="/usr/local/etc/pulse"
PA_CONF="$PA_DIR/default.pa"
PA_SAMPLE="$PA_DIR/default.pa.sample"

mkdir -p "$PA_DIR"

if [ ! -f "$PA_CONF" ]; then
    if [ -f "$PA_SAMPLE" ]; then
        log "Copia default.pa da template sample..."
        cp "$PA_SAMPLE" "$PA_CONF"
    else
        log "ATTENZIONE: default.pa.sample non trovato!"
    fi
fi

if [ -f "$PA_CONF" ]; then
    # Abilita module-oss (cerca di decommentare se esiste, altrimenti appende)
    if grep -q "#load-module module-oss" "$PA_CONF"; then
        sed -i '' 's/#load-module module-oss/load-module module-oss/' "$PA_CONF"
        log "OK: Decommentato module-oss in default.pa"
    elif ! grep -q "^load-module module-oss" "$PA_CONF"; then
        echo "load-module module-oss" >> "$PA_CONF"
        log "OK: Aggiunto module-oss a default.pa"
    fi
else
    # Fallback estremo se il sample non esisteva
    echo "load-module module-oss" > "$PA_CONF"
fi

# Configurazione GPU - KMOD (Esegue append sicuro)
if [ -n "$GPU_KMOD" ]; then
    log "Configurazione driver video kernel module: $GPU_KMOD"
    
    current=$(sysrc -n kld_list 2>/dev/null || echo "")
    if ! echo "$current" | grep -q "$GPU_KMOD"; then
        sysrc kld_list+="$GPU_KMOD"
        log "OK: Aggiunto $GPU_KMOD a kld_list"
    fi
fi

# Configurazione GPU - LOADER.CONF
if [ -n "$GPU_LOADER" ]; then
    log "Configurazione loader.conf: $GPU_LOADER"
    if ! grep -q "hw.nvidiadrm.modeset" /boot/loader.conf 2>/dev/null; then
        echo "$GPU_LOADER" >> /boot/loader.conf
        log "OK: Aggiunto a /boot/loader.conf"
    fi
fi

# VirtualBox servizi
if [ "$gpu" = "VirtualBox" ]; then
    log "Configurazione VirtualBox..."
    sysrc vboxguest_enable=YES
    sysrc vboxservice_enable=YES
    
    # Fix UEFI poweroff
    if [ "$BOOTMETHOD" = "UEFI" ]; then
        if ! grep -q "hw.efi.poweroff" /boot/loader.conf 2>/dev/null; then
            echo 'hw.efi.poweroff=0' >> /boot/loader.conf
            log "OK: Fix VirtualBox UEFI poweroff"
        fi
    fi
fi

# GNOME specifico
if [ "$DE_CHOICE" = "GNOME" ]; then
    log "Configurazione GNOME..."
    sysrc gnome_enable=YES
    sysrc NetworkManager_enable=YES
fi

# KDE: Ottimizzazioni IPC
if [ "$DE_CHOICE" = "KDE" ]; then
    log "Ottimizzazioni KDE..."
    if ! grep -q "net.local.stream.recvspace" /etc/sysctl.conf 2>/dev/null; then
        cat >> /etc/sysctl.conf <<'EOF'

# KDE IPC socket optimization
net.local.stream.recvspace=65536
net.local.stream.sendspace=65536
EOF
        log "OK: Ottimizzazioni IPC KDE applicate"
    fi
fi

# Locale sistema
if ! grep -q "export LANG=" /etc/profile 2>/dev/null; then
    log "Configurazione locale sistema..."
    cat >> /etc/profile <<EOF

# Desktop locale
export LANG=${LOCALE_CHOICE}
export LC_ALL=${LOCALE_CHOICE}
EOF
fi

# Ottimizzazioni base (Audio e IPC)
if ! grep -q "kern.ipc.shmmax" /etc/sysctl.conf 2>/dev/null; then
    log "Applicazione ottimizzazioni base..."
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
    log "Configurazione power management laptop..."
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
    log "Configuring print service (CUPS)..."
    sysrc cupsd_enable=YES
fi

# SSD: TRIM
if [ "$HAS_SSD" = "YES" ]; then
    log "Configurazione TRIM per SSD..."
    sysrc daily_trim_enable=YES
fi

# --- 11. CONFIGURAZIONE UTENTI ---

log "=== Configurazione utenti ==="

# Trova utenti normali
users=$(pw usershow -a | awk -F":" '$NF != "/usr/sbin/nologin" && $3 > 999 {print $1 " \""$1"\" off"}' | sort)

if [ -z "$users" ]; then
    $DIALOG --title "Nessun Utente" \
        --msgbox "Nessun utente trovato.\n\nCrea un utente:\n  pw useradd -n username -m -G wheel" 0 0
    exit 1
fi

exec 5>&1
SELECTED_USERS=$(echo $users | xargs -o $DIALOG \
    --title "Configurazione Utenti" \
    --checklist "Seleziona utenti per desktop:" 12 50 5 \
    2>&1 1>&5)
exec 5>&-

if [ -n "$SELECTED_USERS" ]; then
    log "Utenti selezionati: $SELECTED_USERS"
    
    # Gruppo video (necessario per X.org)
    if [ "$gpu" != "VESA" ] && [ "$gpu" != "SCFB" ]; then
        log "Configurazione gruppo video..."
        pw groupshow video >/dev/null 2>&1 || pw groupadd video
        
        for user in $SELECTED_USERS; do
            pw groupmod video -m "$user"
            log "OK: $user aggiunto a gruppo video"
        done
    fi
    
    # Sudo
    $DIALOG --title "Sudo" \
        --yesno "Abilitare sudo per gli utenti selezionati?" 0 0
    
    if [ $? -eq $BSDDIALOG_YES ]; then
        log "Configurazione sudo..."
        which sudo >/dev/null 2>&1 || install_pkg sudo
        
        if [ -f /usr/local/etc/sudoers ]; then
            if ! grep -q "^%wheel ALL=(ALL:ALL) ALL" /usr/local/etc/sudoers; then
                cp /usr/local/etc/sudoers /usr/local/etc/sudoers.bak
                sed -i '' 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /usr/local/etc/sudoers
                log "OK: Sudo abilitato per gruppo wheel"
            fi
        fi
        
        for user in $SELECTED_USERS; do
            pw groupshow wheel | grep -q "$user" || pw groupmod wheel -m "$user"
            log "OK: $user aggiunto a gruppo wheel"
        done
        
        SUDO_STATUS="Abilitato"
    else
        SUDO_STATUS="Disabilitato"
    fi
    
    # Configurazione per utente
    for user in $SELECTED_USERS; do
        user_home=$(pw usershow "$user" | awk -F: '{print $(NF-1)}')
        log "Configurazione utente: $user (home: $user_home)"
        
        if [ ! -f "${user_home}/.profile" ]; then
            touch "${user_home}/.profile"
        fi
        
        # Locale utente
        if ! grep -q "export LANG=" "${user_home}/.profile" 2>/dev/null; then
            cat >> "${user_home}/.profile" <<EOF

# Desktop locale
export LANG=${LOCALE_CHOICE}
export LC_ALL=${LOCALE_CHOICE}
EOF
        fi
        
        # PulseAudio autostart
        log "Configurazione PulseAudio autostart per $user..."
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
        log "OK: PulseAudio autostart configurato per $user"
        
        # Input Method asiatici fcitx5
        if [ "$NEEDS_FCITX5" = "YES" ]; then
            log "Configurazione fcitx5 per $user..."
            
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
        
        # Configurazione tastiera XFCE
        if [ "$DE_CHOICE" = "XFCE" ]; then
            log "Configurazione tastiera XFCE per $user (layout: $KB_LAYOUT + us)..."
            
            user_config="${user_home}/.config"
            xfce_kb_dir="${user_config}/xfce4/xfconf/xfce-perchannel-xml"
            mkdir -p "${xfce_kb_dir}"
            
            # Layout: primario + us (se primario non è già us)
            if [ "$KB_LAYOUT" = "us" ]; then
                KB_LAYOUTS="us"
                KB_VARIANTS=""
            else
                KB_LAYOUTS="${KB_LAYOUT},us"
                KB_VARIANTS=","
            fi
            
            # Crea/aggiorna configurazione tastiera
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
            log "OK: Tastiera ${KB_LAYOUTS} configurata per $user"
        fi
        
        # Configurazione tastiera KDE
        if [ "$DE_CHOICE" = "KDE" ]; then
            log "Configurazione tastiera KDE per $user (layout: $KB_LAYOUT + us)..."
            
            user_config="${user_home}/.config"
            mkdir -p "${user_config}"
            
            # Layout: primario + us (se primario non è già us)
            if [ "$KB_LAYOUT" = "us" ]; then
                KDE_LAYOUTS="us"
            else
                KDE_LAYOUTS="${KB_LAYOUT},us"
            fi
            
            # KDE Plasma 5/6 usa kxkbrc
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
            log "OK: Tastiera ${KDE_LAYOUTS} configurata per $user"
        fi
        
        # Configurazione tastiera GNOME
        if [ "$DE_CHOICE" = "GNOME" ]; then
            log "Configurazione tastiera GNOME per $user (layout: $KB_LAYOUT + us)..."
            
            user_config="${user_home}/.config"
            mkdir -p "${user_config}/autostart"
            
            # Layout: primario + us (se primario non è già us)
            if [ "$KB_LAYOUT" = "us" ]; then
                GNOME_LAYOUTS="[('xkb', 'us')]"
            else
                GNOME_LAYOUTS="[('xkb', '${KB_LAYOUT}'), ('xkb', 'us')]"
            fi
            
            # Script per configurare tastiera al login (GNOME usa gsettings)
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
            log "OK: Tastiera ${KB_LAYOUT}+us configurata per $user (attiva al primo login)"
        fi
        
        # Configurazione LibreOffice con lingua
        if echo "$EXTRA_APPS" | grep -q "libreoffice"; then
            if [ "$LANG_CODE" != "en" ]; then
                log "Configurazione LibreOffice per $user (lingua: $LANG_CODE)..."
                
                lo_config="${user_home}/.config/libreoffice/4/user"
                mkdir -p "${lo_config}"
                
                # registrymodifications.xcu per impostare lingua UI e locale
                cat > "${lo_config}/registrymodifications.xcu" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<item oor:path="/org.openoffice.Office.Linguistic/General"><prop oor:name="UILocale" oor:op="fuse"><value>${LOCALE_CHOICE}</value></prop></item>
<item oor:path="/org.openoffice.Setup/L10N"><prop oor:name="ooLocale" oor:op="fuse"><value>${LANG_CODE}</value></prop></item>
<item oor:path="/org.openoffice.Setup/L10N"><prop oor:name="ooSetupSystemLocale" oor:op="fuse"><value>${LOCALE_CHOICE}</value></prop></item>
</oor:items>
EOF
                chown -R "${user}:${user}" "${user_home}/.config/libreoffice"
                log "OK: LibreOffice configurato per lingua ${LANG_CODE}"
            fi
        fi
        
        chown "${user}:${user}" "${user_home}/.profile"
    done
fi

# --- 12. VERIFICA FINALE ---

log "=== Verifica installazione ==="

# Verifica driver video installato
if [ -n "$GPU_PKGS" ]; then
    for pkg in $GPU_PKGS; do
        if pkg info "$pkg" >/dev/null 2>&1; then
            log "✓ $pkg installato"
        else
            log "✗ MANCA: $pkg"
        fi
    done
fi

# Verifica display manager
if pkg info "$DM_SERVICE" >/dev/null 2>&1; then
    log "✓ Display manager $DM_SERVICE installato"
else
    log "✗ MANCA: Display manager $DM_SERVICE"
fi

# Verifica kld_list
if sysrc -n kld_list >/dev/null 2>&1; then
    log "✓ kld_list configurato: $(sysrc -n kld_list)"
else
    log "✗ ATTENZIONE: kld_list non configurato"
fi

# Verifica servizi critici abilitati
log "Verifica servizi critici..."
SERVICES_OK=true
for svc in dbus ${DM_SERVICE}; do
    if sysrc -n ${svc}_enable 2>/dev/null | grep -q YES; then
        log "✓ Servizio $svc abilitato"
    else
        log "✗ ATTENZIONE: Servizio $svc non abilitato"
        SERVICES_OK=false
    fi
done

# Verifica PulseAudio daemon
if sysrc -n snd_driver 2>/dev/null | grep -q "snd_driver"; then
    log "✓ Driver audio (snd_driver) configurato"
else
    log "✗ ATTENZIONE: snd_driver non configurato"
fi

if [ "$SERVICES_OK" = "false" ]; then
    log "⚠ Alcuni servizi critici non sono abilitati correttamente"
fi

log "=== Installazione completata ==="

# --- 13. COMPLETAMENTO ---

clear
cat <<EOF
===================================================
    Installazione Desktop FreeBSD Completata!
===================================================

Desktop Environment: $DE_CHOICE
Display Manager: $DM_SERVICE
Lingua: $LOCALE_CHOICE
Layout Tastiera: $KB_LAYOUT$([ "$KB_LAYOUT" != "us" ] && echo " + us (secondario)")
Driver Video: $gpu

Utenti configurati:
$(echo "$SELECTED_USERS" | tr ' ' '\n' | sed 's/^/  - /')

Sudo: ${SUDO_STATUS:-Non configurato}

Ottimizzazioni applicate:
  - Memoria condivisa aumentata
  - Audio (snd_driver caricato, PulseAudio fixed)
$([ "$IS_LAPTOP" = "YES" ] && echo "  - Power management laptop (powerdxx)")
$([ "$HAS_SSD" = "YES" ] && echo "  - TRIM automatico SSD")
$([ "$DE_CHOICE" = "KDE" ] && echo "  - Ottimizzazioni IPC KDE")
$([ "$gpu" = "VirtualBox" ] && [ "$BOOTMETHOD" = "UEFI" ] && echo "  - Fix VirtualBox UEFI poweroff")
$([ "$NEEDS_FCITX5" = "YES" ] && echo "  - Input Method fcitx5 configurato")

Localizzazione:
$([ "$LANG_CODE" != "en" ] && echo "  - Dizionari spell-check e hyphenation installati")
$([ -n "$PKG_LANG_APPS" ] && echo "  - Language pack applicazioni: LibreOffice, Thunderbird")
$([ "$LANG_CODE" != "en" ] && echo "  - LibreOffice pre-configurato in ${LANG_CODE}")
$([ "$LANG_CODE" != "en" ] && echo "  - Firefox: UI in inglese (installa firefox-i18n-* manualmente se disponibile)")

$([ -n "$EXTRA_APPS" ] && echo "Applicazioni installate:" && echo "$EXTRA_APPS" | tr ' ' '\n' | sed 's/^/  - /')

Log completo: $LOGFILE

===================================================
         RIAVVIA IL SISTEMA CON: reboot
===================================================

EOF

# Mostra log se ci sono errori
if grep -q "ERRORE" "$LOGFILE"; then
    $DIALOG --title "Attenzione" \
        --yesno "Rilevati alcuni errori durante l'installazione.\n\nVuoi vedere il log?" 0 0
    
    if [ $? -eq $BSDDIALOG_YES ]; then
        $DIALOG --title "Log Installazione" \
            --textbox "$LOGFILE" 0 0
    fi
fi

# Chiedi se riavviare
$DIALOG --title "Installazione Completata" \
    --yesno "Riavviare ora il sistema?" 0 0

if [ $? -eq $BSDDIALOG_YES ]; then
    log "Riavvio sistema..."
    reboot
fi
