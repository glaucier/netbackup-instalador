# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).

## [0.3.0] - 2026-11-10

Importação dos dados de outro servidor na instalação (`--importar`).

### Adicionado

- `instalar.sh --importar ARQUIVO [--homologacao] [--painel-hostname NOME[:PORTA]]`: instala
  uma VM nova **já com os dados de outro servidor** (recuperação ou migração) usando o
  "pacote do sistema" do produto (`tools.pacote` e `tools.manutencao`), sem passos manuais
  além da senha do pacote.
  - Precheck antes de qualquer alteração: o arquivo existe, é arquivo comum (sem link), legível
    e tem nome no padrão do produto; `ARQUIVO.sha256` é conferido (sem ele: confirmação
    explícita ou `--sem-sha256`); `gpg` para pacote `.gpg`; `sudo`.
  - Transporte: o root só **lê**; o próprio `netbackup` grava a cópia em
    `/home/netbackup/importar` (700, arquivo 600) por `sudo -u netbackup install/tee`, e o
    sha256 da cópia é conferido (também pelo `netbackup`).
  - Fluxo: instalação normal até o deploy → `importar --check` (senha pedida no terminal,
    até 3 tentativas) → para `netbackup.service` e `netbackup-scheduler.service` → liga a
    manutenção → importa → religa os serviços. A **manutenção continua ligada** até o
    operador liberar; o relatório explica e mostra o botão "Liberar agendador" e o comando.
  - A senha do pacote fica só em memória e vai à ferramenta pelo descritor 3
    (`--senha-fd 3`): nunca em argv, disco, log, estado nem relatório.
  - O nome do painel passa a ser o do pacote (ou o de `--painel-hostname`); a etapa HTTPS
    usa esse nome e o instalador avisa quando ele difere do das respostas.
  - Destino com dados (backups, usuários pré-existentes ou produto já instalado): recusa,
    a não ser com `--forcar-importacao` (avisa que sobrepõe e pede confirmação).
  - Cada código de saída da ferramenta (1 a 7) tem mensagem própria; no 7 o estado anterior
    (`system_backups/pre-importacao/`) é indicado e os serviços **não** sobem. O importar
    real nunca roda sem um `--check` com saída 0 sobre a mesma cópia.
  - Estado e relatório registram importação sim/não, nome do arquivo (nunca a senha), origem
    e homologação; o "CHECKLIST DO DESTINO" da ferramenta é anexado ao relatório. Em
    homologação o relatório destaca que os agendamentos ficaram desligados.
  - Depois do sucesso pergunta se apaga a cópia (padrão: apagar); em falha a mantém e diz onde está.
- `--respostas`: chaves `IMPORTAR_ARQUIVO`, `IMPORTAR_HOMOLOGACAO` e `IMPORTAR_PAINEL_HOSTNAME`.
  A senha do pacote **nunca** vai no arquivo (a chave é recusada).
- `--check` com `--importar`: valida o arquivo e o sha256 sem alterar nada e avisa que a senha
  será pedida na instalação.
- Nova etapa `importar` (entre `deploy` e `https`); as etapas seguintes passam a ser 9, 10 e 11.

### Alterado

#### Ajustes da revisão (v2)

- Leitura do `PANEL_HOSTNAME` do `importar --check` corrigida: vale só o primeiro token depois
  de `destino ` (a linha sem `--painel-hostname` traz um texto explicativo depois do nome, que
  antes confundia o corte em `:`); `(não definido)` conta como sem nome (o HTTPS mantém o das respostas, com aviso).
- Homologação nunca assume o nome da origem: sem `--painel-hostname`, o instalador passa
  `--painel-hostname <domínio das respostas>:44318` ao `--check` e à importação e informa na tela
  e no relatório. Recuperação/migração continuam usando o nome do pacote.
