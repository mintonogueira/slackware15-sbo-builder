#!/bin/bash

set -Eeuo pipefail

PROJECT_DIR=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d /tmp/slackware-repo-test.XXXXXX)

cleanup()
{
    case "$TEMP_DIR" in
        /tmp/slackware-repo-test.*) rm -rf "$TEMP_DIR" ;;
    esac
}
trap cleanup EXIT

sh -n "$PROJECT_DIR/compilar-slackbuilds.sh"
sh -n "$PROJECT_DIR/preparar-hospedeiro.sh"
sh -n "$PROJECT_DIR/parar-execucao.sh"
sh -n "$PROJECT_DIR/scripts/provisionar-imagem.sh"
bash -n "$PROJECT_DIR/scripts/inicializar-rotinas.sh"
bash -n "$PROJECT_DIR/scripts/entrypoint-servico.sh"
bash -n "$PROJECT_DIR/scripts/gerenciar-repositorios.sh"
bash -n "$PROJECT_DIR/scripts/gerar-indice-repositorio.sh"
bash -n "$PROJECT_DIR/scripts/atualizar-navegadores.sh"
bash -n "$PROJECT_DIR/scripts/verificar-navegadores-diariamente.sh"
bash -n "$PROJECT_DIR/slackbuilds/brave-browser/brave-browser.SlackBuild"
bash -n "$PROJECT_DIR/slackbuilds/google-chrome/google-chrome.SlackBuild"
sh -n "$PROJECT_DIR/slackbuilds/brave-browser/doinst.sh"
sh -n "$PROJECT_DIR/slackbuilds/google-chrome/doinst.sh"

# Versoes diferentes do Podman retornam o ID da imagem com ou sem o prefixo
# "sha256:". O controlador deve aceitar ambos e persistir o formato normalizado.
PULL_FAKEBIN="$TEMP_DIR/pull-fakebin"
PULL_DATA="$TEMP_DIR/pull-dados"
PULL_HASH='63cc3e66abe3e05f4fffeb66a9ed83548a56c3822ac58c1db448bd87633d018f'
mkdir -p "$PULL_FAKEBIN"
cat > "$PULL_FAKEBIN/podman" <<'EOF'
#!/bin/sh
case "$1 ${2:-}" in
    'info ') exit 0 ;;
    'inspect -f') printf '%s\n' false; exit 0 ;;
    'container exists') exit 1 ;;
    'pull ghcr.io/mintonogueira/slackware15-sbo-builder:15.0')
        printf '%s\n' "$PODMAN_FAKE_IMAGE_ID"
        exit 0
        ;;
    'image inspect') printf '%s\n' "$PODMAN_FAKE_IMAGE_ID"; exit 0 ;;
    *) printf 'podman falso recebeu: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
chmod 0755 "$PULL_FAKEBIN/podman"
for PULL_ID in "$PULL_HASH" "sha256:$PULL_HASH"; do
    rm -rf "$PULL_DATA"
    PATH="$PULL_FAKEBIN:$PATH" \
    PODMAN_FAKE_IMAGE_ID="$PULL_ID" \
    SLACKBUILD_DATA_DIR="$PULL_DATA" \
        "$PROJECT_DIR/compilar-slackbuilds.sh" --atualizar-imagem >/dev/null
    grep -qx "sha256:$PULL_HASH" \
        "$PULL_DATA/.estado/imagem-sha256.txt"
done

ROTINAS_TEST_ROOT="$TEMP_DIR/rotinas"
CUSTOM_TEST_ROOT="$TEMP_DIR/slackbuilds-personalizados"
ROTINAS_ACTIVE="$TEMP_DIR/rotinas-ativas"
mkdir -p "$ROTINAS_TEST_ROOT/scripts" "$CUSTOM_TEST_ROOT"
for routine_script in \
    entrypoint-servico.sh \
    gerenciar-repositorios.sh \
    gerar-indice-repositorio.sh \
    atualizar-navegadores.sh \
    verificar-navegadores-diariamente.sh; do
    cp -p "$PROJECT_DIR/scripts/$routine_script" \
        "$ROTINAS_TEST_ROOT/scripts/$routine_script"
