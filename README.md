# Slackware 15 SBo Builder

Imagem estática e reutilizável do Slackware 15.0 x86_64 para compilar
SlackBuilds e entregar conjuntos autônomos com todas as dependências.

A imagem é construída uma única vez pelo GitHub Actions e publicada em:

```text
ghcr.io/mintonogueira/slackware15-sbo-builder:15.0
```

O computador hospedeiro **não constrói nem configura a imagem**. O script
somente a baixa, cria uma instância temporária, compila e elimina essa
instância. A imagem baixada permanece no Podman para os próximos usos.

## Conteúdo da imagem

- Slackware 15.0 x86_64 com ambiente completo;
- atualizações oficiais aplicadas pelo espelho mantido pelo Salix;
- compiladores e ferramentas de desenvolvimento;
- `sbopkg` e `sqg`;
- `slapt-get`, `slapt-src`, `spkg` e `fakeroot`;
- catálogo SBo 15.0 mantido pelo Salix;
- certificados CA e chave GPG do Slackware validados.

## Requisitos no hospedeiro

- Linux x86_64;
- Podman;
- acesso à internet para baixar a imagem e as fontes dos SlackBuilds.

## Uso

```sh
chmod +x compilar-slackbuilds.sh parar-execucao.sh
./compilar-slackbuilds.sh --pacote sl
```

Na primeira execução o Podman baixa a imagem pronta. Nas seguintes, a imagem
local é reutilizada.

Cada compilação concluída fica em:

```text
dados/resultados/NOME-DATA/
├── NOME.sqf
├── ORDEM_INSTALACAO.txt
├── CKSUMS.sha256
├── INFORMACOES.txt
├── STATUS
├── instalar.sh
├── fontes/
├── logs/
└── pacotes/
```

As dependências são compiladas primeiro e instaladas somente dentro da
instância descartável. O aplicativo principal é compilado, mas não é
instalado no contêiner. O `instalar.sh` usa a ordem registrada para instalar
todo o conjunto posteriormente no Slackware 15.0 x86_64.

## Interromper

No terminal ativo, pressione `Ctrl+C`. Em outro terminal, use:

```sh
./parar-execucao.sh
```

ou:

```sh
./compilar-slackbuilds.sh --parar
```

## Limpeza e estado

```sh
./compilar-slackbuilds.sh --status
./compilar-slackbuilds.sh --limpar-falhas
./compilar-slackbuilds.sh --limpar-testes
./compilar-slackbuilds.sh --atualizar-imagem
```

- `--limpar-falhas` apaga somente tentativas malsucedidas.
- `--limpar-testes` apaga resultados e resíduos deste projeto, após
  confirmação, mas preserva a imagem do Podman.
- `--atualizar-imagem` baixa novamente a versão publicada no GHCR.

## Recursos adaptativos

O controlador calcula os limites antes de iniciar e monitora o hospedeiro:

- RAM nunca acima de 25% da memória total;
- considera `MemAvailable` e mantém uma reserva para o hospedeiro;
- não permite swap adicional ao contêiner;
- CPU nunca acima de 25% dos processadores lógicos;
- reduz o orçamento quando o hospedeiro já está ocupado;
- recalcula a CPU durante a compilação;
- pausa a instância sob pressão crítica de memória e a retoma quando houver
  segurança;
- usa prioridade baixa de CPU e entrada/saída.

## Fontes de referência do sistema

- [Slackware Linux](https://www.slackware.com/)
- [Espelho Slackware 15.0 do Salix](https://download.salixos.org/x86_64/slackware-15.0/)
- [Coleção SBo 15.0 do Salix](https://download.salixos.org/sbo/15.0/SLACKBUILDS.TXT)
- [Documentação Salix sobre SlackBuilds](https://docs.salixos.org/user/slackbuilds-in-salix-repos/)
