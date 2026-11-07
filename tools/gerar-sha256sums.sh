#!/usr/bin/env bash
# Gera o SHA256SUMS (para instalar.sh). Rode na raiz do repositório antes de
# criar a tag:  bash tools/gerar-sha256sums.sh
# Opcional: um argumento com o caminho de saída (padrão: SHA256SUMS na raiz).
set -eu
raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
saida="${1:-$raiz/SHA256SUMS}"
( cd "$raiz" && sha256sum instalar.sh ) >"$saida"
echo "Gerado: $saida"
cat "$saida"