done
cp -Rp "$PROJECT_DIR/slackbuilds/." "$CUSTOM_TEST_ROOT/"
(
    cd "$ROTINAS_TEST_ROOT"
    find scripts -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
(
    cd "$CUSTOM_TEST_ROOT"
    find . -mindepth 2 -maxdepth 2 -type f -printf '%P\0' |
        sort -z | xargs -0 sha256sum > SHA256SUMS
)

# Um arquivo remoto previamente armazenado e verificado deve substituir a
# copia local sem tentar acessar a rede.
REMOTE_OVERRIDE="$ROTINAS_TEST_ROOT/cache/remotas/scripts/gerenciar-repositorios.sh"
mkdir -p "$(dirname "$REMOTE_OVERRIDE")"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" rotina-remota-verificada' \
    > "$REMOTE_OVERRIDE"
chmod 0755 "$REMOTE_OVERRIDE"
REMOTE_SHA=$(sha256sum "$REMOTE_OVERRIDE" | awk '{print $1}')
printf '%s|%s|%s\n' "$REMOTE_SHA" 'scripts/gerenciar-repositorios.sh' \
    'https://example.invalid/gerenciar-repositorios.sh' \
    > "$ROTINAS_TEST_ROOT/links.conf"

WORKROOT="$TEMP_DIR/workroot" \
ROTINAS_ROOT="$ROTINAS_TEST_ROOT" \
SLACKBUILDS_PERSONALIZADOS_ROOT="$CUSTOM_TEST_ROOT" \
ROTINAS_ATIVAS_ROOT="$ROTINAS_ACTIVE" \
ROTINAS_NAO_LINKAR=1 \
    "$PROJECT_DIR/scripts/inicializar-rotinas.sh" \
    --preparar-rotinas-apenas >/dev/null
cmp "$REMOTE_OVERRIDE" "$ROTINAS_ACTIVE/scripts/gerenciar-repositorios.sh"
grep -q 'scripts/entrypoint-servico.sh' \
    "$TEMP_DIR/workroot/.estado/rotinas-ativas.sha256"

printf '%s\n' '# adulterado depois do manifesto' \
    >> "$ROTINAS_TEST_ROOT/scripts/entrypoint-servico.sh"
set +e
WORKROOT="$TEMP_DIR/workroot-adulterado" \
ROTINAS_ROOT="$ROTINAS_TEST_ROOT" \
SLACKBUILDS_PERSONALIZADOS_ROOT="$CUSTOM_TEST_ROOT" \
ROTINAS_ATIVAS_ROOT="$TEMP_DIR/rotinas-ativas-adulteradas" \
ROTINAS_NAO_LINKAR=1 \
    "$PROJECT_DIR/scripts/inicializar-rotinas.sh" \
    --preparar-rotinas-apenas >/dev/null 2>&1
rotinas_rc=$?
set -e
[ "$rotinas_rc" -ne 0 ]

# O controlador deve criar automaticamente os dois volumes editaveis antes de
# usar um conteiner ja existente.
HOST_FAKEBIN="$TEMP_DIR/host-fakebin"
HOST_DATA="$TEMP_DIR/host-dados"
mkdir -p "$HOST_FAKEBIN" "$HOST_DATA/.estado"
printf '%s\n' 'host' > "$HOST_DATA/.estado/pergunta-vpn-respondida"
cat > "$HOST_FAKEBIN/podman" <<'EOF'
#!/bin/sh
case "$1 ${2:-}" in
    'info ') exit 0 ;;
    'image exists') exit 0 ;;
    'container exists') exit 0 ;;
    'inspect -f') printf '%s\n' true; exit 0 ;;
    'exec slackware15-repositorio') exit 0 ;;
    'restart slackware15-repositorio') exit 0 ;;
    *) printf 'podman falso recebeu: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
chmod 0755 "$HOST_FAKEBIN/podman"
PATH="$HOST_FAKEBIN:$PATH" SLACKBUILD_DATA_DIR="$HOST_DATA" \
    "$PROJECT_DIR/compilar-slackbuilds.sh" --iniciar >/dev/null
