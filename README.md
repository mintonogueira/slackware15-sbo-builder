# Slackware 15 Repository Builder

Contêiner Slackware 15.0 x86_64 que mantém um espelho binário local, compara
a coleção SBo completa, compila somente o que ainda não existe em formato
binário e publica tudo por HTTP e HTTPS.

A imagem pronta é publicada em:

```text
ghcr.io/mintonogueira/slackware15-sbo-builder:15.0
```

O computador hospedeiro não constrói essa imagem. O GitHub Actions produz,
testa e publica a imagem completa; o controlador executa apenas `podman pull`.
As camadas OCI são verificadas pelo Podman, e o identificador SHA-256 baixado
fica em `dados/.estado/imagem-sha256.txt`.

A imagem não contém scripts operacionais nem SlackBuilds personalizados. Esses
arquivos ficam nos volumes editáveis `dados/rotinas/` e
`dados/slackbuilds-personalizados/`. Assim, alterar uma rotina ou SlackBuild não
exige reconstruir a imagem.

## Separação entre hospedeiro e contêiner

| Camada | Responsabilidade |
|---|---|
| Hospedeiro | Arch, Debian, Ubuntu, Fedora ou Slackware/Salix 15.0; executa Podman rootless e guarda os dados |
| Contêiner | Slackware 15.0 completo; executa `rsync`, `sbopkg`, compiladores e Apache |
| Pasta `dados/` | Repositórios, fontes, pacotes, resultados, falhas, logs e estado para retomada |

O sistema hospedeiro nunca precisa ser Slackware e nunca recebe os pacotes
compilados para Slackware.

## Conteúdo espelhado

Somente pacotes binários e os metadados necessários são sincronizados:

- Slackware 15.0 x86_64: `slackware64/`, `patches/packages/`, `extra/`,
  índices, checksums, assinaturas e chave GPG, obtidos de um espelho listado
  oficialmente pelo Slackware;
- Salix 15.0 x86_64: repositório principal e metadados;
- Salix `extra-15.0` x86_64: pacotes adicionais, incluindo os pacotes que o
  Salix exclui de seu catálogo filtrado de SlackBuilds;
- repositório local `compilados/15.0`: somente o que não existe nos três
  inventários binários anteriores;
- repositório local `navegadores/15.0`: Brave Browser Stable e Google Chrome
  Stable convertidos pelos SlackBuilds próprios do projeto.

ISOs e árvores de código-fonte do Slackware e do Salix não são espelhadas.
As receitas e fontes necessárias para as compilações SBo são preservadas à
parte em `dados/cache/` e em cada resultado.

## Primeira execução

```sh
chmod +x \
  compilar-slackbuilds.sh \
  preparar-hospedeiro.sh \
  parar-execucao.sh

./compilar-slackbuilds.sh --iniciar
./compilar-slackbuilds.sh --executar-tudo
```

Ao executar `--iniciar`, o controlador baixa a imagem pronta. Se o Podman não
estiver presente, ele oferece a instalação automática de Podman,
`fuse-overlayfs`, suporte rootless e das dependências pertinentes:

- Arch Linux e derivados suportados: `pacman`;
- Debian e Ubuntu: `apt-get`;
- Fedora: `dnf`;
- Slackware/Salix 15.0: `slapt-get`; se estiver ausente no Slackware, o
  pacote oficial do Salix é instalado e configurado primeiro.

Também são tratados:

- `kernel.unprivileged_userns_clone`, quando o kernel expõe essa opção;
- faixas de `/etc/subuid` e `/etc/subgid`;
- `fuse-overlayfs` para pasta pessoal em Btrfs;
- volume com rótulo privado `:Z` em hospedeiros com SELinux;
- validação final de `podman info` como usuário comum.

O comando `--preparar-hospedeiro` continua disponível para preparar apenas o
hospedeiro antes da inicialização.

## Rotinas e SlackBuilds fora da imagem

Na primeira inicialização, o controlador cria dois conjuntos persistentes:

```text
dados/rotinas/
├── SHA256SUMS
├── links.conf
├── scripts/
└── cache/remotas/

dados/slackbuilds-personalizados/
├── SHA256SUMS
├── links.conf
├── brave-browser/
├── google-chrome/
└── cache/remotas/
```

