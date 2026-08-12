#!/bin/sh

# Instala e configura Podman rootless no hospedeiro.
# Suporta Arch Linux, Debian, Ubuntu, Fedora e Slackware 15.0/Salix 15.0.

set -eu

TARGET_USER=${1:-${SUDO_USER:-}}
TARGET_HOME=${2:-}
SALIX_BASE='https://download.salixos.org/x86_64/15.0/'
SALIX_EXTRA='https://download.salixos.org/x86_64/extra-15.0/'
SALIX_SLACKWARE='https://download.salixos.org/x86_64/slackware-15.0/'

log()
{
    printf '%s\n' "[hospedeiro] $*"
}

die()
{
    printf '%s\n' "ERRO: $*" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    die 'execute este script como root ou use --preparar-hospedeiro no controlador'
fi

[ -n "$TARGET_USER" ] || die 'nao foi possivel identificar o usuario comum'
case "$TARGET_USER" in
    root) die 'Podman rootless deve ser preparado para um usuario comum, nao para root' ;;
    *[!A-Za-z0-9_.-]*) die 'nome de usuario invalido' ;;
esac

if [ -z "$TARGET_HOME" ]; then
    TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | awk -F: '{print $6; exit}')
fi
[ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ] ||
    die "diretorio pessoal nao localizado para $TARGET_USER"

if [ -r /etc/os-release ]; then
    # O arquivo e mantido pela distribuicao e contem somente atribuicoes.
    . /etc/os-release
else
    ID=''
    ID_LIKE=''
fi

install_arch()
{
    log 'Instalando Podman e suporte rootless no Arch Linux.'
    pacman -S --needed --noconfirm \
        podman fuse-overlayfs slirp4netns shadow
}

install_debian_family()
{
    log 'Instalando Podman e suporte rootless no Debian/Ubuntu.'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        podman fuse-overlayfs slirp4netns uidmap dbus-user-session
}

install_fedora()
{
    log 'Instalando Podman e suporte rootless no Fedora.'
    dnf install -y \
        podman fuse-overlayfs slirp4netns shadow-utils
}

download_file()
{
    destination=$1
    url=$2
    if command -v wget >/dev/null 2>&1; then
        wget --https-only --timeout=60 --tries=3 -O "$destination" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl --fail --location --proto '=https' --retry 3 \
            --output "$destination" "$url"
    else
        die 'Slackware precisa de wget ou curl para instalar slapt-get'
    fi
}

salix_package_relative_path()
{
    package_name=$1
    awk -v wanted="$package_name" '
        $1 == "PACKAGE" && $2 == "NAME:" {
            filename = $3
            stem = filename
            sub(/\.(t[gx]z|tlz)$/, "", stem)
            pieces = split(stem, field, "-")
            name = ""
            for (i = 1; i <= pieces - 3; i++)
                name = name (name == "" ? "" : "-") field[i]
            selected = (name == wanted)
            next
        }
        selected && $1 == "PACKAGE" && $2 == "LOCATION:" {
            location = $3
            sub(/^\.\//, "", location)
            print location "/" filename
            exit
        }
    ' /tmp/salix-host-PACKAGES.TXT
}

bootstrap_slapt_get()
{
    command -v slapt-get >/dev/null 2>&1 && return 0

    log 'Instalando slapt-get oficial do Salix para preparar o Slackware.'
    download_file /tmp/salix-host-PACKAGES.TXT "${SALIX_BASE}PACKAGES.TXT"
    relative=$(salix_package_relative_path slapt-get)
    [ -n "$relative" ] || die 'pacote slapt-get nao localizado no repositorio Salix 15.0'

    package=/tmp/$(basename "$relative")
    md5_file=${package%.*}.md5
    download_file "$package" "${SALIX_BASE}${relative}"
    download_file "$md5_file" \
        "${SALIX_BASE}${relative%/*}/$(basename "${relative%.*}.md5")"

    expected=$(awk '{print $1; exit}' "$md5_file")
    actual=$(md5sum "$package" | awk '{print $1}')
    [ -n "$expected" ] && [ "$expected" = "$actual" ] ||
        die 'checksum do pacote slapt-get invalido'

    /sbin/upgradepkg --install-new "$package"
    rm -f "$package" "$md5_file" /tmp/salix-host-PACKAGES.TXT
}

append_source()
{
    line=$1
    config=/etc/slapt-get/slapt-getrc
    mkdir -p /etc/slapt-get
    touch "$config"
    grep -Fqx "$line" "$config" || printf '%s\n' "$line" >> "$config"
}

install_slackware()
{
    if [ ! -r /etc/slackware-version ]; then
        die 'sistema identificado como Slackware, mas /etc/slackware-version nao existe'
    fi
    grep -Eq '^(Slackware|Salix) 15\.0' /etc/slackware-version ||
        die 'este preparador oferece suporte ao Slackware/Salix 15.0'

    bootstrap_slapt_get
    append_source "SOURCE=${SALIX_SLACKWARE}:OFFICIAL"
    append_source "SOURCE=${SALIX_BASE}:PREFERRED"
    append_source "SOURCE=${SALIX_EXTRA}:CUSTOM"

    log 'Instalando Podman e dependencias pelo slapt-get.'
    slapt-get --update
    slapt-get --install podman fuse-overlayfs slirp4netns
}

case "${ID:-}" in
    arch|cachyos|endeavouros|manjaro) install_arch ;;
    debian|ubuntu|linuxmint|pop) install_debian_family ;;
    fedora) install_fedora ;;
    slackware|salix) install_slackware ;;
    *)
        case " ${ID_LIKE:-} " in
            *' arch '*) install_arch ;;
            *' debian '*) install_debian_family ;;
            *' fedora '*) install_fedora ;;
            *' slackware '*) install_slackware ;;
            *) die "distribuicao hospedeira nao suportada: ${ID:-desconhecida}" ;;
        esac
        ;;
