#!/bin/sh
# zero — gerenciador de pacotes estilo KISS (POSIX sh)
# Recursos: fetch, checksum, patch, strip, deps recursivas (c/ ciclo),
# revdep evoluído (detecção + --fix), remove integrado ao revdep,
# world (rebuild de todo o sistema), sync (git), upgrade (versão maior),
# clean, update, mensagens coloridas.

# ---------- Variáveis (podem ser sobrescritas via ambiente) ----------
: "${ZERO_PATH:=$HOME/repos}"            # Repositórios (separe por :)
: "${ZERO_DB:=/var/db/zero/installed}"   # Banco de pacotes instalados
: "${ZERO_CACHE:=/var/cache/zero}"       # Cache (sources, buildsrc, pkgdir, .tar.gz)
: "${ZERO_STRIP:=yes}"                   # yes/no para strip de ELF
: "${ZERO_FETCH_CMD:=auto}"              # auto|curl|wget
: "${ZERO_VERSION:=0.3}"                 # versão do gerenciador
umask 022

# ---------- Cores ----------
if [ -t 1 ]; then
    ESC=$(printf '\033')
    C_RESET="${ESC}[0m"; C_BOLD="${ESC}[1m"
    C_RED="${ESC}[31m"; C_GRN="${ESC}[32m"; C_YLW="${ESC}[33m"
    C_BLU="${ESC}[34m"; C_MAG="${ESC}[35m"; C_CYN="${ESC}[36m"
else
    C_RESET=; C_BOLD=; C_RED=; C_GRN=; C_YLW=; C_BLU=; C_MAG=; C_CYN=
fi

info(){ printf "%s==>%s %s\n" "$C_BOLD$C_CYN" "$C_RESET" "$*"; }
ok(){   printf "%s[ok]%s %s\n" "$C_GRN" "$C_RESET" "$*"; }
warn(){ printf "%s[warn]%s %s\n" "$C_YLW" "$C_RESET" "$*"; }
err(){  printf "%s[err]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
die(){  err "$*"; exit 1; }

need_bin(){ command -v "$1" >/dev/null 2>&1 || die "comando requerido não encontrado: $1"; }

# ---------- Pastas essenciais ----------
ensure_dirs(){ mkdir -p "$ZERO_DB" "$ZERO_CACHE" || die "falha ao criar diretórios"; }
ensure_dirs

# ---------- Leitura de linhas (ignora vazias e comentários) ----------
read_lines(){ [ -f "$1" ] || return 0; awk 'NF && $1 !~ /^#/' "$1"; }

# ---------- Caminho do pacote em ZERO_PATH ----------
pkg_path(){
    _name=$1
    OLDIFS=$IFS; IFS=:
    for repo in $ZERO_PATH; do
        [ -d "$repo/$_name" ] && { IFS=$OLDIFS; printf %s "$repo/$_name"; return 0; }
    done
    IFS=$OLDIFS
    return 1
}

# ---------- Download ----------
fetch_file(){
    url=$1 out=$2
    case "$ZERO_FETCH_CMD" in
        curl) need_bin curl; curl -L --fail --proto =https -o "$out" "$url" || return 1 ;;
        wget) need_bin wget; wget -O "$out" "$url" || return 1 ;;
        auto|*) if command -v curl >/dev/null 2>&1; then ZERO_FETCH_CMD=curl; fetch_file "$url" "$out"
                elif command -v wget >/dev/null 2>&1; then ZERO_FETCH_CMD=wget; fetch_file "$url" "$out"
                else die "precisa de curl ou wget para baixar: $url"; fi ;;
    esac
}

# ---------- ELF e strip ----------
is_elf(){ file -b "$1" 2>/dev/null | grep -q "ELF"; }
do_strip_tree(){
    [ "$ZERO_STRIP" = "yes" ] || { warn "strip desabilitado (ZERO_STRIP=no)"; return 0; }
    command -v strip >/dev/null 2>&1 || { warn "strip ausente, pulando"; return 0; }
    root=$1
    info "strip ELF em $root"
    find "$root" -type f -print | while IFS= read -r f; do
        if is_elf "$f"; then
            strip -s "$f" 2>/dev/null || strip "$f" 2>/dev/null || true
        fi
    done
    ok "strip concluído"
}