`dados/rotinas/scripts/` recebe todos os scripts operacionais padrão.
`dados/slackbuilds-personalizados/` recebe os SlackBuilds de Brave Stable e
Google Chrome Stable e também pode receber outras receitas próprias. O
controlador cria os dois manifestos na primeira execução e nunca sobrescreve
esses arquivos posteriormente.

Depois de editar um script, regenere o manifesto dentro de `dados/rotinas/`:

```sh
find scripts -type f -print0 |
  sort -z |
  xargs -0 sha256sum > SHA256SUMS
```

Depois de editar ou acrescentar um SlackBuild, regenere o manifesto dentro de
`dados/slackbuilds-personalizados/`:

```sh
find . -mindepth 2 -maxdepth 2 -type f ! -path './cache/*' -printf '%P\0' |
  sort -z |
  xargs -0 sha256sum > SHA256SUMS
```

Os manifestos precisam corresponder exatamente aos arquivos montados. Arquivo
ausente, adulterado ou não listado impede a inicialização.

Cada pasta também pode ter `links.conf` no formato:

```text
SHA256|CAMINHO_RELATIVO|URL_HTTPS
```

Somente HTTPS é aceito. O arquivo remoto só fica ativo depois da validação
SHA-256; um cache previamente validado pode ser reutilizado se o link estiver
temporariamente indisponível. As substituições remotas têm precedência sobre
os arquivos locais validados.

O carregador mínimo cria a árvore ativa em `/run/slackrepo-rotinas` e registra
o conjunto efetivamente utilizado em `dados/.estado/rotinas-ativas.sha256`.

Um SlackBuild próprio adicional usa a estrutura:

```text
dados/slackbuilds-personalizados/NOME/
├── NOME.info
├── NOME.SlackBuild
├── slack-desc
└── fontes exigidas pela receita
```

Quando `NOME.info` e `NOME.SlackBuild` estão presentes, a receita entra no
catálogo geral e tem prioridade sobre uma receita SBo de mesmo nome. A árvore
SBo sincronizada pelo `sbopkg` permanece separada em
`dados/cache/sbopkg-lib/SBo/15.0/`.

## Execução visível no terminal

O Apache permanece no contêiner de serviço. Todas as tarefas solicitadas pelo
controlador são executadas com `podman exec` em primeiro plano. O terminal
mostra ao vivo:

- arquivos sincronizados e progresso do `rsync`;
- validação GPG e checksums;
- sincronização SBo;
- comparação dos inventários;
- posição atual na fila global;
- comparação, download, conversão e instalação dos navegadores;
- saída completa de cada SlackBuild;
- sucesso, falha ou motivo para ignorar cada pacote.

O controlador não envia a compilação para segundo plano. `Ctrl+C` é entregue
à tarefa anexada ao terminal.

A única execução autônoma em segundo plano é a verificação diária dos dois
navegadores. Sua saída aparece em `--logs-servidor` e no log persistente; o
comando manual `--atualizar-navegadores` executa o mesmo fluxo anexado ao
terminal.

## Fluxo da compilação completa

```sh
./compilar-slackbuilds.sh --executar-tudo
```

O comando:

1. sincroniza os três repositórios binários;
2. verifica as assinaturas dos índices e os checksums presentes;
3. sincroniza a árvore SBo 15.0 completa usada pelo `sbopkg`;
4. extrai todos os nomes de pacote dos índices `PACKAGES.TXT`;
5. elimina da fila tudo que já existe no Slackware ou Salix;
6. resolve a ordem das dependências das receitas restantes;
7. instala dependências binárias somente dentro do contêiner;
8. compila e instala dependências SBo dentro do contêiner;
9. publica os novos `.txz` no repositório local;
10. gera `PACKAGES.TXT`, checksums e relatório final.

Antes dessa sequência, `--executar-tudo` também verifica as versões oficiais
dos dois navegadores e atualiza o repositório `navegadores/15.0`.

## Brave Stable e Google Chrome Stable

O projeto contém dois SlackBuilds independentes:

```text
slackbuilds/
├── brave-browser/brave-browser.SlackBuild
└── google-chrome/google-chrome.SlackBuild
```