test -x "$HOST_DATA/rotinas/scripts/gerenciar-repositorios.sh"
test -x "$HOST_DATA/slackbuilds-personalizados/brave-browser/brave-browser.SlackBuild"
test -x "$HOST_DATA/slackbuilds-personalizados/google-chrome/google-chrome.SlackBuild"
(
    cd "$HOST_DATA/rotinas"
    sha256sum -c SHA256SUMS >/dev/null
)
(
    cd "$HOST_DATA/slackbuilds-personalizados"
    sha256sum -c SHA256SUMS >/dev/null
)

if grep -Eq '^COPY (scripts/(entrypoint-servico|gerenciar-repositorios|gerar-indice-repositorio|atualizar-navegadores|verificar-navegadores-diariamente)|slackbuilds/)' \
    "$PROJECT_DIR/Containerfile"; then
    printf '%s\n' 'ERRO: a imagem ainda incorpora uma rotina operacional.' >&2
    exit 1
fi

"$PROJECT_DIR/scripts/atualizar-navegadores.sh" --self-test

set +e
WORKROOT="$TEMP_DIR/failure-state" \
BROWSER_SLACKBUILDS_ROOT="$TEMP_DIR/slackbuild-inexistente" \
    "$PROJECT_DIR/scripts/atualizar-navegadores.sh" --brave \
    >/dev/null 2>&1
failure_rc=$?
set -e
[ "$failure_rc" -ne 0 ]
grep -q '^FALHA (' \
    "$TEMP_DIR/failure-state/.estado/navegadores/status-ultima-tentativa"

grep -q 'brave-browser-apt-release.s3.brave.com/dists/stable' \
    "$PROJECT_DIR/slackbuilds/brave-browser/brave-browser.SlackBuild"
grep -q 'dl.google.com/linux/chrome/deb/dists/stable' \
    "$PROJECT_DIR/slackbuilds/google-chrome/google-chrome.SlackBuild"
grep -q 'SOURCE=http://IP_DO_SERVIDOR:8080/navegadores/15.0/:CUSTOM' \
    "$PROJECT_DIR/scripts/gerenciar-repositorios.sh"

FAKE_MAKEPKG="$TEMP_DIR/makepkg"
cat > "$FAKE_MAKEPKG" <<'EOF'
#!/bin/sh
set -eu
target=''
for argument do
    target=$argument
done
[ -n "$target" ]
tar -cJf "$target" .
EOF
chmod 0755 "$FAKE_MAKEPKG"

make_test_deb()
{
    browser=$1
    source_file=$2
    data_root="$TEMP_DIR/deb-$browser/data"
    archive_root="$TEMP_DIR/deb-$browser/archive"
    rm -rf "$TEMP_DIR/deb-$browser"
    mkdir -p "$data_root/etc/apt/sources.list.d" "$archive_root"
    printf '%s\n' 'nao deve entrar no txz' \
        > "$data_root/etc/apt/sources.list.d/vendor.list"

    case "$browser" in
        brave)
            mkdir -p "$data_root/opt/brave.com/brave" "$data_root/usr/bin"
            printf '%s\n' '#!/bin/sh' > "$data_root/opt/brave.com/brave/brave-browser"
            printf '%s\n' 'sandbox' > "$data_root/opt/brave.com/brave/brave-sandbox"
            chmod 0755 "$data_root/opt/brave.com/brave/brave-browser"
            chmod 4755 "$data_root/opt/brave.com/brave/brave-sandbox"
            ;;
        google)
            mkdir -p "$data_root/opt/google/chrome" "$data_root/usr/bin"
            printf '%s\n' '#!/bin/sh' > "$data_root/opt/google/chrome/google-chrome"
            printf '%s\n' 'sandbox' > "$data_root/opt/google/chrome/chrome-sandbox"
            chmod 0755 "$data_root/opt/google/chrome/google-chrome"
            chmod 4755 "$data_root/opt/google/chrome/chrome-sandbox"
            ;;
    esac

    printf '%s\n' '2.0' > "$archive_root/debian-binary"
    tar -C "$data_root" -cJf "$archive_root/data.tar.xz" .
    tar -C "$TEMP_DIR" -czf "$archive_root/control.tar.gz" --files-from /dev/null
    (
        cd "$archive_root"
        ar r "$source_file" debian-binary control.tar.gz data.tar.xz >/dev/null
    )
}

