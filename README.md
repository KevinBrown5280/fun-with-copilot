# fun-with-copilot

A personal sandbox for exploring and experimenting with GitHub Copilot.

## Playbooks

| Playbook | Description |
|----------|-------------|
| [multi-model-debate](playbooks/multi-model-debate/) | **GitHub Copilot CLI** — Pit multiple AI models against each other to stress-test a technical decision |

## Plugins

Install any plugin from inside the Copilot CLI:
```
/plugin marketplace add KevinBrown5280/fun-with-copilot
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

| Plugin | Description |
|--------|-------------|
| [adversarial-review](plugins/adversarial-review/) | **GitHub Copilot CLI** — 4-model independent code review with voting reconciliation and cross-session dismissed-findings persistence. Supports `full`, `local`, `pr`, `commit`, `since+local`, and `files` scope modes — auto-detects based on git state. |
| [multi-model-debate](plugins/multi-model-debate/) | **GitHub Copilot CLI** — Pit multiple AI models against each other to stress-test a technical decision |

## License

[MIT](LICENSE)