Eles usam somente a edição Stable x86_64. Para não baixar e converter o mesmo
arquivo repetidamente, o fluxo diário:

1. baixa apenas o índice `Packages` do repositório oficial do fornecedor;
2. lê `Version`, `Filename` e `SHA256`;
3. compara a versão oficial com os `.txz` já publicados localmente;
4. se a versão já existir, não baixa novamente o `.deb` e não executa nova
   conversão;
5. se houver versão nova, baixa o `.deb` oficial e confirma seu SHA-256;
6. executa o SlackBuild correspondente e gera o `.txz`;
7. instala ou atualiza o navegador dentro do contêiner persistente;
8. regenera `PACKAGES.TXT`, `CHECKSUMS.md5` e `CHECKSUMS.sha256`;
9. preserva somente as três versões mais recentes de cada navegador.

Na primeira execução existirá somente a versão atual. As três versões serão
acumuladas naturalmente conforme os fornecedores publicarem atualizações.

O agendador interno faz uma tentativa a cada 24 horas. A execução e os erros
ficam visíveis nos logs do contêiner e também em:

```text
dados/logs/navegadores/AAAA-MM-DD.log
```

O agendador opera enquanto o contêiner está ativo. Se o computador ou o
serviço permanecer desligado por mais de 24 horas, a verificação vencida é
executada assim que o contêiner voltar a iniciar.

Para executar a verificação imediatamente, anexada ao terminal:

```sh
./compilar-slackbuilds.sh --atualizar-navegadores
```

Os SlackBuilds editáveis ficam em `dados/slackbuilds-personalizados/`, os
`.deb` verificados ficam no cache e os pacotes servidos pelo Apache ficam em:

```text
dados/repositorios/navegadores/15.0/packages/
```

Receitas com `%README%`, dependências irresolvíveis ou fontes que exigem
intervenção manual são registradas em `dados/ignorados/`. Uma falha individual
é registrada em `dados/falhas/` e não interrompe pacotes independentes.

Pacotes já concluídos no repositório local são reutilizados na próxima
execução. Assim, uma execução interrompida pode continuar sem recompilar tudo.

Compilar um único pacote continua disponível:

```sh
./compilar-slackbuilds.sh --pacote NOME
```

Se o nome já existir nos repositórios Slackware ou Salix, o controlador
informa a origem binária e não o recompila.

## Estrutura persistente

```text
dados/
├── repositorios/
│   ├── slackware/slackware64-15.0/
│   ├── salix/15.0/
│   ├── salix/extra-15.0/
│   ├── compilados/15.0/
│   └── navegadores/15.0/
├── cache/
├── rotinas/
│   ├── SHA256SUMS
│   ├── scripts/
│   └── cache/remotas/
├── slackbuilds-personalizados/
│   ├── SHA256SUMS
│   ├── brave-browser/
│   ├── google-chrome/
│   └── cache/remotas/
├── execucoes/
├── resultados/NOME-DATA/
│   ├── NOME.sqf
│   ├── ORDEM_INSTALACAO.txt
│   ├── CKSUMS.sha256
│   ├── INFORMACOES.txt
│   ├── STATUS
│   ├── instalar.sh
│   ├── fontes/
│   ├── logs/
│   └── pacotes/
├── falhas/
├── ignorados/
└── logs/
```

Os arquivos em `resultados/*/pacotes/` usam hard links quando o sistema de
arquivos permite; o mesmo `.txz` não ocupa espaço duas vezes.

A árvore de receitas do SlackBuilds.org fica em
`dados/cache/sbopkg-lib/SBo/15.0/`. Os arquivos-fonte baixados pelo `sbopkg`
ficam em `dados/cache/sbopkg-fontes/`. Para atualizar somente essa coleção:

```sh
./compilar-slackbuilds.sh --sincronizar-slackbuilds
```

## Servidor HTTP e HTTPS

Portas padrão do hospedeiro:

- HTTP: `8080`;
- HTTPS: `8443`.

Exemplo:

```text
http://192.168.1.20:8080/
https://192.168.1.20:8443/
```

