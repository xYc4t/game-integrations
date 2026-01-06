# Hyvlib v0.1.0

Hyvlib is a library created to implement common functionality for hoyoverse
games. It provides API fetching mechanism as well as functions to download
games and related packages like voiceovers.

## Integration

Add hyvlib package to your integration package inputs:

```json
{
    "format": 1,
    "inputs": {
        "hyvlib": "http://127.0.0.1:8080/packages/hyvlib/package.json"
    }
}
```

## Supported games

It should be possible to support all the hoyoverse games since they use the same
downloading and updating mechanism. Here only tested games are listed.

| Region   | Game      | Title                   |
| -------- | --------- | ----------------------- |
| `global` | `genshin` | Genshin Impact (global) |

Licensed under [GPL-3.0](../../LICENSE).
