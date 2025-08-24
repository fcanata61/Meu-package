
## 📦 Gerenciador de Pacotes `zero`

## ✅ Funcionalidades Implementadas

### Build / Instalação

* [x] **Fetch** automático (curl/wget com fallback)
* [x] **Checksum** SHA-256 (gera e valida)
* [x] **Patch** aplicado em ordem definida no arquivo `sources`
* [x] **Strip** automático de ELF (opcional, via `ZERO_STRIP`)
* [x] **Empacotamento** em `.tar.gz` com manifesto e metadados
* [x] **Instalação** com checagem de conflitos e suporte a `--force`

### Dependências

* [x] **Resolução recursiva de dependências** (ordem topológica, com detecção de ciclos)
* [x] **Reverse deps** (quem depende de quem)
* [x] **Revdep fix**: rebuild automático de dependentes diretos após upgrade
* [x] **Revdep check**: detecção de ELF quebrado via `ldd "not found"`
* [x] **Revdep conflicts**: verificação de conflitos antes da instalação

### Gestão do Sistema

* [x] **Remove** seguro (checa reverse deps; `--force` ignora)
* [x] **Update**: rebuild/reinstall mantendo mesma versão
* [x] **Upgrade**: instala apenas se houver versão maior (`sort -V`)
* [x] **World**: rebuild completo do sistema em ordem de dependências
* [x] **Sync**: `git pull --ff-only` em todos os repositórios do `ZERO_PATH`
* [x] **Clean**: limpeza de cache por pacote ou total

### Qualidade de Vida

* [x] **Mensagens coloridas** (`info`, `ok`, `warn`, `err`)
* [x] **Configuração via variáveis de ambiente** (`ZERO_PATH`, `ZERO_DB`, `ZERO_CACHE`, `ZERO_STRIP`, `ZERO_FETCH_CMD`)
* [x] **Utilitários**: `list`, `search`, `version`, `depgraph`

---

## 🚧 Planejado / Ideias Futuras

### Funcionalidades Avançadas

* [ ] **Hooks** de build/instalação (pré/pós build, pré/pós install)
* [ ] **Cache binário** (instalar direto de binários já empacotados)
* [ ] **Rollback** (desinstalar e restaurar versão anterior)
* [ ] **Suporte a múltiplos formatos** de pacote além de `.tar.gz`
* [ ] **Gestão de logs** (guardar histórico de builds, installs e removals)
* [ ] **Integração com containers/chroot** para builds isolados
* [ ] **Verificação de assinaturas GPG** nos sources

### Experiência do Usuário

* [ ] **Autocompletar de comandos** para shell
* [ ] **Interface TUI** opcional para busca e gestão
* [ ] **Documentação expandida** com exemplos práticos

### Manutenção / Infraestrutura

* [ ] **Testes automatizados** (CI) para validar comandos principais
* [ ] **Releases versionadas** (`v0.x`, `v1.0`, ...)
* [ ] **Roadmap público** mantido no repositório

---

📌 Este roadmap é iterativo — novas ideias podem ser adicionadas conforme a evolução do `zero` e feedback de usuários.
