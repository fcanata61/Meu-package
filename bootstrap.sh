#!/bin/sh
# ====================================================
# ZERO bootstrap installer
# ====================================================

set -e

REPO_URL="https://seu-repo-git/zero.git"
PREFIX="/usr/local"
ZERO_BIN="$PREFIX/bin/zero"
ZERO_PATH="$PREFIX/zero/repos"
ZERO_DB="/var/db/zero"
ZERO_CACHE="/var/cache/zero"
ZERO_TMP="/var/tmp/zero"
PROFILE="/etc/profile.d/zero.sh"

msg() {
    printf "\033[1;32m[ZERO] \033[0m%s\n" "$1"
}

err() {
    printf "\033[1;31m[ERRO] \033[0m%s\n" "$1"
    exit 1
}

# ====================================================
# Criar estrutura de diretórios
# ====================================================
setup_dirs() {
    msg "Criando estrutura de diretórios..."
    sudo mkdir -p "$ZERO_DB" "$ZERO_CACHE" "$ZERO_TMP" "$ZERO_PATH"
    sudo chmod -R 755 "$ZERO_DB" "$ZERO_CACHE" "$ZERO_TMP" "$ZERO_PATH"
}

# ====================================================
# Clonar repositório principal
# ====================================================
clone_repo() {
    msg "Clonando repositório ZERO..."
    if [ -d "$ZERO_PATH/core" ]; then
        msg "Repositório já existe, atualizando..."
        (cd "$ZERO_PATH/core" && git pull)
    else
        git clone "$REPO_URL" "$ZERO_PATH/core"
    fi
}

# ====================================================
# Instalar binário principal
# ====================================================
install_bin() {
    msg "Instalando binário zero..."
    if [ ! -f "$ZERO_PATH/core/zero" ]; then
        err "Arquivo 'zero' não encontrado no repositório."
    fi
    sudo install -m 755 "$ZERO_PATH/core/zero" "$ZERO_BIN"
}

# ====================================================
# Instalar profile
# ====================================================
install_profile() {
    msg "Instalando profile do ZERO..."
    sudo mkdir -p /etc/profile.d
    cat <<EOF | sudo tee "$PROFILE" > /dev/null
# ====================================================
# ZERO package manager profile
# ====================================================
export ZERO_PATH="$ZERO_PATH"
export ZERO_DB="$ZERO_DB"
export ZERO_CACHE="$ZERO_CACHE"
export ZERO_TMP="$ZERO_TMP"
export ZERO_COLOR=1
# Repositório do git do zero,por ordem
export ZERO_REPOS="/usr/local/zero/repos/core:/usr/local/zero/repos/x11:/usr/local/zero/repos/desktop:/usr/local/zero/repos/extras"
# PATH: adiciona binários do ZERO
export PATH="$PREFIX/bin:\$PATH"
EOF
    sudo chmod 644 "$PROFILE"
    msg "Profile instalado em $PROFILE"
}

# ====================================================
# Help
# ====================================================
show_help() {
cat <<EOF
ZERO - Gerenciador de Pacotes

Comandos disponíveis:
    build <pkg> [--force]   → Compila pacotes
    install <pkg> [--force] → Instala pacotes
    remove <pkg> [--force]  → Remove pacotes
    list                    → Lista pacotes instalados
    search <pkg>            → Busca pacotes
    checksum <pkg>          → Verifica checksums
    update <pkg>            → Rebuild do pacote
    depends <pkg>           → Lista dependências
    revdep <pkg> [--fix]    → Lista/corrige dependências reversas
    strip <pkg>             → Remove símbolos de debug
    color                   → Coloriza mensagens
    clean <pkg|all>         → Limpa cache
    version                 → Mostra versão do ZERO
    world                   → Rebuild de todos pacotes
    sync                    → Sincroniza repositórios
    upgrade <pkg>           → Atualiza pacotes (versão nova)
Opções globais:
    --force                 → Força operação ignorando erros

Estrutura de diretórios:
    $ZERO_DB       → Banco de pacotes instalados
    $ZERO_CACHE    → Cache de pacotes compilados
    $ZERO_TMP      → Área temporária de build
    $ZERO_PATH     → Repositórios de pacotes
    $ZERO_BIN      → Binário principal
    $PROFILE       → Profile com variáveis do ZERO

EOF
}

# ====================================================
# Execução principal
# ====================================================
setup_dirs
clone_repo
install_bin
install_profile
msg "ZERO instalado com sucesso!"
msg "Reinicie o shell ou rode: source $PROFILE"
show_help
