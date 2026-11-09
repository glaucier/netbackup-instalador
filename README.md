# netbackup-instalador

Instalador do **NetBackup Manager** (sistema web de backup de configuração de
equipamentos de rede).

> **Software proprietário, uso sob licença.** Este repositório contém apenas o
> instalador; o produto em si está em repositório privado e exige licença.

## Estado atual: Versão 0.2.0

> Em desenvolvimento (`0.3.0-dev`, ainda sem tag): `--importar`, descrito em
> [Importar os dados de outro servidor](#importar-os-dados-de-outro-servidor---importar).

Leva a VM limpa até **"acesse https://NOME:44318"**. Ordem das etapas:

```
precheck → perguntas → [resumo + confirmação] → disco → chave → codigo
        → config → deploy → [importar] → https → firewall → relatorio
```

1. **pré-checagem** (sistema, UFW, relógio, memória, espaço, saída para o GitHub);
2. **perguntas** (ou `--respostas ARQUIVO`) e resumo com confirmação. Tudo que é
   pergunta vem antes de qualquer alteração; só a escolha do disco e o cadastro da
   chave ficam no meio;
3. **disco de dados** opcional em `/opt` (LVM + ext4);
4. **chave de deploy** do GitHub, somente leitura;
5. **código** do produto (clone);
6. **config**: cria `app_settings.conf` (com `APP_SECRET_KEY` nova, 600) e os
   arquivos de redes confiáveis a partir dos modelos do próprio produto e aplica as
   respostas (fuso, portas sugeridas, `PANEL_HOSTNAME`, redes). Guarda uma cópia do
   modelo do Nginx numa pasta só do root, com o sha256 registrado;
7. **deploy**: executa `deploy.sh --dominio NOME` (o `deploy.sh` pede a senha do
   administrador, digitada no terminal e nunca gravada);
8. **importar** (só com `--importar`): ver a seção própria abaixo;
9. **https**: confere o DNS, emite o certificado Let's Encrypt (ou liga o HTTPS
   provisório), gera o site do Nginx e o liga;
10. **firewall**: libera a `44318/tcp` para as redes do painel;
11. **relatório**: além do resumo na tela, grava `/root/netbackup-instalacao.txt` (600).

## Requisitos

- VM **Ubuntu 24.04 amd64** (22.04 funciona com aviso e confirmação);
- **server-baseline já aplicado** (UFW ativo, relógio sincronizado);
- 2 GB de RAM no mínimo (4 GB recomendados) e espaço livre para `/opt`;
- saída para `github.com:443`;
- acesso de administrador do repositório do produto, para cadastrar a chave de deploy.

## Como baixar (por TAG, com conferência)

**Tudo roda como root, na pasta `/root/instalador`.** Entre como root uma vez e
execute os comandos seguintes **sem `sudo`** (`/root` é 700: um usuário comum
não consegue entrar nela). Troque `vX.Y.Z` pela tag da versão que você recebeu.

```bash
sudo -i
```

Já como root:

```bash
install -d -m 755 /root/instalador
cd /root/instalador
```

```bash
TAG=v0.2.0
BASE=https://raw.githubusercontent.com/glaucier/netbackup-instalador/$TAG
curl -fsSLO "$BASE/instalar.sh"
curl -fsSLO "$BASE/SHA256SUMS"
```

```bash
sha256sum -c SHA256SUMS
```

Só continue se a saída for `instalar.sh: OK`.

## Como rodar

Ainda como root, em `/root/instalador`:

```bash
bash instalar.sh
```

O instalador pergunta o que precisa e pode ser repetido: continua de onde parou.
O log fica em `/root/netbackup-instalacao-AAAAMMDD_HHMMSS.log` (modo 600, sem
segredos).

### Perguntas e `--respostas`

Perguntas: nome do painel (ex.: `netbackup.example.com`), e-mail do Let's Encrypt,
redes do painel (pelo menos uma; a sugestão é o IP de quem está no SSH), redes
públicas e privadas confiáveis (opcionais), fuso horário (sugestão: o do servidor) e
"usar as portas oficiais no cadastro de equipamentos (22/443/80/8291)?". Depois vem
o resumo e a confirmação `[s/N]`. As respostas ficam em
`/root/netbackup-respostas.conf` (600); numa nova execução o instalador pergunta
"usar as respostas gravadas? [S/n]".

