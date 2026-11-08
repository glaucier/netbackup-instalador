# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).

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
