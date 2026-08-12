#!/bin/bash

set -Eeuo pipefail

REPO_ROOT=${1:-/work/repositorios/compilados/15.0}
PACKAGES_DIR="$REPO_ROOT/packages"
METADATA_DIR="$REPO_ROOT/metadata"
TMP_INDEX="$REPO_ROOT/.PACKAGES.TXT.$$.tmp"

log()
{
    printf '%s\n' "[indice] $*"
}

package_base_name()
{
    local filename=$1
    local stem rest
    stem=${filename%.txz}
    stem=${stem%.tgz}
    stem=${stem%.tlz}
    rest=${stem%-*}
    rest=${rest%-*}
    rest=${rest%-*}
    printf '%s\n' "$rest"
}

uncompressed_kib()
{
    local package_file=$1
    local bytes
    case "$package_file" in
        *.txz) bytes=$(xz -dc "$package_file" | wc -c) ;;
        *.tgz) bytes=$(gzip -dc "$package_file" | wc -c) ;;
        *.tlz) bytes=$(lzma -dc "$package_file" | wc -c) ;;
        *) bytes=0 ;;
    esac
    printf '%s\n' $(( (bytes + 1023) / 1024 ))
}

mkdir -p "$PACKAGES_DIR" "$METADATA_DIR"
: > "$TMP_INDEX"

mapfile -t package_files < <(
    find "$PACKAGES_DIR" -maxdepth 1 -type f \
        \( -name '*.txz' -o -name '*.tgz' -o -name '*.tlz' \) \
        -print | LC_ALL=C sort
)

for package_file in "${package_files[@]}"; do
    filename=$(basename "$package_file")
    package_name=$(package_base_name "$filename")
    compressed_bytes=$(stat -c %s "$package_file")
    compressed_kib=$(( (compressed_bytes + 1023) / 1024 ))
    unpacked_kib=$(uncompressed_kib "$package_file")
    requirements=''
    if [ -r "$METADATA_DIR/${package_name}.requires" ]; then
        requirements=$(tr ' ' ',' < "$METADATA_DIR/${package_name}.requires" |
            sed -e 's/,,*/,/g' -e 's/^,//' -e 's/,$//')
    fi

    {
        printf 'PACKAGE NAME:  %s\n' "$filename"
        printf '%s\n' 'PACKAGE LOCATION:  ./packages'
        printf 'PACKAGE SIZE (compressed):  %s K\n' "$compressed_kib"
        printf 'PACKAGE SIZE (uncompressed):  %s K\n' "$unpacked_kib"
        printf 'PACKAGE REQUIRED:  %s\n' "$requirements"
        printf '%s\n' 'PACKAGE CONFLICTS:'
        printf '%s\n' 'PACKAGE SUGGESTS:'
        printf '%s\n' 'PACKAGE DESCRIPTION:'
        if ! tar -xOf "$package_file" install/slack-desc 2>/dev/null &&
           ! tar -xOf "$package_file" ./install/slack-desc 2>/dev/null; then
            printf '%s: pacote compilado localmente a partir do SBo 15.0\n' \
                "$package_name"
        fi
        printf '\n'
    } >> "$TMP_INDEX"
done

mv "$TMP_INDEX" "$REPO_ROOT/PACKAGES.TXT"
gzip -9 -c "$REPO_ROOT/PACKAGES.TXT" > "$REPO_ROOT/PACKAGES.TXT.gz"

(
    cd "$REPO_ROOT"
    find packages -maxdepth 1 -type f \
        \( -name '*.txz' -o -name '*.tgz' -o -name '*.tlz' \) \
        -print | LC_ALL=C sort > FILELIST.TXT
    if [ -s FILELIST.TXT ]; then
        xargs md5sum < FILELIST.TXT > CHECKSUMS.md5
        xargs sha256sum < FILELIST.TXT > CHECKSUMS.sha256
    else
        : > CHECKSUMS.md5
        : > CHECKSUMS.sha256
    fi
    gzip -9 -c CHECKSUMS.md5 > CHECKSUMS.md5.gz
)

printf '%s - indice regenerado: %s pacote(s)\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#package_files[@]}" \
    >> "$REPO_ROOT/ChangeLog.txt"

log "Repositorio pronto: $REPO_ROOT (${#package_files[@]} pacote(s))."
