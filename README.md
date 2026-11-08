# netbackup-instalador

Instalador do **NetBackup Manager** (sistema web de backup de configuração de
equipamentos de rede).

> **Software proprietário, uso sob licença.** Este repositório contém apenas o
> instalador; o produto em si está em repositório privado e exige licença.

## Estado atual: Versão 0.2.0

Leva a VM limpa até **"acesse https://NOME:44318"**. Ordem das etapas:

```
precheck → perguntas → [resumo + confirmação] → disco → chave → codigo
        → config → deploy → https → firewall → relatorio
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
8. **https**: confere o DNS, emite o certificado Let's Encrypt (ou liga o HTTPS
   provisório), gera o site do Nginx e o liga;
9. **firewall**: libera a `44318/tcp` para as redes do painel;
10. **relatório**: além do resumo na tela, grava `/root/netbackup-instalacao.txt` (600).

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

## Variáveis (para testes)

Todos os caminhos e comandos podem ser sobrescritos por ambiente (`OPT_DIR`,
`SSH_DIR`, `LOG_DIR`, `ESTADO_DIR`, `SHARE_DIR`, `LE_LIVE`, `HOOKS_DIR`, `REPO`, `BRANCH`,
`CMD_GIT`, `CMD_DIG`, `CMD_CERTBOT`, `CMD_NGINX`, `CMD_LSBLK`, ...; veja o topo
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
