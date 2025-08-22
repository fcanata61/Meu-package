#!/bin/sh
# zero - gerenciador de pacotes estilo KISS, POSIX sh
# Recursos: fetch, checksum, patch, build, install, remove, list, search,
# deps recursivas com ciclo, strip, revdep, mensagens coloridas.

# ---------- Opções/variáveis (podem ser sobrescritas por ambiente) ----------
: "${ZERO_PATH:=$HOME/repos}"            # Repositórios (separe por :)
: "${ZERO_DB:=/var/db/zero/installed}"   # Banco de pacotes instalados
: "${ZERO_CACHE:=/var/cache/zero}"       # Cache (sources, buildsrc, pkgdir)
: "${ZERO_JOBS:=1}"                      # Futuro: paralelismo (não usado aqui)
: "${ZERO_STRIP:=yes}"                   # yes/no para strip em ELF
: "${ZERO_FETCH_CMD:=auto}"              # auto|curl|wget
umask 022

# ---------- Cores ----------
if [ -t 1 ]; then
    ESC=$(printf '\033')
    C_RESET="${ESC}[0m"
    C_BOLD="${ESC}[1m"
    C_RED="${ESC}[31m"
    C_GRN="${ESC}[32m"
    C_YLW="${ESC}[33m"
    C_BLU="${ESC}[34m"
    C_MAG="${ESC}[35m"
    C_CYN="${ESC}[36m"
else
    C_RESET= C_BOLD= C_RED= C_GRN= C_YLW= C_BLU= C_MAG= C_CYN=
fi

msg() { printf "%s==>%s %s\n" "$C_BOLD$C_CYN" "$C_RESET" "$*"; }
ok()  { printf "%s[ok]%s %s\n" "$C_GRN" "$C_RESET" "$*"; }
wrn() { printf "%s[warn]%s %s\n" "$C_YLW" "$C_RESET" "$*"; }
err() { printf "%s[err]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
die() { err "$*"; exit 1; }

# ---------- Checagens iniciais ----------
need_bin() { command -v "$1" >/dev/null 2>&1 || die "comando requerido não encontrado: $1"; }

# fetcher auto
fetch_file() {
    url=$1 out=$2
    case "$ZERO_FETCH_CMD" in
        curl) need_bin curl; curl -L --fail --proto =https -o "$out" "$url" || return 1 ;;
        wget) need_bin wget; wget -O "$out" "$url" || return 1 ;;
        auto|*) if command -v curl >/dev/null 2>&1; then
                    ZERO_FETCH_CMD=curl; fetch_file "$url" "$out"
                elif command -v wget >/dev/null 2>&1; then
                    ZERO_FETCH_CMD=wget; fetch_file "$url" "$out"
                else
                    die "precisa de curl ou wget para baixar: $url"
                fi ;;
    esac
}

# ---------- Caminhos, busca de pacote ----------
# percorre ZERO_PATH (sep por :) e retorna caminho do pacote
pkg_path() {
    _name=$1
    OLDIFS=$IFS; IFS=:
    for repo in $ZERO_PATH; do
        [ -d "$repo/$_name" ] && { IFS=$OLDIFS; printf %s "$repo/$_name"; return 0; }
    done
    IFS=$OLDIFS
    return 1
}

ensure_dirs() {
    mkdir -p "$ZERO_DB" || die "falha mkdir $ZERO_DB"
    mkdir -p "$ZERO_CACHE" || die "falha mkdir $ZERO_CACHE"
}
ensure_dirs

# ---------- Helpers de leitura ----------
read_lines() { # read_lines <file> → ecoa linhas não vazias/sem comentário
    _f=$1
    [ -f "$_f" ] || return 0
    awk 'NF && $1 !~ /^#/' "$_f"
}

# ---------- ELF/strip ----------
is_elf() { file -b "$1" 2>/dev/null | grep -q "ELF"; }
do_strip_tree() {
    [ "$ZERO_STRIP" = "yes" ] || { wrn "strip desabilitado (ZERO_STRIP=no)"; return 0; }
    if ! command -v strip >/dev/null 2>&1; then wrn "strip ausente, pulando"; return 0; fi
    root=$1
    msg "strip ELF em $root"
    find "$root" -type f -print | while IFS= read -r f; do
        if is_elf "$f"; then
            # tentar preservar depuração mínima
            strip -s "$f" 2>/dev/null || strip "$f" 2>/dev/null || true
        fi
    done
    ok "strip concluído"
}
# ---------- Fetch, checksum, extract, patch ----------
fetch_sources() {
    pkg=$1; path=$2; cache="$ZERO_CACHE/$pkg/sources"
    mkdir -p "$cache" || die "mkdir $cache"
    msg "baixando/copiano sources de $pkg"
    read_lines "$path/sources" | while IFS= read -r src; do
        case "$src" in
            http://*|https://*)
                out="$cache/$(basename "$src")"
                msg "baixa: $src"
                fetch_file "$src" "$out" || die "falha ao baixar $src"
                ;;
            *)
                [ -f "$path/$src" ] || die "arquivo local não existe: $path/$src"
                msg "copia: $src"
                cp -f "$path/$src" "$cache/" || die "falha copiar $src"
                ;;
        esac
    done
    ok "sources prontos em $cache"
}