Sem perguntas, com um arquivo `CHAVE=valor` (sem segredos), ex. `/root/respostas.conf`:

```
DOMINIO=netbackup.example.com
EMAIL_LETSENCRYPT=admin@example.com
REDES_PAINEL=203.0.113.10/32  Administração
REDES_PAINEL=198.51.100.0/24  Escritório
REDES_PUBLICAS=192.0.2.0/24  Provedor
REDES_PRIVADAS=10.20.0.0/16  LAN
FUSO=America/Sao_Paulo
PORTA_SSH=22
PORTA_HTTPS=443
PORTA_HTTP=80
PORTA_WINBOX=8291
```

```bash
bash instalar.sh --respostas /root/respostas.conf
```

`REDES_*` podem se repetir (uma rede por linha, `CIDR descrição`); `FUSO` e `PORTA_*`
são opcionais. O arquivo é **só lido** (nunca recebe `source`) e precisa ser do root
e sem escrita para grupo/outros. Qualquer valor inválido para a instalação **antes de
alterar qualquer coisa**. Os formulários futuros vão gerar este mesmo arquivo. A
**senha do administrador não é pergunta do instalador**: o `deploy.sh` a pede no fim.

### HTTPS: DNS, certificado e modo provisório

O instalador consulta o `A` e o `AAAA` do nome em **dois resolvedores públicos**
(`1.1.1.1` e `8.8.8.8`, via `dig`) e compara com os endereços globais da VM
(`ip -o addr`). O `A` precisa bater; o `AAAA`, se existir, também (IPv6 errado =
não tenta, porque o Let's Encrypt prefere IPv6). Ele mostra o encontrado e o
esperado.

- **DNS ok**: abre a porta 80 (gancho `pre` do certbot), roda
  `certbot certonly --standalone` e fecha a 80 (gancho `post`, sempre, mesmo se o
  certbot falhar). Depois gera o site do Nginx, valida com `nginx -t` e liga.
- **DNS não ok** (ou certificado não emitido): **HTTPS provisório**, com certificado
  autoassinado (365 dias) em `/etc/netbackup-instalador/provisorio/` (pasta 700) e
  um site do Nginx com o cabeçalho `# PROVISORIO - gerado por instalar.sh (não editar)`.
  Acesse `https://IP:44318` (o aviso do navegador é esperado).

Quando o DNS apontar para a VM:

```bash
bash instalar.sh --certificado
```

Ele confere o DNS (para se não bater), emite o certificado e troca o site provisório
pelo definitivo, **só se** o site instalado tiver o cabeçalho `PROVISORIO`; se o
`nginx -t` falhar, o provisório volta; se der certo, recarrega o Nginx e testa
`https://NOME:44318` (302/403 = no ar). Um site do Nginx que não seja o provisório
gerado pelo instalador **nunca é sobrescrito**. O `--certificado` não usa nada de
`/opt/netbackup`: só a cópia do modelo guardada pelo root.

**Bancada/testes**: `LE_STAGING=1 bash instalar.sh` usa o ambiente de teste do Let's
Encrypt (`--staging`), que não gasta o limite de emissões (o certificado não é
confiável nos navegadores).

### Firewall

Para cada rede do painel o instalador cria a regra `44318/tcp` no UFW com o **mesmo
comentário** que a tela Firewall do produto usa (`NetBackup HTTPS (Nginx) - painel`).
Só acrescenta: não remove nem altera regra existente, não toca nas regras do
baseline (SSH) e é idempotente.

### Importar os dados de outro servidor (`--importar`)

Para instalar uma VM nova **já com os dados de outro servidor** (recuperação ou
migração), a partir de um *pacote do sistema* exportado pelo produto:

```bash
bash instalar.sh --importar /root/netbackup-AAAAMMDD_HHMMSS-sistema.tar.gz.gpg
```

Opções: `--homologacao` (importa com os agendamentos desligados), `--painel-hostname
NOME[:PORTA]` (nome do painel no destino; o padrão é o do pacote), `--forcar-importacao`
(permite importar sobre um produto que **já tem dados**: sobrepõe) e `--sem-sha256`.
Também vale com `--respostas` (chaves `IMPORTAR_ARQUIVO`, `IMPORTAR_HOMOLOGACAO=sim|nao`,
`IMPORTAR_PAINEL_HOSTNAME`; a linha de comando vence o arquivo). **A senha do pacote
nunca vai no arquivo de respostas**: é sempre pedida no terminal (sem eco).

1. **Antes de qualquer alteração**: o arquivo existe, é arquivo comum (sem link),
   legível e tem nome `netbackup...-AAAAMMDD_HHMMSS-(sistema|completo)[-N].tar.gz[.gpg]`.
   Se existir `ARQUIVO.sha256` ao lado, é conferido (uma linha `HASH  NOME`). Sem ele, o
   instalador avisa e pede `sim` (ou use `--sem-sha256`).
2. **Instalação normal até o deploy**, com o administrador inicial.
3. **Transporte**: o root só *lê* o pacote; o próprio `netbackup` grava a cópia em
   `/home/netbackup/importar` (pasta 700, arquivo 600), e o sha256 da cópia é conferido.
4. **`importar --check`** da ferramenta do produto, rodada sempre como `netbackup` a
   partir de `/opt/netbackup`. A senha é pedida aqui (até 3 tentativas para senha errada).
   A mesma senha é reaproveitada, só em memória, no passo real (descritor 3; nunca em
   argv, disco, log, estado nem relatório).
5. **Para** `netbackup.service` e `netbackup-scheduler.service`, **liga a manutenção**,
   **importa** e **religa** os serviços. **A manutenção continua ligada** até você
   liberar: pelo botão **"Liberar agendador"** da faixa do painel ou por
   `cd /opt/netbackup && sudo -u netbackup venv/bin/python -m tools.manutencao desligar`
   (`... estado`: saída 0 = desligada, 10 = ligada).
   Em **homologação**, sem `--painel-hostname`, o instalador passa
   `--painel-hostname <domínio das respostas>:44318` (nunca o nome da origem, pois a cópia roda ao
   lado da produção). Para encerrar: `cd /opt/netbackup && sudo -u netbackup venv/bin/python -m tools.pacote homologacao --encerrar`.
   As redes do painel no produto vêm do pacote, mas o UFW recebe as das respostas: confira em
   Firewall > "Aplicar regras faltantes". A senha do administrador pedida no deploy é temporária.
6. **HTTPS** com o nome do painel do pacote (ou de `--painel-hostname`); se ele for
   diferente do nome das respostas, o instalador avisa, atualiza as respostas gravadas e
   o DNS desse nome é que precisa apontar para a VM.
7. **Relatório** (`/root/netbackup-instalacao.txt`): importação sim/não, nome do arquivo,
   origem, homologação e o *CHECKLIST DO DESTINO* impresso pela ferramenta. Em homologação
   destaca que os agendamentos ficaram desligados. Depois do sucesso o instalador pergunta
   se apaga a cópia em `/home/netbackup/importar` (padrão: apagar); em falha a mantém e diz onde está.

**Destino com dados**: se o produto já tiver backups, banco com usuários anteriores ao
deploy ou tiver sido instalado fora do instalador, a importação é **recusada**; com
`--forcar-importacao` ela sobrepõe (pede confirmação; o estado anterior fica em
`/opt/netbackup/system_backups/pre-importacao/`).

**Códigos da ferramenta**: 0 ok; 1 erro de E/S; 2 recusado; 3 pacote inválido/adulterado;
4 senha errada; 5 pacote mais novo que o código (atualize o produto); 6 `gpg` ausente;
7 parou no meio. No **7** os serviços **não** sobem, a manutenção fica ligada e o
instalador mostra onde está o estado anterior; nas demais recusas antes da importação ele
restaura a manutenção e religa os serviços. O importar real **nunca** roda sem um
`--check` com saída 0 sobre a mesma cópia.

`bash instalar.sh --check --importar ARQUIVO` valida tudo o que dá sem alterar nada
(arquivo, nome, sha256, `gpg`, `sudo`, destino com dados) e avisa que a senha será pedida.
O pacote não traz os `backups/` dos equipamentos nem o `rclone.conf` (a não ser que tenha
sido exportado com `--com-rclone`): veja o checklist.

### Regras de segurança

Precisa de root; recusa rodar se o arquivo ou qualquer pasta acima dele não for do
root ou tiver escrita para grupo/outros (por exemplo, de dentro de `/opt/netbackup`);
só executa arquivos que passem na mesma conferência. O `deploy.sh` entrega
`/opt/netbackup` ao usuário `netbackup`: **toda escrita do root ali acontece antes
dele** (árvore ainda do root e conferida) e, depois dele, o instalador **nunca mais
executa nem escreve nada de lá**. O que o HTTPS precisa do produto (o modelo do
Nginx) fica numa cópia só do root em `/usr/local/share/netbackup-instalador/`
(sha256 conferido a cada uso). O estado do instalador fica em
`/etc/netbackup-instalador/` (só do root).

### Somente leitura

```bash
bash instalar.sh --check    # ok/falta por item (inclui DNS, HTTPS e firewall); não altera nada
bash instalar.sh --status   # resumo do que está pronto (sem rede)
bash instalar.sh --help
```

`--check` sai com código 1 se houver item faltando.

## Limitações conhecidas

- Depois do `deploy.sh`, `/opt/netbackup` é do usuário `netbackup` e o instalador não
  o toca mais: rodar o instalador de novo **pula** a configuração, o código e o
  deploy ("deploy feito") e continua em HTTPS/firewall/relatório. Se for preciso o
  `deploy.sh` outra vez, o instalador **recusa e explica**; rode-o à mão e o
  instalador reconhece o deploy concluído. O endurecimento posterior resolve isto.
- Mudar as respostas depois do deploy não reaplica a configuração (os arquivos já
  são do `netbackup`); ajuste pelo painel ou à mão.
- O DNS só é conferido contra endereços **globais** da VM: uma VM atrás de NAT (sem IP
  público na interface) fica sempre em HTTPS provisório.
- Só IPv4 nas redes do painel e nas redes confiáveis (como a tela Firewall do produto).
- A conferência de confiança cobre o `deploy.sh`, os ganchos do certbot e as pastas
  acima deles, não os arquivos que eles carregam.
- Sem `dig` (pacote `bind9-dnsutils`) o DNS não é conferido e o HTTPS fica provisório.
- Não há atualização (`git pull`) do código já instalado.
- Importação: "destino com dados" é detectado por backups em `/opt/netbackup/backups`, banco
  que já tinha usuários antes do deploy e produto instalado fora do instalador; equipamentos
  cadastrados sem nenhum backup não são vistos pelo instalador. Uma importação interrompida
  (código 7) bloqueia nova tentativa com `--importar` até você resolver à mão.

## Variáveis (para testes)

Todos os caminhos e comandos podem ser sobrescritos por ambiente (`OPT_DIR`,
`SSH_DIR`, `LOG_DIR`, `ESTADO_DIR`, `SHARE_DIR`, `LE_LIVE`, `HOOKS_DIR`, `REPO`, `BRANCH`,
`CMD_GIT`, `CMD_DIG`, `CMD_CERTBOT`, `CMD_NGINX`, `CMD_LSBLK`, `CMD_SUDO`, `CMD_GPG`,
`IMPORT_DIR`, `BACKUPS_DIR`, `PRE_IMPORT_DIR`, ...; veja o topo
de `instalar.sh`). Os padrões são os valores reais. Exemplo de repositório
alternativo: `REPO=git@github-netbackup:example/produto.git`.

## Desenvolvimento

```bash
python3 -m unittest discover -s tests -v   # testes (sem dependências externas; leva alguns minutos)
bash -n instalar.sh && shellcheck instalar.sh
bash tools/gerar-sha256sums.sh             # atualiza o SHA256SUMS antes da tag
```

Os testes usam raiz falsa e comandos falsos no `PATH`; nunca tocam disco,
`/etc`, `/root` ou `/opt` reais. Um teste falha se o `SHA256SUMS` não bater com
o `instalar.sh`.

Este repositório é público: não coloque dados reais (IPs, domínios, nomes de
empresas). Exemplos usam apenas faixas RFC 5737/3849 e `example.com`.