# ---------- Flags globais (ex.: --force) ----------
FORCE=no
GLOBAL_ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=yes; shift ;;
        --) shift; break ;;
        -*)
            GLOBAL_ARGS="$GLOBAL_ARGS $1"; shift ;;
        *) break ;;
    esac
done
CMD=$1; shift 2>/dev/null || true
# ---------- Fetch, checksum ----------
fetch_sources(){
    pkg=$1; path=$2; cache="$ZERO_CACHE/$pkg/sources"
    mkdir -p "$cache" || die "mkdir $cache"
    info "baixando/copiano sources de $pkg"
    read_lines "$path/sources" | while IFS= read -r src; do
        case "$src" in
            http://*|https://*)
                out="$cache/$(basename "$src")"
                info "baixa $src"
                fetch_file "$src" "$out" || die "falha ao baixar $src" ;;
            *)
                [ -f "$path/$src" ] || die "arquivo local não existe: $path/$src"
                info "copia $src"
                cp -f "$path/$src" "$cache/" || die "falha copiar $src" ;;
        esac
    done
    ok "sources prontos em $cache"
}

verify_checksums(){
    pkg=$1; path=$(pkg_path "$pkg") || die "sem path"
    cache="$ZERO_CACHE/$pkg/sources"
    [ -f "$path/checksums" ] || die "faltando checksums em $pkg"
    info "verificando checksums de $pkg"
    ( cd "$cache" || exit 1
      while IFS= read -r sum file; do
          [ -z "$sum" ] && continue
          printf "%s  %s\n" "$sum" "$file" | sha256sum -c - || exit 2
      done < "$path/checksums"
    ) || die "checksum inválido"
    ok "checksums válidos"
}

