# netbackup-instalador

Instalador do **NetBackup Manager** (sistema web de backup de configuração de
equipamentos de rede).

> **Software proprietário, uso sob licença.** Este repositório contém apenas o
> instalador; o produto em si está em repositório privado e exige licença.

## Estado atual: Fase 3a

Prepara a VM até o código do produto estar em `/opt/netbackup`:

1. pré-checagem (sistema, UFW, relógio, memória, espaço, saída para o GitHub);
2. disco de dados opcional em `/opt` (LVM + ext4);
3. chave de deploy do GitHub, somente leitura;
4. clone do código do produto;
5. relatório (`deploy.sh --check` do produto, somente leitura).

A configuração (domínio, certificado, firewall, administrador) vem na Fase 3b.

## Requisitos

- VM **Ubuntu 24.04 amd64** (22.04 funciona com aviso e confirmação);
- **server-baseline já aplicado** (UFW ativo, relógio sincronizado);
- 2 GB de RAM no mínimo (4 GB recomendados) e espaço livre para `/opt`;
- saída para `github.com:443`;
- acesso de administrador do repositório do produto, para cadastrar a chave de deploy.

## Como baixar (por TAG, com conferência)

Troque `vX.Y.Z` pela tag da versão que você recebeu. Faça como root, numa pasta
que só o root escreve:

```bash
sudo install -d -m 755 -o root -g root /root/instalador
cd /root/instalador
```

```bash
TAG=vX.Y.Z
BASE=https://raw.githubusercontent.com/glaucier/netbackup-instalador/$TAG
sudo curl -fsSLO "$BASE/instalar.sh"
sudo curl -fsSLO "$BASE/SHA256SUMS"
```

```bash
sha256sum -c SHA256SUMS
```

Só continue se a saída for `instalar.sh: OK`.

## Como rodar

```bash
sudo bash instalar.sh
```

O instalador pergunta o que precisa (disco de dados, cadastro da chave de deploy)
e pode ser repetido: continua de onde parou. O log fica em
`/root/netbackup-instalacao-AAAAMMDD_HHMMSS.log` (modo 600, sem segredos).

Regras de segurança do próprio instalador: precisa de root; recusa rodar se o
arquivo ou qualquer pasta acima dele não for do root ou tiver escrita para
grupo/outros (por exemplo, de dentro de `/opt/netbackup`); só executa arquivos
de `/opt/netbackup` que passem na mesma conferência.

### Somente leitura

```bash
sudo bash instalar.sh --check    # ok/falta por item; não altera nada
sudo bash instalar.sh --status   # resumo do que está pronto (sem rede)
sudo bash instalar.sh --help
```

`--check` sai com código 1 se houver item faltando.

## Variáveis (para testes)

Todos os caminhos e comandos podem ser sobrescritos por ambiente (`OPT_DIR`,
`SSH_DIR`, `LOG_DIR`, `REPO`, `BRANCH`, `CMD_GIT`, `CMD_LSBLK`, ...; veja o topo
de `instalar.sh`). Os padrões são os valores reais. Exemplo de repositório
alternativo: `REPO=git@github-netbackup:example/produto.git`.

## Desenvolvimento

```bash
python3 -m unittest discover -s tests -v   # testes (sem dependências externas)
bash -n instalar.sh && shellcheck instalar.sh
bash tools/gerar-sha256sums.sh             # atualiza o SHA256SUMS antes da tag
```

Os testes usam raiz falsa e comandos falsos no `PATH`; nunca tocam disco,
`/etc`, `/root` ou `/opt` reais. Um teste falha se o `SHA256SUMS` não bater com
o `instalar.sh`.

Este repositório é público: não coloque dados reais (IPs, domínios, nomes de
empresas). Exemplos usam apenas faixas RFC 5737/3849 e `example.com`.
