# fun-with-copilot

A personal sandbox for exploring and experimenting with GitHub Copilot.

## Playbooks

| Playbook | Description |
|----------|-------------|
| [multi-model-debate](playbooks/multi-model-debate/) | **GitHub Copilot CLI** — Pit multiple AI models against each other to stress-test a technical decision |
| [multi-repo-workspace](playbooks/multi-repo-workspace/) | Give AI agents full context across a multi-repo bounded context using Windows junctions — no clones, no submodules |

## Plugins

| Plugin | Description |
|--------|-------------|
| [adversarial-review](plugins/adversarial-review/) | **GitHub Copilot CLI** — 4-model independent code review with voting reconciliation and cross-session dismissed-findings persistence. Supports `full`, `local`, `pr`, `commit`, `since+local`, and `files` scope modes — auto-detects based on git state. |
| [multi-model-debate](plugins/multi-model-debate/) | **GitHub Copilot CLI** — Pit multiple AI models against each other to stress-test a technical decision |

## GitHub Spec Kit Extensions

Additional GitHub Spec Kit extensions in separate repositories:

| Extension | Description |
|----------|-------------|
| [spec-kit-memory-loader](https://github.com/KevinBrown5280/spec-kit-memory-loader) | Loads `.specify/memory/` files before spec-kit lifecycle commands so agents have project governance context. |
| [spec-kit-spec-reference-loader](https://github.com/KevinBrown5280/spec-kit-spec-reference-loader) | Reads the `## References` section from a feature spec and loads the listed files into context before downstream lifecycle commands. |
| [spec-kit-version-guard](https://github.com/KevinBrown5280/spec-kit-version-guard) | Checks locked dependency versions against live registries and surfaces official update guidance before planning and implementation. |

Add the marketplace source:
```
/plugin marketplace add KevinBrown5280/fun-with-copilot
```

Install a plugin:
```
/plugin install <plugin-name>@fun-with-copilot
```

Update a plugin:
```
/plugin update <plugin-name>@fun-with-copilot
```

Uninstall a plugin:
```
/plugin uninstall <plugin-name>
```

Remove the marketplace source:
```
/plugin marketplace remove fun-with-copilot
```

## License

[MIT](LICENSE)