esac

command -v podman >/dev/null 2>&1 || die 'Podman nao foi instalado'
command -v fuse-overlayfs >/dev/null 2>&1 || die 'fuse-overlayfs nao foi instalado'

configure_user_namespaces()
{
    if [ -e /proc/sys/kernel/unprivileged_userns_clone ]; then
        current=$(cat /proc/sys/kernel/unprivileged_userns_clone)
        if [ "$current" != 1 ]; then
            log 'Habilitando user namespaces para Podman rootless.'
            printf '%s\n' 'kernel.unprivileged_userns_clone = 1' \
                > /etc/sysctl.d/90-podman-rootless.conf
            sysctl -w kernel.unprivileged_userns_clone=1 >/dev/null
        fi
    fi
}

next_subid_start()
{
    files=$1
    awk -F: 'BEGIN {maximum=99999}
        NF >= 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
            ending = $2 + $3 - 1
            if (ending > maximum) maximum = ending
        }
        END {
            start = maximum + 1
            remainder = start % 65536
            if (remainder != 0) start += 65536 - remainder
            print start
        }' $files 2>/dev/null
}

configure_subids()
{
    touch /etc/subuid /etc/subgid
    if ! awk -F: -v user="$TARGET_USER" '$1 == user {found=1} END {exit !found}' /etc/subuid; then
        start=$(next_subid_start /etc/subuid)
        printf '%s:%s:65536\n' "$TARGET_USER" "$start" >> /etc/subuid
        log "Faixa subuid criada para $TARGET_USER: $start-$(($start + 65535))."
    fi
    if ! awk -F: -v user="$TARGET_USER" '$1 == user {found=1} END {exit !found}' /etc/subgid; then
        start=$(next_subid_start /etc/subgid)
        printf '%s:%s:65536\n' "$TARGET_USER" "$start" >> /etc/subgid
        log "Faixa subgid criada para $TARGET_USER: $start-$(($start + 65535))."
    fi
}

filesystem_for_home()
{
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -n -o FSTYPE -T "$TARGET_HOME" 2>/dev/null || :
    elif command -v stat >/dev/null 2>&1; then
        stat -f -c %T "$TARGET_HOME" 2>/dev/null || :
    fi
}

configure_storage()
{
    filesystem=$(filesystem_for_home)
    case "$filesystem" in
        btrfs|zfs|ecryptfs|fuseblk)
            config_dir="$TARGET_HOME/.config/containers"
            config_file="$config_dir/storage.conf"
            if [ ! -e "$config_file" ]; then
                log "Configurando fuse-overlayfs para o sistema de arquivos $filesystem."
                mkdir -p "$config_dir"
                fuse_path=$(command -v fuse-overlayfs)
                cat > "$config_file" <<EOF
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "$fuse_path"
EOF
                chown -R "$TARGET_USER" "$TARGET_HOME/.config/containers"
            else
                log "storage.conf existente foi preservado: $config_file"
            fi
            ;;
        '') log 'Nao foi possivel identificar o sistema de arquivos da pasta pessoal.' ;;
        *) log "Sistema de arquivos detectado: $filesystem; configuracao padrao do Podman mantida." ;;
    esac
}

run_as_target()
{
    target_uid=$(id -u "$TARGET_USER")
    target_runtime="/run/user/$target_uid"
    if [ ! -d "$target_runtime" ]; then
        mkdir -p "$target_runtime"
        chown "$TARGET_USER" "$target_runtime"
        chmod 0700 "$target_runtime"
    fi
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$TARGET_USER" -- env \
            "HOME=$TARGET_HOME" \
            "XDG_RUNTIME_DIR=$target_runtime" \
            "$@"
    else
        command_string="HOME='$TARGET_HOME' XDG_RUNTIME_DIR='$target_runtime'"
        for argument in "$@"; do
            case "$argument" in
                *"'"*) die 'argumento inseguro ao trocar de usuario' ;;
            esac
            command_string="$command_string '$argument'"
        done
        su -s /bin/sh "$TARGET_USER" -c "$command_string"
    fi
}

configure_user_namespaces
configure_subids
configure_storage

log 'Validando Podman rootless como usuario comum.'
if ! run_as_target podman info; then
    die 'Podman ainda falhou; a mensagem acima identifica a configuracao restante'
fi

log 'Hospedeiro preparado com sucesso.'