# ---------- Extract + Patch ----------
extract_and_patch(){
    pkg=$1
    path=$(pkg_path "$pkg") || die "sem path"
    cache="$ZERO_CACHE/$pkg/sources"
    buildsrc="$ZERO_CACHE/$pkg/buildsrc"
    rm -rf "$buildsrc" && mkdir -p "$buildsrc" || die "prep buildsrc"

    info "extraindo tarballs de $pkg"
    for f in "$cache"/*; do
        case "$f" in
            *.tar.gz|*.tgz) tar -xzf "$f" -C "$buildsrc" || die "tar $f" ;;
            *.tar.xz)       tar -xJf "$f" -C "$buildsrc" || die "tar $f" ;;
            *.tar.bz2)      tar -xjf "$f" -C "$buildsrc" || die "tar $f" ;;
            *) : ;;
        esac
    done

    srcdir=$(find "$buildsrc" -mindepth 1 -maxdepth 1 -type d | head -n1)
    [ -n "$srcdir" ] || die "não foi possível detectar diretório do source"

    info "aplicando patches (ordem do arquivo sources)"
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

# ---------- Build de um pacote ----------
build_one(){
    pkg=$1
    path=$(pkg_path "$pkg") || die "pacote $pkg não encontrado em ZERO_PATH"
    info "build de $pkg"

    fetch_sources "$pkg" "$path"
    verify_checksums "$pkg"
    srcdir=$(extract_and_patch "$pkg") || exit 1

    DESTDIR="$ZERO_CACHE/$pkg/pkgdir"
    rm -rf "$DESTDIR" && mkdir -p "$DESTDIR" || die "prep DESTDIR"

    [ -x "$path/build" ] || chmod +x "$path/build" 2>/dev/null || true
    ( cd "$srcdir" && sh "$path/build" "$DESTDIR" ) || die "build falhou ($pkg)"

    do_strip_tree "$DESTDIR"

    ( cd "$DESTDIR" && tar -czf "$ZERO_CACHE/$pkg.tar.gz" . ) || die "empacotar falhou"
    ok "pacote pronto: $ZERO_CACHE/$pkg.tar.gz"
}

# ---------- Manifesto e metadados ----------
write_meta_from_tar(){
    pkg=$1; tarball="$ZERO_CACHE/$pkg.tar.gz"
    mkdir -p "$ZERO_DB/$pkg" || die "mkdir db $pkg"
    tar -tzf "$tarball" > "$ZERO_DB/$pkg/manifest" || die "manifest falhou"
    path=$(pkg_path "$pkg") || die "path pkg"
    cp -f "$path/version" "$ZERO_DB/$pkg/version" 2>/dev/null || printf "0\n" > "$ZERO_DB/$pkg/version"
    cp -f "$path/depends" "$ZERO_DB/$pkg/depends" 2>/dev/null || :
}
# ---------- Conflitos de arquivos (tarball vs sistema instalado) ----------
tar_conflicts(){
    pkg=$1; tarball="$ZERO_CACHE/$pkg.tar.gz"
    [ -f "$tarball" ] || die "tarball não encontrado: $tarball"
    conflicts=""
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if [ -e "/$f" ]; then
            owner=""
            for d in "$ZERO_DB"/*; do
                [ -d "$d" ] || continue
                if grep -qxF "$f" "$d/manifest" 2>/dev/null; then
                    base=$(basename "$d"); owner="$base"; break
                fi
            done
            if [ -n "$owner" ] && [ "$owner" != "$pkg" ]; then
                conflicts="$conflicts\n/$f  (pertence a: $owner)"
            fi
        fi
    done <<EOF
$(tar -tzf "$tarball")
EOF
    [ -n "$conflicts" ] && printf "%b" "$conflicts" || return 0
}

# ---------- Instalar ----------
install_one(){
    pkg=$1
    tarball="$ZERO_CACHE/$pkg.tar.gz"
    [ -f "$tarball" ] || die "tarball não encontrado: $tarball (rode zero build $pkg)"
    c=$(tar_conflicts "$pkg")
    if [ -n "$c" ] && [ "$FORCE" != "yes" ]; then
        err "conflitos de arquivos detectados ao instalar $pkg:"
        printf "%b\n" "$c"
        die "use --force para sobrescrever"
    fi
    info "instalando $pkg"
    tar -xzf "$tarball" -C / || die "falha ao extrair no /"
    write_meta_from_tar "$pkg"
    ok "$pkg instalado"
}

# ---------- Reverse deps (leitura simples do banco) ----------
reverse_deps(){
    target=$1
    [ -d "$ZERO_DB" ] || return 0
    for p in "$ZERO_DB"/*; do
        [ -d "$p" ] || continue
        base=$(basename "$p")
        grep -qxF "$target" "$p/depends" 2>/dev/null && printf "%s " "$base"
    done
}

# ---------- Remover (revdep integrado) ----------
remove_one(){
    pkg=$1
    [ -d "$ZERO_DB/$pkg" ] || die "$pkg não está instalado"
    rdeps=$(reverse_deps "$pkg")
    if [ -n "$rdeps" ] && [ "$FORCE" != "yes" ]; then
        err "não é seguro remover $pkg; usado por: $rdeps"
        die "use --force para remover mesmo assim"
    fi
    info "removendo $pkg"
    manifest="$ZERO_DB/$pkg/manifest"
    [ -f "$manifest" ] || die "manifest ausente de $pkg"
    tac "$manifest" 2>/dev/null | while IFS= read -r f; do rm -f "/$f" 2>/dev/null || true; done
    rm -rf "$ZERO_DB/$pkg"
    ok "$pkg removido"
}

# ---------- Dependências ----------
pkg_depends(){ _p=$1; _path=$(pkg_path "$_p") || return 1; read_lines "$_path/depends"; }

dep_resolve(){ # imprime ordem topológica (deps antes do alvo), detecta ciclo
    target=$1
    VIS="$(mktemp -t zero.vis.XXXXXX)" || exit 1
    STK="$(mktemp -t zero.stk.XXXXXX)" || exit 1
    ORD="$(mktemp -t zero.ord.XXXXXX)" || exit 1
    touch "$VIS" "$STK" "$ORD"
    _dfs(){ n=$1
        grep -qxF "$n" "$VIS" 2>/dev/null && return 0
        echo "$n" >>"$VIS"; echo "$n" >>"$STK"
        for d in $(pkg_depends "$n"); do
            [ -z "$d" ] && continue
            pkg_path "$d" >/dev/null 2>&1 || die "dependência ausente: $d (requerida por $n)"
            if grep -qxF "$d" "$STK"; then die "ciclo de dependências: $n -> $d"; fi
            grep -qxF "$d" "$VIS" || _dfs "$d"
        done
        tmp="$(mktemp)"; grep -vxF "$n" "$STK" > "$tmp"; mv "$tmp" "$STK"
        echo "$n" >>"$ORD"
    }
    _dfs "$target"
    awk '!seen[$0]++' "$ORD"
    rm -f "$VIS" "$STK" "$ORD"
}

# ---------- Build/Install com dependências ----------
build_with_deps(){
    pkg=$1
    info "resolvendo dependências de build para $pkg"
    order=$(dep_resolve "$pkg") || exit 1
    info "ordem de build: $order"
    for p in $order; do
        if [ -f "$ZERO_CACHE/$p.tar.gz" ] && [ "$FORCE" != "yes" ]; then
            ok "cache presente: $p"
        else
            build_one "$p"
        fi
    done
}

install_with_deps(){
    pkg=$1
    info "resolvendo dependências de instalação para $pkg"
    order=$(dep_resolve "$pkg") || exit 1
    info "ordem de instalação: $order"
    for p in $order; do
        [ -f "$ZERO_CACHE/$p.tar.gz" ] || build_one "$p"
        install_one "$p"
    done
}
# ---------- checksum (gerar/atualizar) ----------
cmd_checksum(){
    pkg=$1; [ -n "$pkg" ] || die "uso: zero checksum <pkg>"
    path=$(pkg_path "$pkg") || die "pacote não encontrado"
    cache="$ZERO_CACHE/$pkg/sources"; mkdir -p "$cache" || die "mkcache"
    info "preparando sources para checksums de $pkg"
    fetch_sources "$pkg" "$path"
    out="$path/checksums"; : > "$out"
    read_lines "$path/sources" | while IFS= read -r src; do
        f="$cache/$(basename "$src")"; [ -f "$f" ] || die "source ausente p/ checksum: $f"
        s=$(sha256sum "$f" | awk '{print $1}'); printf "%s  %s\n" "$s" "$(basename "$f")" >> "$out"
    done
    ok "checksums atualizados em $out"
}

# ---------- list/search/clean/version ----------
cmd_list(){
    info "instalados em $ZERO_DB"
    for d in "$ZERO_DB"/*; do
        [ -d "$d" ] || continue
        p=$(basename "$d"); v=$(cat "$d/version" 2>/dev/null || printf "0")
        printf "%s %s\n" "$p" "$v"
    done
}

cmd_search(){
    needle=$1; [ -n "$needle" ] || die "uso: zero search <nome>"
    info "procurando '$needle' em ZERO_PATH"
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

cmd_clean(){
    what=$1
    case "$what" in
        all|"") info "limpando cache $ZERO_CACHE"; rm -rf "$ZERO_CACHE"/* 2>/dev/null || true; ok "cache limpo" ;;
        *) info "limpando cache de $what"; rm -rf "$ZERO_CACHE/$what" "$ZERO_CACHE/$what.tar.gz" 2>/dev/null || true; ok "limpo $what" ;;
    esac
}

cmd_version(){ printf "zero %s\n" "$ZERO_VERSION"; }

# ---------- revdep evoluído ----------
# Usos:
#   zero revdep list <pkg>
#   zero revdep check
#   zero revdep conflicts <pkg>
#   zero revdep fix <pkg>     (equivalente a revdep --fix)
cmd_revdep(){
    sub=$1
    case "$sub" in
        list)
            p=$2; [ -n "$p" ] || die "uso: zero revdep list <pkg>"
            r=$(reverse_deps "$p")
            if [ -n "$r" ]; then info "reverse deps de $p:"; printf "%s\n" "$r"; else ok "sem reverse deps"; fi
            ;;
        check)
            need_bin ldd
            info "checando bins/libs quebrados (ldd 'not found')"
            broken=""
            for d in "$ZERO_DB"/*; do
                [ -d "$d" ] || continue
                while IFS= read -r f; do
                    abs="/$f"; [ -f "$abs" ] || continue
                    if is_elf "$abs"; then
                        if ldd "$abs" 2>/dev/null | grep -q "not found"; then
                            broken="$broken\n$abs"
                        fi
                    fi
                done < "$d/manifest"
            done
            if [ -n "$broken" ]; then err "ELFs com libs ausentes:"; printf "%b\n" "$broken"; exit 1; else ok "nenhum ELF quebrado"; fi
            ;;
        conflicts)
            p=$2; [ -n "$p" ] || die "uso: zero revdep conflicts <pkg>"
            t="$ZERO_CACHE/$p.tar.gz"; [ -f "$t" ] || die "tarball ausente (rode zero build $p)"
            c=$(tar_conflicts "$p")
            if [ -n "$c" ]; then err "conflitos ao instalar $p:"; printf "%b\n" "$c"; exit 1; else ok "sem conflitos detectados"; fi
            ;;
        fix)
            p=$2; [ -n "$p" ] || die "uso: zero revdep fix <pkg>"
            info "corrigindo dependentes de $p (rebuild automático)"
            # 1) listar dependentes diretos
            r=$(reverse_deps "$p")
            [ -n "$r" ] || { ok "nenhum dependente para corrigir"; return 0; }
            # 2) para cada dependente, rebuild + reinstall (em ordem de deps)
            for dep in $r; do
                info "rebuild dependente: $dep"
                build_with_deps "$dep"
                install_with_deps "$dep"
            done
            ok "revdep fix concluído"
            ;;
        *) die "uso: zero revdep {list <pkg>|check|conflicts <pkg>|fix <pkg>}" ;;
    esac
}
# ---------- update (rebuild mantendo versão) ----------
cmd_update(){
    pkg=$1; [ -n "$pkg" ] || die "uso: zero update <pkg>"
    build_with_deps "$pkg"
    install_with_deps "$pkg"
}

# ---------- sync (git pull em todos os repositórios) ----------
cmd_sync(){
    info "sincronizando repositórios em ZERO_PATH"
    OLDIFS=$IFS; IFS=:
    for repo in $ZERO_PATH; do
        if [ -d "$repo/.git" ]; then
            info "git pull: $repo"
            git -C "$repo" pull --ff-only || die "git pull falhou em $repo"
        else
            warn "não é repositório git: $repo"
        fi
    done
    IFS=$OLDIFS
    ok "sync concluído"
}

# ---------- upgrade (instalar apenas se houver versão maior) ----------
ver_of_pkg_in_repo(){ path=$(pkg_path "$1") || return 1; cat "$path/version" 2>/dev/null || printf "0"; }
ver_installed(){ cat "$ZERO_DB/$1/version" 2>/dev/null || printf "0"; }
ver_is_newer(){  # retorna 0 se v2 > v1 (usa sort -V)
    v1=$1; v2=$2
    newest=$(printf "%s\n%s\n" "$v1" "$v2" | sort -V | tail -n1)
    [ "$newest" = "$v2" ] && [ "$v1" != "$v2" ]
}

cmd_upgrade(){
    pkg=$1; [ -n "$pkg" ] || die "uso: zero upgrade <pkg>"
    v_local=$(ver_installed "$pkg")
    v_repo=$(ver_of_pkg_in_repo "$pkg") || die "pacote não encontrado no repo"
    if ver_is_newer "$v_local" "$v_repo"; then
        info "upgrade $pkg: $v_local -> $v_repo"
        build_with_deps "$pkg"
        # antes de instalar, tentar corrigir dependentes (se necessário)
        # (não obrigatório, mas útil se a ABI muda)
        cmd_revdep fix "$pkg"
        install_with_deps "$pkg"
    else
        ok "já na última versão ($v_local)"
    fi
}

# ---------- world (recompila/atualiza tudo na ordem de dependências) ----------
cmd_world(){
    info "reconstruindo mundo (todos instalados) respeitando dependências"
    pkgs=""
    for d in "$ZERO_DB"/*; do [ -d "$d" ] || continue; pkgs="$pkgs $(basename "$d")"; done
    [ -n "$pkgs" ] || { ok "nada instalado"; return 0; }

    order=""
    for p in $pkgs; do order="$order $(dep_resolve "$p")"; done
    order=$(printf "%s\n" $order | awk '!seen[$0]++')
    info "ordem de world:\n$order"

    for p in $order; do
        build_one "$p"
        install_one "$p"
    done

    cmd_revdep check || warn "há ELFs quebrados após world"
    ok "world concluído"
}
usage(){
cat <<EOF
${C_BOLD}zero${C_RESET} v$ZERO_VERSION — gerenciador de pacotes estilo KISS

Uso geral:
  zero [--force] <comando> [args]

Comandos:
  search <nome>           Procurar pacotes em ZERO_PATH
  list                    Listar pacotes instalados
  checksum <pkg>          Gerar/atualizar checksums de <pkg>
  build <pkg>             Build (resolve deps, patch, strip, empacota)
  install <pkg>           Instalar (resolve deps e instala em ordem)
  remove <pkg>            Remover pacote (checa reverse-deps; '--force' ignora)
  update <pkg>            Rebuild + reinstala <pkg> (mesma versão)
  upgrade <pkg>           Atualiza somente se houver versão maior no repo
  world                   Reconstruir/atualizar todos (ordem de deps)
  depgraph <pkg>          Imprime ordem topológica de <pkg> e suas deps
  revdep list <pkg>       Quem depende de <pkg>
  revdep conflicts <pkg>  Conflitos de arquivos do tarball com instalados
  revdep check            ELF quebrados (ldd "not found")
  revdep fix <pkg>        Corrige dependentes de <pkg> (rebuild automático)
  sync                    git pull em todos os repositórios do ZERO_PATH
  clean [pkg|all]         Limpa cache (de um pacote ou inteiro)
  version                 Versão do ZERO

Ambiente:
  ZERO_PATH   (padrão: $HOME/repos)              # repositórios (sep por :)
  ZERO_DB     (padrão: /var/db/zero/installed)   # banco de instalados
  ZERO_CACHE  (padrão: /var/cache/zero)          # cache de builds
  ZERO_STRIP  (yes|no, padrão yes)               # strip de ELF pós-build
  ZERO_FETCH_CMD (auto|curl|wget, padrão auto)

Notas:
- Patches ficam no diretório do pacote e devem constar em 'sources' (ordem aplicada).
- Script 'build' do pacote recebe \$1=DESTDIR (use 'make DESTDIR="\$1" install').
- 'depends' tem um nome de pacote por linha; dependências recursivas são resolvidas.
- '--force' permite ignorar reverse-deps e sobrescrever conflitos em remove/install/upgrade.
EOF
}

# ---------- Router ----------
case "$CMD" in
    search)    cmd_search "$@" ;;
    list)      cmd_list ;;
    checksum)  cmd_checksum "$@" ;;
    build)     build_with_deps "$@" ;;
    install)   install_with_deps "$@" ;;
    remove)    remove_one "$@" ;;
    update)    cmd_update "$@" ;;
    upgrade)   cmd_upgrade "$@" ;;
    world)     cmd_world "$@" ;;
    depgraph)  dep_resolve "$@" ;;
    revdep)    cmd_revdep "$@" ;;
    sync)      cmd_sync "$@" ;;
    clean)     cmd_clean "$@" ;;
    version)   cmd_version ;;
    ""|-h|--help|help) usage ;;
    *) die "comando desconhecido: $CMD (use 'zero help')" ;;
esac
