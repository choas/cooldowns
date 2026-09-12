# cooldowns

Interactive shell script that sets a dependency **cooldown** (minimum release age) for your package installers, based on [cooldowns.dev](https://cooldowns.dev/).

A cooldown makes an installer refuse package versions published less than N days ago. Most compromised packages are pulled within hours or days, so a 3-day cooldown blocks the majority of supply-chain attacks.

## Install

```sh
git clone https://github.com/choas/cooldowns.git
cd cooldowns
./cooldowns.sh --add-zshrc   # adds: alias cooldowns="$HOME/.../cooldowns.sh" to ~/.zshrc
```

## Usage

```sh
cooldowns            # asks: global or local
cooldowns global     # user-wide config for every supported installer
cooldowns local      # the project in the current directory (auto-detected)
```

Each installer is asked separately:

```
1) 1 day   2) 2 days   3) 3 days   0) turn OFF   s) skip   [3]:
```

The header shows the installed version and whether it supports cooldowns. At the end you get a summary and, if needed, the upgrade command for tools that are too old.

## Supported

| Tool | Global | Local | Setting |
|------|:------:|:-----:|---------|
| npm | `~/.npmrc` | `.npmrc` | `min-release-age` (days) |
| pnpm | pnpm global config | `pnpm-workspace.yaml` / `.npmrc` | `minimumReleaseAge` (minutes) |
| Yarn 4 | `~/.yarnrc.yml` | `.yarnrc.yml` | `npmMinimalAgeGate` (minutes) |
| Bun | `~/.bunfig.toml` | `bunfig.toml` | `[install] minimumReleaseAge` (seconds) |
| Deno | – | `deno.json` | `minimumDependencyAge` (`P3D`) |
| uv | `~/.config/uv/uv.toml` | `uv.toml` / `pyproject.toml [tool.uv]` | `exclude-newer` |
| pip | `pip config --user` | – | `install.uploaded-prior-to` (`P3D`) |
| pipenv | `PIP_UPLOADED_PRIOR_TO` | `Pipfile [pipenv]` | `cool-down-period` |
| Poetry | `poetry config` | `poetry.toml` | `solver.min-release-age` (days) |
| PDM | `pdm config` | `pyproject.toml [tool.pdm.resolution]` | `exclude-newer` |
| pixi | – | `pixi.toml [workspace]` | `exclude-newer` |
| Cargo | `~/.cargo/cooldown.toml` | `cooldown.toml` | `global-min-publish-age` (needs [cargo-cooldown](https://github.com/dertin/cargo-cooldown)) |
| Bundler | `bundle config --global` | `.bundle/config` | `cooldown` (days) |
| Hex | `mix hex.config` | `mix.exs` | `cooldown` |
| mise | `~/.config/mise/config.toml` | `mise.toml` | `[settings] minimum_release_age` |
| VS Code | `settings.json` | – | `extensions.autoUpdateDelay` (hours) |
| Dependabot | – | `.github/dependabot.yml` | `cooldown.default-days` |
| Renovate | – | `renovate.json` | `minimumReleaseAge` |

**Turn OFF** writes an explicit `0` where the tool has a built-in default (pnpm 11, Yarn 4.15, Deno 2.9, mise, Dependabot, Renovate); for uv, pip, PDM and pixi it removes the key.

Env-var based settings go to `~/.cooldowns.env`, sourced from `~/.zshrc`.

## Requirements

bash 3.2+, awk, perl (Hex), jq (Deno, Renovate, VS Code).
