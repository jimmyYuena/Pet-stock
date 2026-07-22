# Teddy Codex Buddy

Teddy is a tiny animated bear buddy for Codex: calm, dapper, wearing round glasses and a navy cardigan, with a tiny iPad mini and softer little work moods.

## Install

1. Unzip `teddy-codex-buddy.zip`.
2. Open the unzipped `teddy/` folder.
3. Back up any existing `~/.codex/pets/teddy` folder.
4. Copy only `pet.json` and `spritesheet.webp` into `~/.codex/pets/teddy/`.
5. Verify the installed spritesheet SHA-256 is `c9e0da13b6bdeed6ffefecebf0633621c90aa042ca02b3b7224b62806642304a`.
6. Restart Codex if Teddy does not appear right away, then select `Teddy` in Codex pets.

## Tell Codex To Install It

Paste this into Codex:

```text
Please install Teddy, my tiny Codex buddy, from:
https://danieloleary.github.io/teddy-v31/downloads/teddy-codex-buddy.zip

Back up any existing ~/.codex/pets/teddy folder, download and unzip the ZIP,
copy only pet.json and spritesheet.webp into ~/.codex/pets/teddy/,
then verify the installed spritesheet SHA-256 is:
c9e0da13b6bdeed6ffefecebf0633621c90aa042ca02b3b7224b62806642304a

If verification fails, restore the backup.
```

## What Is Inside

- `pet.json`: Teddy's Codex pet manifest.
- `spritesheet.webp`: Teddy's validated transparent animation atlas.
- `contact-sheet.png`: all animation frames in one image.
- `installed-validation.json`: atlas validation proof.
- `manifest.json`: hashes and package metadata.
- `previews/`: small GIF previews of Teddy's core moods.

Only `pet.json` and `spritesheet.webp` are needed for installation. The rest are previews, validation proof, and hashes.

## Validation

- Release: `4.0.0`
- Atlas: `1536x1872`
- Grid: `8x9`
- Cell: `192x208`
- Format: `WEBP`
- Mode: `RGBA`
- Transparent residue: `0`
- Pet JSON SHA-256: `a2a2e69f47da98babcee011cbad7a78e7b663e61ff39a6ec5f4c05e860823218`
- Spritesheet SHA-256: `c9e0da13b6bdeed6ffefecebf0633621c90aa042ca02b3b7224b62806642304a`

Do not send your whole `.codex` folder. This ZIP contains only Teddy's pet package, previews, validation proof, and metadata.
