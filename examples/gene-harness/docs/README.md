# Harness documentation

The reference documents describe implemented behavior. Proposals and dated
verification records are separate so a planned API is not mistaken for an
available feature.

## Reference

- [Design and module responsibilities](design.md)
- [Plugin contract](plugins.md), [plugin manager](plugin-manager.md) and [source/history](plugin-source.md)
- [Turn participants, Outcome schemas and initiators](turn-participants.md)
- [Browser client](web-client.md), [workspace views](workspace-views.md) and [components](web-components.md)
- [Workspace manager](manager.md), [commands](commands.md), [shell](shell.md) and [REPL](repl.md)
- [Notifications](notification.md), [cards](cards.md), [media](media.md) and [images](image-generation.md)
- [Voice](audio.md), [computer use](computer.md), [Slack channels](channels.md) and [sub-agents](sub-agent.md)
- [Triggers](triggers.md), [discovery](discovery.md), [sidebar](sidebar.md), [themes](theming.md) and [Claude providers](claude.md)
- [UI recipes](recipes/ui.md) and [notification recipes](recipes/notifications.md)
- [Todo replay guide](todo-replay.md)

## Proposals

- [Durable memory](proposals/memory.md): planned; not implemented.

## Implementation and verification

These are dated evidence and progress records, not alternate API contracts.

- [Architecture refactor batches](verification/architecture-refactor.md)
- [Notifications](verification/notification-verification.md)
- [Plugin manager verification](verification/plugin-manager-verification.md) and [progress](verification/plugin-manager-progress.md)
- [Workspace views](verification/workspace-views-verification.md)
- [Spotlight](verification/spotlight-verification.md)
- [Voice implementation](verification/audio-implementation.md) and [benchmarks](verification/audio-benchmarks.md)
- [Channels](verification/channels-implementation.md)
- [Spreadsheet experiment](verification/spreadsheet-experiment.md)