verify_checksums() {
    pkg=$1; path=$(pkg_path "$pkg") || die "sem path"
    cache="$ZERO_CACHE/$pkg/sources"
    [ -f "$path/checksums" ] || die "faltando checksums em $pkg"
    msg "verificando checksums de $pkg"
    # checksums: "sha256  filename"
    ( cd "$cache" || exit 1
      while IFS= read -r sum file; do
          [ -z "$sum" ] && continue
          printf "%s  %s\n" "$sum" "$file" | sha256sum -c - || exit 2
      done < "$path/checksums"
    ) || die "checksum inválido"
    ok "checksums válidos"
}

extract_and_patch() {
    pkg=$1
    path=$(pkg_path "$pkg") || die "sem path"
    cache="$ZERO_CACHE/$pkg/sources"
    buildsrc="$ZERO_CACHE/$pkg/buildsrc"
    rm -rf "$buildsrc" && mkdir -p "$buildsrc" || die "prep buildsrc"

    msg "extraindo tarballs de $pkg"
    for f in "$cache"/*; do
        case "$f" in
            *.tar.gz|*.tgz) tar -xzf "$f" -C "$buildsrc" || die "tar $f" ;;
            *.tar.xz)       tar -xJf "$f" -C "$buildsrc" || die "tar $f" ;;
            *.tar.bz2)      tar -xjf "$f" -C "$buildsrc" || die "tar $f" ;;
            *) : ;;
        esac
    done

    # diretório raiz do source (primeiro nível)
    srcdir=$(find "$buildsrc" -mindepth 1 -maxdepth 1 -type d | head -n1)
    [ -n "$srcdir" ] || die "não foi possível detectar diretório do source"

    msg "aplicando patches (ordem de sources)"
    read_lines "$path/sources" | while IFS= read -r src; do
        case "$src" in
            *.patch|*.diff)
                pfile="$cache/$(basename "$src")"
                [ -f "$pfile" ] || die "patch ausente: $pfile"
                ( cd "$srcdir" && patch -p1 < "$pfile" ) || die "falha patch $pfile"
                ok "patch aplicado: $(basename "$pfile")"
                ;;
        esac
    done

    printf %s "$srcdir"
}

# ---------- Build (um pacote) ----------
build_one() {
    pkg=$1
    path=$(pkg_path "$pkg") || die "pacote $pkg não encontrado em ZERO_PATH"
    msg "build de $pkg"

    fetch_sources "$pkg" "$path"
    verify_checksums "$pkg"
    srcdir=$(extract_and_patch "$pkg") || exit 1

    DESTDIR="$ZERO_CACHE/$pkg/pkgdir"
    rm -rf "$DESTDIR" && mkdir -p "$DESTDIR" || die "prep DESTDIR"

    # executa script build do pacote com $1 = DESTDIR
    [ -x "$path/build" ] || chmod +x "$path/build" 2>/dev/null || true
    ( cd "$srcdir" && sh "$path/build" "$DESTDIR" ) || die "build falhou ($pkg)"

    do_strip_tree "$DESTDIR"

    # empacotar
    ( cd "$DESTDIR" && tar -czf "$ZERO_CACHE/$pkg.tar.gz" . ) || die "empacotar falhou"
    ok "pacote pronto: $ZERO_CACHE/$pkg.tar.gz"
}
# ---------- Dependências ----------
# Lê depends de um pacote (uma por linha)
pkg_depends() {
    _p=$1; _path=$(pkg_path "$_p") || return 1
    read_lines "$_path/depends"
}

# Resolve dependências recursivamente e retorna ordem topológica
# detecta ciclo e aborta
dep_resolve() {
    # uso: dep_resolve <pkg>  → ecoa lista na ordem correta
    target=$1
    VISITED_TMP="$(mktemp -t zero.visited.XXXXXX)" || exit 1
    STACK_TMP="$(mktemp -t zero.stack.XXXXXX)" || exit 1
    ORDER_TMP="$(mktemp -t zero.order.XXXXXX)" || exit 1

    touch "$VISITED_TMP" "$STACK_TMP" "$ORDER_TMP"

    _dfs() {
        node=$1
        echo "$node" | grep -qxF "$(cat "$VISITED_TMP")" 2>/dev/null && return 0
        echo "$node" >>"$VISITED_TMP"
        echo "$node" >>"$STACK_TMP"

        for d in $(pkg_depends "$node"); do
            [ -z "$d" ] && continue
            # se não existe pacote, erro
            pkg_path "$d" >/dev/null 2>&1 || die "dependência ausente: $d (requerida por $node)"
            # ciclo?
            if grep -qxF "$d" "$STACK_TMP"; then
                die "ciclo de dependências detectado: $node -> $d"
            fi
            # já visitado?
            if ! grep -qxF "$d" "$VISITED_TMP"; then
                _dfs "$d"
            fi
        done

        # pop stack e adiciona na ordem
        # remove última ocorrência de $node do STACK_TMP
        tmp="$(mktemp)"
        grep -vxF "$node" "$STACK_TMP" > "$tmp" && mv "$tmp" "$STACK_TMP"
        echo "$node" >>"$ORDER_TMP"
    }

    _dfs "$target"

    cat "$ORDER_TMP" | awk '!seen[$0]++'

    rm -f "$VISITED_TMP" "$STACK_TMP" "$ORDER_TMP"
}

# ---------- Install ----------
install_one() {
    pkg=$1
    tarball="$ZERO_CACHE/$pkg.tar.gz"
    [ -f "$tarball" ] || die "tarball não encontrado: $tarball (rode zero build $pkg)"
    msg "instalando $pkg"
    mkdir -p "$ZERO_DB/$pkg" || die "mkdir db $pkg"
    # extrair e capturar manifest
    TMPROOT="$(mktemp -d -t zero.root.XXXXXX)" || exit 1
    tar -xzf "$tarball" -C / || { rm -rf "$TMPROOT"; die "falha ao extrair no /"; }

    # gerar manifest a partir do tarball (conteúdo, com path relativo)
    tar -tzf "$tarball" > "$ZERO_DB/$pkg/manifest" || die "manifest falhou"
    path=$(pkg_path "$pkg") || die "path pkg"
    cp -f "$path/version" "$ZERO_DB/$pkg/version" 2>/dev/null || printf "0\n" > "$ZERO_DB/$pkg/version"
    cp -f "$path/depends" "$ZERO_DB/$pkg/depends" 2>/dev/null || : 
    ok "$pkg instalado"
}

install_with_deps() {
    pkg=$1
    msg "resolvendo dependências de $pkg"
    order=$(dep_resolve "$pkg") || exit 1
    msg "ordem de build/install: $order"
    for p in $order; do
        [ -f "$ZERO_CACHE/$p.tar.gz" ] || build_one "$p"
        install_one "$p"
    done
}

# ---------- Remove ----------
remove_one() {
    pkg=$1
    msg "removendo $pkg"
    [ -d "$ZERO_DB/$pkg" ] || die "$pkg não está instalado"
    # checar reverse deps que dependem de $pkg
    rdeps=$(reverse_deps "$pkg")
    if [ -n "$rdeps" ]; then
        wrn "removendo $pkg, mas estes pacotes dependem dele:"
        printf "  %s\n" $rdeps
    fi
    manifest="$ZERO_DB/$pkg/manifest"
    [ -f "$manifest" ] || die "manifest ausente de $pkg"
    # remover arquivos listados
    # (remover diretórios vazios depois)
    tac "$manifest" 2>/dev/null | while IFS= read -r f; do
        rm -f "/$f" 2>/dev/null || true
    done
    # limpar diretórios vazios de /usr, /etc, etc? (opcional)
    rm -rf "$ZERO_DB/$pkg"
    ok "$pkg removido"
}

# ---------- List/Search ----------
cmd_list() {
    msg "pacotes instalados em $ZERO_DB"
    ls -1 "$ZERO_DB" 2>/dev/null || true
}
cmd_search() {
    needle=$1
    [ -n "$needle" ] || die "uso: zero search <nome>"
    msg "procurando $needle em ZERO_PATH"
    OLDIFS=$IFS; IFS=:
    for repo in $ZERO_PATH; do
        for p in "$repo"/*; do
            [ -d "$p" ] || continue
            base=$(basename "$p")
            printf "%s\n" "$base" | grep -q "$needle" && printf "%s/%s\n" "$repo" "$base"
        done
    done
    IFS=$OLDIFS
}

# ---------- Reverse deps (quem depende de X) ----------
reverse_deps() {
    target=$1
    [ -d "$ZERO_DB" ] || return 0
    for p in "$ZERO_DB"/*; do
        [ -d "$p" ] || continue
        base=$(basename "$p")
        grep -qxF "$target" "$p/depends" 2>/dev/null && printf "%s " "$base"
    done
}

cmd_revdep() {
    # Modo 1: lista reverse deps de um pacote (leitura de depends instalados)
    # Modo 2: verificação de libs ausentes (revdep-rebuild simples)
    case "$1" in
        list)
            [ -n "$2" ] || die "uso: zero revdep list <pkg>"
            r=$(reverse_deps "$2")
            [ -n "$r" ] && { msg "reverse deps de $2:"; printf "%s\n" "$r"; } || ok "sem reverse deps"
            ;;
        check)
            need_bin ldd
            msg "checando bins/libs quebrados (ldd not found)"
            # Varre todos os manifestos, testa arquivos ELF
            broken=""
            for d in "$ZERO_DB"/*; do
                [ -d "$d" ] || continue
                while IFS= read -r f; do
                    abs="/$f"
                    [ -f "$abs" ] || continue
                    if is_elf "$abs"; then
                        if ldd "$abs" 2>/dev/null | grep -q "not found"; then
                            broken="$broken\n$abs"
                        fi
                    fi
                done < "$d/manifest"
            done
            if [ -n "$broken" ]; then
                err "arquivos ELF com dependências ausentes:"
                printf "%b\n" "$broken"
                exit 1
            else
                ok "nenhum ELF quebrado encontrado"
            fi
            ;;
        *)
            die "uso: zero revdep {list <pkg>|check}"
            ;;
    esac
}
# ---------- Comando checksums (gerar/atualizar) ----------
cmd_checksum() {
    pkg=$1
    [ -n "$pkg" ] || die "uso: zero checksum <pkg>"
    path=$(pkg_path "$pkg") || die "pacote não encontrado"
    cache="$ZERO_CACHE/$pkg/sources"
    mkdir -p "$cache" || die "mkcache"
    msg "preparando sources para calcular checksums de $pkg"
    # baixar/copiar para garantir presença local
    fetch_sources "$pkg" "$path"
    # gerar checksums (sha256) na ordem de sources
    out="$path/checksums"
    : > "$out"
    read_lines "$path/sources" | while IFS= read -r src; do
        f="$cache/$(basename "$src")"
        [ -f "$f" ] || die "source ausente p/ checksum: $f"
        s=$(sha256sum "$f" | awk '{print $1}')
        printf "%s  %s\n" "$s" "$(basename "$f")" >> "$out"
    done
    ok "checksums atualizados em $out"
}

# ---------- Comandos públicos ----------
cmd_build()   { [ -n "$1" ] || die "uso: zero build <pkg>"; build_one "$1"; }
cmd_install() { [ -n "$1" ] || die "uso: zero install <pkg>"; install_with_deps "$1"; }
cmd_remove()  { [ -n "$1" ] || die "uso: zero remove <pkg>"; remove_one "$1"; }
cmd_depgraph(){ [ -n "$1" ] || die "uso: zero depgraph <pkg>"; dep_resolve "$1"; }

# ---------- Ajuda ----------
usage() {
cat <<EOF
${C_BOLD}zero${C_RESET} - gerenciador de pacotes estilo KISS

Uso:
  zero search <nome>           # procurar pacote(s) em ZERO_PATH
  zero list                    # listar instalados
  zero checksum <pkg>          # gerar/atualizar checksums do pacote
  zero build <pkg>             # build (fetch+checksum+patch+empacota)
  zero install <pkg>           # resolver deps e instalar em ordem
  zero remove <pkg>            # remover pacote
  zero depgraph <pkg>          # imprimir ordem de deps (topológica)
  zero revdep list <pkg>       # quem depende de <pkg>
  zero revdep check            # checar ELF quebrados (ldd "not found")

Ambiente:
  ZERO_PATH   (padrão: $HOME/repos)              # repositórios (sep por :)
  ZERO_DB     (padrão: /var/db/zero/installed)   # banco de instalados
  ZERO_CACHE  (padrão: /var/cache/zero)          # cache de builds
  ZERO_STRIP  (yes|no, padrão yes)               # strip de ELF pós-build
  ZERO_FETCH_CMD (auto|curl|wget, padrão auto)

Notas:
- Patches devem ficar no mesmo diretório do pacote e ser listados em 'sources'.
- O script 'build' do pacote recebe ${C_BOLD}\$1${C_RESET} = DESTDIR.
- 'depends' tem um nome de pacote por linha; deps recursivas são resolvidas.
EOF
}

# ---------- Router ----------
cmd=$1; shift 2>/dev/null || true
case "$cmd" in
    search)   cmd_search "$@" ;;
    list)     cmd_list ;;
    checksum) cmd_checksum "$@" ;;
    build)    cmd_build "$@" ;;
    install)  cmd_install "$@" ;;
    remove)   cmd_remove "$@" ;;
    depgraph) cmd_depgraph "$@" ;;
    revdep)   cmd_revdep "$@" ;;
    ""|help|-h|--help) usage ;;
    *) die "comando desconhecido: $cmd (use 'zero help')" ;;
esac