- Relatório: encerrar a homologação com `tools.pacote homologacao --encerrar` (não religa nada
  sozinho; `homologacao` sem `--encerrar` só mostra o estado) e aviso sobre as redes do painel
  (produto = as do pacote; UFW = as das respostas; conferir em Firewall > "Aplicar regras faltantes").
- Com `--importar`, o aviso antes da senha do administrador diz que ela é temporária (o banco será trocado).
- shellcheck limpo (variável sem uso removida).

### Corrigido

- Leitura do nome do painel no `importar --check` (ver v2 acima).
- Relatório com importação: o item "encerre a homologação" só aparece quando a importação foi
  feita com `--homologacao` (numa recuperação ele não faz sentido); os itens são renumerados.

#### Ajustes do teste real (v3)

- Código do produto: um clone existente agora é comparado com `origin/<branch>` (fetch). Em dia: segue.
  Atrás com fast-forward possível e sem alterações locais: mostra "local X, remoto Y", pergunta
  "Atualizar para Y? [S/n]" e faz `merge --ff-only`. Divergente ou com alterações locais em arquivos
  versionados: recusa com instrução, **antes** da etapa de configuração. Local à frente ou fetch
  que falha: só avisa. Com `--check` só informa (usa `ls-remote`, não escreve nada).
- Resumo das respostas com `--importar`: linhas "Importação", "Homologação" e "Nome do painel no
  produto"; a senha do administrador aparece como TEMPORÁRIA.
- Depois do `importar --check`, quando a ferramenta avisa que o destino já tem 1 usuário e ele é o
  admin criado agora pelo deploy, o instalador imprime que isso é esperado.
- Relatório com importação: "Próximos passos" próprios (usuário da origem, CHECKLIST, liberar a
  manutenção, encerrar a homologação, conferir o Firewall). Sem importação nada muda.

### Limitações conhecidas

- "Destino com dados" é detectado por arquivos em `/opt/netbackup/backups`, por banco que já
  tinha usuários antes do deploy e por produto instalado fora do instalador; equipamentos
  cadastrados sem nenhum backup não são vistos pelo instalador (só pela ferramenta do produto).
- Importação interrompida (código 7) ou sem estado conhecido bloqueia nova tentativa com
  `--importar`; resolva à mão e rode o instalador sem `--importar`.
- A comparação do clone com `origin/main` (v3) foi testada só com `git` simulado; o teste real
  fica para a próxima instalação a partir de VM limpa.

## [0.2.0] - 2026-11-07

Fases 3a e 3b: da VM limpa até "acesse https://NOME:44318".

### Adicionado

- Pré-checagem (sistema, UFW, relógio, memória, espaço, programas, saída para o GitHub).
- Disco de dados opcional em `/opt` (LVM + ext4), com recusa de disco em uso ou pequeno.
- Chave de deploy do GitHub somente leitura, com impressão digital oficial fixada e
  diagnóstico de onde a chave está cadastrada.
- Clone do código do produto.
- Perguntas interativas e `--respostas ARQUIVO`, com validação (domínio, e-mail, CIDR,
  fuso, portas), resumo e confirmação; respostas gravadas e reaproveitadas.
- Configuração antes do deploy: arquivos de configuração a partir dos modelos do produto,
  sem sobrescrever arquivo diferente, e cópia do modelo do Nginx só do root com sha256.
- Deploy do produto (`deploy.sh --dominio NOME`) com conferência de confiança, ligado direto
  ao terminal via `script(1)` para o pedido da senha do administrador.
- HTTPS: conferência de DNS (A/AAAA em dois resolvedores), certificado Let's Encrypt com
  ganchos da porta 80, HTTPS provisório autoassinado e modo `--certificado`
  (`LE_STAGING=1` para bancada).
- Firewall: regra da `44318/tcp` para as redes do painel, idempotente, com o comentário da tela
  Firewall do produto.
- Relatório final (`/root/netbackup-instalacao.txt`), regravado após o `--certificado`.
- `--check` e `--status` cobrindo todas as etapas.

### Limitações conhecidas

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