O HTTPS recebe um certificado local persistente contendo os IPs do hospedeiro
detectados na primeira criação. Para usar HTTPS sem avisos, o certificado
`dados/.estado/tls/repositorio.crt` deve ser adicionado à cadeia de confiança
dos clientes. Em rede doméstica protegida, HTTP pode ser usado diretamente.

As portas podem ser alteradas antes de iniciar:

```sh
SLACKBUILD_HTTP_PORT=8888 \
SLACKBUILD_HTTPS_PORT=9443 \
./compilar-slackbuilds.sh --iniciar
```

## Configuração do slapt-get cliente

Mostre as linhas prontas:

```sh
./compilar-slackbuilds.sh --fontes-slapt-get
```

Substitua `IP_DO_SERVIDOR` pelo IP local ou IP Tailscale do hospedeiro:

```text
SOURCE=http://IP_DO_SERVIDOR:8080/slackware/slackware64-15.0/:OFFICIAL
SOURCE=http://IP_DO_SERVIDOR:8080/salix/15.0/:PREFERRED
SOURCE=http://IP_DO_SERVIDOR:8080/salix/extra-15.0/:CUSTOM
SOURCE=http://IP_DO_SERVIDOR:8080/compilados/15.0/:CUSTOM
SOURCE=http://IP_DO_SERVIDOR:8080/navegadores/15.0/:CUSTOM
```

Depois:

```sh
sudo slapt-get --update
```

## Rede local, Tailscale e Headscale

O contêiner tem rede privada do Podman, mas as portas são publicadas no
hospedeiro. Portanto, a forma mais simples e portável é:

- rede local: usar o IP LAN do hospedeiro;
- Tailscale: usar o IP Tailscale do hospedeiro;
- Headscale: registrar o hospedeiro com o cliente Tailscale apontado para o
  servidor Headscale e usar esse IP VPN.

Headscale é o servidor de controle; ele não substitui o cliente Tailscale
dentro de uma máquina. Na primeira criação, o controlador pergunta se a VPN
ficará no hospedeiro ou se será reservada uma configuração interna futura. A
escolha pode ser revista:

```sh
./compilar-slackbuilds.sh --configurar-vpn
```

Nenhuma chave de autenticação ou URL privada é solicitada ou gravada nessa
etapa.

## Comandos de administração

```sh
./compilar-slackbuilds.sh --status
./compilar-slackbuilds.sh --logs-servidor
./compilar-slackbuilds.sh --sincronizar
./compilar-slackbuilds.sh --sincronizar-slackbuilds
./compilar-slackbuilds.sh --compilar-faltantes
./compilar-slackbuilds.sh --atualizar-navegadores
./compilar-slackbuilds.sh --parar
./compilar-slackbuilds.sh --remover-instancia
./compilar-slackbuilds.sh --atualizar-imagem
```

`--parar` preserva a instância e todos os dados. `--remover-instancia`
preserva a imagem e a pasta `dados/`. `--atualizar-imagem` recria somente a
instância de serviço e reutiliza todo o armazenamento persistente.

## Recursos do hospedeiro

Antes de cada tarefa pesada, o controlador calcula e aplica:

- máximo de 25% da RAM total, mantendo reserva para o hospedeiro;
- máximo de 25% da CPU lógica disponível;
- quantidade de jobs compatível com a cota de CPU;
- ausência de cota adicional de swap;
- pausa temporária sob pressão crítica de memória.

O espelho binário exige dezenas de gigabytes. Compilar a parte restante da
coleção SBo pode exigir muito mais espaço e levar dias ou semanas, dependendo
da máquina, das fontes disponíveis e da quantidade de receitas compiláveis.

## Referências técnicas

- [Slackware Linux](https://www.slackware.com/)
- [Árvore oficial Slackware 15.0](https://mirrors.slackware.com/slackware/slackware64-15.0/)
- [Espelhos oficiais documentados pelo Salix](https://docs.salixos.org/user/repository-mirrors/)
- [Repositório Salix 15.0](https://download.salixos.org/x86_64/15.0/)
- [Repositório Salix extra-15.0](https://download.salixos.org/x86_64/extra-15.0/)
- [Comportamento de preferência binária do Salix](https://docs.salixos.org/user/slackbuilds-in-salix-repos/)
- [Uso de sbopkg no Salix](https://docs.salixos.org/user/sbopkg/)