mkdir -p "$TEMP_DIR/browser-output"

BRAVE_DEB="$TEMP_DIR/brave.deb"
make_test_deb brave "$BRAVE_DEB"
BRAVE_SHA=$(sha256sum "$BRAVE_DEB" | awk '{print $1}')
UPSTREAM_VERSION=1.99.1 VERSION=1.99.1 \
SOURCE_URL=https://example.invalid/brave.deb SOURCE_SHA256="$BRAVE_SHA" \
SOURCE_FILE="$BRAVE_DEB" OUTPUT="$TEMP_DIR/browser-output" \
TMP="$TEMP_DIR/brave-build" MAKEPKG="$FAKE_MAKEPKG" \
    "$PROJECT_DIR/slackbuilds/brave-browser/brave-browser.SlackBuild" >/dev/null
BRAVE_TXZ="$TEMP_DIR/browser-output/brave-browser-1.99.1-x86_64-1_browser.txz"
test -s "$BRAVE_TXZ"
tar -tf "$BRAVE_TXZ" | grep -q '^./install/slack-desc$'
if tar -tf "$BRAVE_TXZ" | grep -q '^./etc/apt/'; then
    printf '%s\n' 'ERRO: o SlackBuild do Brave preservou arquivos do apt.' >&2
    exit 1
fi

GOOGLE_DEB="$TEMP_DIR/google.deb"
make_test_deb google "$GOOGLE_DEB"
GOOGLE_SHA=$(sha256sum "$GOOGLE_DEB" | awk '{print $1}')
UPSTREAM_VERSION=140.0.1-1 VERSION=140.0.1_1 \
SOURCE_URL=https://example.invalid/google.deb SOURCE_SHA256="$GOOGLE_SHA" \
SOURCE_FILE="$GOOGLE_DEB" OUTPUT="$TEMP_DIR/browser-output" \
TMP="$TEMP_DIR/google-build" MAKEPKG="$FAKE_MAKEPKG" \
    "$PROJECT_DIR/slackbuilds/google-chrome/google-chrome.SlackBuild" >/dev/null
GOOGLE_TXZ="$TEMP_DIR/browser-output/google-chrome-140.0.1_1-x86_64-1_browser.txz"
test -s "$GOOGLE_TXZ"
tar -tf "$GOOGLE_TXZ" | grep -q '^./install/slack-desc$'
if tar -tf "$GOOGLE_TXZ" | grep -q '^./etc/apt/'; then
    printf '%s\n' 'ERRO: o SlackBuild do Google Chrome preservou arquivos do apt.' >&2
    exit 1
fi

mkdir -p "$TEMP_DIR/pacote/install" "$TEMP_DIR/pacote/usr/share" \
    "$TEMP_DIR/repositorio/packages" "$TEMP_DIR/repositorio/metadata"

printf '%s\n' \
    'teste: teste (pacote de validacao)' \
    'teste:' \
    'teste: pacote minimo para validar o indice' \
    > "$TEMP_DIR/pacote/install/slack-desc"
printf '%s\n' 'conteudo' > "$TEMP_DIR/pacote/usr/share/teste.txt"
printf '%s\n' 'dependencia-a dependencia-b' \
    > "$TEMP_DIR/repositorio/metadata/teste.requires"

tar -C "$TEMP_DIR/pacote" -cJf \
    "$TEMP_DIR/repositorio/packages/teste-1.0-x86_64-1_SBo.txz" .

"$PROJECT_DIR/scripts/gerar-indice-repositorio.sh" \
    "$TEMP_DIR/repositorio"

grep -q '^PACKAGE NAME:  teste-1.0-x86_64-1_SBo.txz$' \
    "$TEMP_DIR/repositorio/PACKAGES.TXT"
grep -q '^PACKAGE REQUIRED:  dependencia-a,dependencia-b$' \
    "$TEMP_DIR/repositorio/PACKAGES.TXT"
(
    cd "$TEMP_DIR/repositorio"
    md5sum -c CHECKSUMS.md5
    sha256sum -c CHECKSUMS.sha256
)

printf '%s\n' 'TESTES ESTATICOS OK'
