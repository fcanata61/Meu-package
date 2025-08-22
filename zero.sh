#!/bin/sh
# zero - Gerenciador de pacotes minimalista estilo KISS
DB_DIR="/var/db/zero/installed"
PKG_CACHE="/var/cache/zero"
REPOS="$HOME/repos"

die() {
    echo "Erro: $*" >&2
    exit 1
}

pkg_path() {
    for repo in $REPOS/*; do
        [ -d "$repo/$1" ] && echo "$repo/$1" && return 0
    done
    return 1
}
# Funções de fetch/extract/checksum
fetch_sources() {
    pkg=$1
    path=$2
    cache="$PKG_CACHE/$pkg/sources"

    mkdir -p "$cache"

    while read -r src; do
        case $src in
            http://*|https://*)
                echo "==> Baixando $src"
                curl -L "$src" -o "$cache/$(basename "$src")" || die "Falha ao baixar $src"
                ;;
            *)
                echo "==> Copiando $src"
                cp "$path/$src" "$cache/" || die "Falha ao copiar $src"
                ;;
        esac
    done < "$path/sources"
}

verify_checksums() {
    pkg=$1
    path=$(pkg_path "$pkg")
    cache="$PKG_CACHE/$pkg/sources"

    [ -f "$path/checksums" ] || die "Arquivo checksums não encontrado em $pkg"

    echo "==> Verificando checksums"
    cd "$cache" || die "Falha ao entrar em $cache"
    # cada linha: "sha256sum  filename"
    while read -r sum file; do
        echo "$sum  $file" | sha256sum -c - || die "Checksum inválido para $file"
    done < "$path/checksums"
}

extract_sources() {
    pkg=$1
    path=$(pkg_path "$pkg")
    cache="$PKG_CACHE/$pkg/sources"
    builddir="$PKG_CACHE/$pkg/buildsrc"

    rm -rf "$builddir"
    mkdir -p "$builddir"
    # 1. Extrair tarballs
    for file in "$cache"/*; do
        case $file in
            *.tar.gz|*.tgz) tar -xzf "$file" -C "$builddir" ;;
            *.tar.xz)       tar -xJf "$file" -C "$builddir" ;;
            *.tar.bz2)      tar -xjf "$file" -C "$builddir" ;;
        esac
    done
    # 2. Achar diretório do source principal
    srcdir=$(find "$builddir" -mindepth 1 -maxdepth 1 -type d | head -n1)
    # 3. Aplicar patches em ordem
    while read -r src; do
        case $src in
            *.patch)
                patchfile="$cache/$(basename "$src")"
                echo "==> Aplicando patch $patchfile"
                (cd "$srcdir" && patch -p1 < "$patchfile") || die "Falha ao aplicar patch"
                ;;
        esac
    done < "$path/sources"

    echo "==> Fontes extraídos em $srcdir"
}
# Comandos principais
pkg_build() {
    pkg=$1
    path=$(pkg_path "$pkg") || die "Pacote não existe"

    echo "==> Construindo $pkg"
    # 1. Baixar/copiar fontes
    fetch_sources "$pkg" "$path"
    # 2. Verificar checksums
    verify_checksums "$pkg"
    # 3. Extrair fontes + aplicar patches
    extract_sources "$pkg"
    # 4. Preparar DESTDIR
    DESTDIR="$PKG_CACHE/$pkg/pkgdir"
    rm -rf "$DESTDIR"
    mkdir -p "$DESTDIR"
    # 5. Entrar no source principal
    srcdir=$(find "$PKG_CACHE/$pkg/buildsrc" -mindepth 1 -maxdepth 1 -type d | head -n1)
    cd "$srcdir" || die "Falha ao entrar no source"
    # 6. Rodar script build do pacote
    echo "==> Executando script build"
    sh "$path/build" "$DESTDIR" || die "Falha no build"
    # 7. Empacotar resultado
    cd "$DESTDIR" || die "Falha ao entrar no DESTDIR"
    tar -czf "$PKG_CACHE/$pkg.tar.gz" . || die "Falha no empacotamento"

    echo "==> Pacote $pkg.tar.gz criado em $PKG_CACHE"
}

pkg_install() {
    pkg=$1
    echo "==> Instalando $pkg"

    mkdir -p "$DB_DIR/$pkg"
    tar -xzf "$PKG_CACHE/$pkg.tar.gz" -C / || die "Falha ao instalar"

    cp "$(pkg_path "$pkg")/version" "$DB_DIR/$pkg/version"
    cp "$(pkg_path "$pkg")/depends" "$DB_DIR/$pkg/depends" 2>/dev/null || true
    tar -tzf "$PKG_CACHE/$pkg.tar.gz" > "$DB_DIR/$pkg/manifest"
}

pkg_remove() {
    pkg=$1
    echo "==> Removendo $pkg"
    manifest="$DB_DIR/$pkg/manifest"
    [ -f "$manifest" ] || die "Manifesto não encontrado"

    while read -r file; do
        rm -f "/$file"
    done < "$manifest"

    rm -rf "$DB_DIR/$pkg"
    echo "==> $pkg removido"
}

pkg_list() {
    echo "==> Pacotes instalados:"
    ls "$DB_DIR"
}

pkg_search() {
    echo "==> Procurando pacote: $1"
    pkg_path "$1" || die "Pacote não encontrado"
}
# Roteador de comandos
case $1 in
    search) shift; pkg_search "$@" ;;
    list)   pkg_list ;;
    build)  shift; pkg_build "$@" ;;
    install) shift; pkg_install "$@" ;;
    remove) shift; pkg_remove "$@" ;;
    *)
        echo "Uso: $0 {search|list|build|install|remove} [pacote]"
        ;;
esac
