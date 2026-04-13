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